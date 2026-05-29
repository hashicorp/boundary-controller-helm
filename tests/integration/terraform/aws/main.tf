# Copyright IBM Corp. 2026

# ---------------------------------------------------------------------------
# Provider configuration
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  # Fetch short-lived EKS auth tokens on demand instead of using a token
  # generated at the beginning of terraform apply.
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--region",
      var.aws_region,
      "--cluster-name",
      aws_eks_cluster.this.name,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--region",
        var.aws_region,
        "--cluster-name",
        aws_eks_cluster.this.name,
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# Kubernetes namespace
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "boundary" {
  metadata {
    name = var.release_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# AWS KMS keys — root / recovery / worker-auth
# ---------------------------------------------------------------------------

resource "aws_kms_key" "root" {
  description             = "Boundary controller root key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name    = "boundary-root"
    ManagedBy = "terraform"
  }
}

resource "aws_kms_alias" "root" {
  name          = var.kms_root_key_alias
  target_key_id = aws_kms_key.root.key_id
}

resource "aws_kms_key" "recovery" {
  description             = "Boundary controller recovery key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name      = "boundary-recovery"
    ManagedBy = "terraform"
  }
}

resource "aws_kms_alias" "recovery" {
  name          = var.kms_recovery_key_alias
  target_key_id = aws_kms_key.recovery.key_id
}

resource "aws_kms_key" "worker_auth" {
  description             = "Boundary controller worker-auth key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name      = "boundary-worker-auth"
    ManagedBy = "terraform"
  }
}

resource "aws_kms_alias" "worker_auth" {
  name          = var.kms_worker_auth_key_alias
  target_key_id = aws_kms_key.worker_auth.key_id
}

# ---------------------------------------------------------------------------
# IRSA — IAM role that the controller pod uses to access KMS
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "irsa_assume_role" {
  count = var.create_irsa_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.release_namespace}:${var.release_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "boundary_controller" {
  count              = var.create_irsa_role ? 1 : 0
  name               = var.irsa_role_name
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role[0].json

  tags = {
    ManagedBy = "terraform"
  }
}

data "aws_iam_policy_document" "kms_access" {
  count = var.create_irsa_role ? 1 : 0

  statement {
    sid    = "BoundaryKMSAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [
      aws_kms_key.root.arn,
      aws_kms_key.recovery.arn,
      aws_kms_key.worker_auth.arn,
    ]
  }
}

resource "aws_iam_role_policy" "kms_access" {
  count  = var.create_irsa_role ? 1 : 0
  name   = "boundary-kms-access"
  role   = aws_iam_role.boundary_controller[0].id
  policy = data.aws_iam_policy_document.kms_access[0].json
}

# ---------------------------------------------------------------------------
# Kubernetes ServiceAccount (with IRSA annotation)
# ---------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "boundary_controller" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace_v1.boundary.metadata[0].name

    annotations = var.create_irsa_role ? {
      "eks.amazonaws.com/role-arn" = aws_iam_role.boundary_controller[0].arn
    } : {}

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"        = var.release_name
    }
  }
}

# ---------------------------------------------------------------------------
# Kubernetes Secret — Boundary runtime secrets
# ---------------------------------------------------------------------------

resource "kubernetes_secret_v1" "boundary_controller" {
  metadata {
    name      = "boundary-controller-secrets"
    namespace = kubernetes_namespace_v1.boundary.metadata[0].name
  }

  # Encode values as base64 — the `data` block handles this automatically.
  data = {
    "database-url"   = var.boundary_db_url
    "license"        = var.boundary_license
    "admin-username" = var.boundary_admin_username
    "admin-password" = var.boundary_admin_password
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Local values — build Helm values YAML
# ---------------------------------------------------------------------------

locals {
  nlb_api_annotations = var.enable_nlb_annotations ? {
    "service.beta.kubernetes.io/aws-load-balancer-type"                  = "external"
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"       = "ip"
    "service.beta.kubernetes.io/aws-load-balancer-scheme"                = "internet-facing"
    "service.beta.kubernetes.io/aws-load-balancer-attributes"            = "load_balancing.cross_zone.enabled=true"
  } : {}

  nlb_cluster_annotations = var.enable_nlb_annotations ? {
    "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
    "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
  } : {}
}

# ---------------------------------------------------------------------------
# Deploy in-cluster PostgreSQL before the Helm chart's db-init pre-install hook
# ---------------------------------------------------------------------------

resource "terraform_data" "postgres" {
  triggers_replace = {
    cluster_name  = aws_eks_cluster.this.name
    postgres_yaml = filemd5("${path.module}/../../postgres.yaml")
  }

  depends_on = [
    aws_eks_node_group.this,
    kubernetes_namespace_v1.boundary,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --region ${var.aws_region} \
        --name ${aws_eks_cluster.this.name} \
        --alias eks-${aws_eks_cluster.this.name}
      kubectl apply -f ${path.module}/../../postgres.yaml \
        --context eks-${aws_eks_cluster.this.name}
      kubectl wait --for=condition=ready pod \
        -n ${var.release_namespace} \
        --context eks-${aws_eks_cluster.this.name} \
        -l app=postgres \
        --timeout=120s
    EOT
  }
}

# ---------------------------------------------------------------------------
# Helm release — boundary-controller
# ---------------------------------------------------------------------------

resource "helm_release" "boundary_controller" {
  name             = var.release_name
  namespace        = kubernetes_namespace_v1.boundary.metadata[0].name
  chart            = var.chart_path
  version          = var.chart_version != "" ? var.chart_version : null
  create_namespace = false   # Namespace managed by kubernetes_namespace above
  wait             = false  # Integration test uses port-forward; LoadBalancer IPs are not needed
  timeout          = 900  # 15 min — allows for EKS image pull on initial deploy
  upgrade_install  = true    # Allow install-or-upgrade (handles stale failed releases)
  cleanup_on_fail  = true    # Clean up on failure to avoid stale releases blocking retries

  # Ensure secrets, service account, and PostgreSQL exist before the chart deploys
  depends_on = [
    kubernetes_secret_v1.boundary_controller,
    kubernetes_service_account_v1.boundary_controller,
    terraform_data.postgres,
  ]

  # -----------------------------------------------------------------------
  # Individual value overrides
  # (helm provider v3: set blocks replaced with set = [...] argument)
  # -----------------------------------------------------------------------

  set = [
    # Core image & replica settings
    {
      name  = "image.tag"
      value = var.image_tag
    },
    {
      name  = "controller.replicas"
      value = var.controller_replicas
    },
    # TLS
    {
      name  = "tls.disabled"
      value = var.tls_disabled
    },
    # Secret reference (the K8s secret we created above)
    {
      name  = "controller.secretRefs.secretName"
      value = kubernetes_secret_v1.boundary_controller.metadata[0].name
    },
    {
      name  = "controller.secretRefs.validateExisting"
      value = "true"
    },
    # Service account (IRSA-annotated, created above)
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.boundary_controller.metadata[0].name
    },
    # API service type
    {
      name  = "controller.service.api.type"
      value = var.api_service_type
    },
    # Run bootstrap-admin on upgrade so it executes even after a timed-out install
    {
      name  = "controller.bootstrapAdmin.runOnUpgrade"
      value = "true"
    },
  ]

  # -----------------------------------------------------------------------
  # Rendered values: KMS config + NLB annotations
  # Multiline strings and annotation maps must be passed via `values`,
  # not `set`, to avoid shell-escaping and newline issues.
  # -----------------------------------------------------------------------

  values = [
    templatefile("${path.module}/templates/helm-values.yaml.tpl", {
      tls_disabled            = var.tls_disabled
      aws_region              = var.aws_region
      kms_root_alias          = var.kms_root_key_alias
      kms_recovery_alias      = var.kms_recovery_key_alias
      kms_worker_alias        = var.kms_worker_auth_key_alias
      nlb_api_annotations     = local.nlb_api_annotations
      nlb_cluster_annotations = local.nlb_cluster_annotations
    }),
    # Caller-supplied overrides have the highest precedence (last wins in Helm).
    var.additional_helm_values,
  ]
}
