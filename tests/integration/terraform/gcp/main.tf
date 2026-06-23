# Copyright IBM Corp. 2026

# ---------------------------------------------------------------------------
# Provider configuration
# ---------------------------------------------------------------------------

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# data.google_client_config supplies a short-lived OAuth2 token for the
# kubernetes and helm providers so they authenticate without a static kubeconfig.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.this.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${google_container_cluster.this.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate)
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

  depends_on = [google_container_node_pool.this]
}

# ---------------------------------------------------------------------------
# Kubernetes Secret — Boundary runtime secrets
# ---------------------------------------------------------------------------

resource "kubernetes_secret_v1" "boundary_controller" {
  metadata {
    name      = "boundary-controller-secrets"
    namespace = kubernetes_namespace_v1.boundary.metadata[0].name
  }

  # The `data` block handles base64 encoding automatically.
  data = {
    "database-url"   = var.boundary_db_url
    "license"        = var.boundary_license
    "admin-username" = var.boundary_admin_username
    "admin-password" = var.boundary_admin_password
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# In-cluster PostgreSQL — deployed before the Helm chart's db-init hook
# ---------------------------------------------------------------------------

resource "terraform_data" "postgres" {
  triggers_replace = {
    cluster_name  = google_container_cluster.this.name
    postgres_yaml = filemd5("${path.module}/../../postgres.yaml")
  }

  depends_on = [
    google_container_node_pool.this,
    kubernetes_namespace_v1.boundary,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      gcloud container clusters get-credentials ${google_container_cluster.this.name} \
        --zone ${var.gke_zone} \
        --project ${var.gcp_project_id}
      kubectl apply -f ${path.module}/../../postgres.yaml \
        --context gke_${var.gcp_project_id}_${var.gke_zone}_${google_container_cluster.this.name}
      kubectl wait --for=condition=ready pod \
        -n ${var.release_namespace} \
        --context gke_${var.gcp_project_id}_${var.gke_zone}_${google_container_cluster.this.name} \
        -l app=postgres \
        --timeout=120s
    EOT
  }
}

# ---------------------------------------------------------------------------
# Local values — computed Helm value fragments
# ---------------------------------------------------------------------------

locals {
  # GKE external LoadBalancer annotation (no special NLB setup required)
  lb_api_annotations = {
    "cloud.google.com/load-balancer-type" = "External"
  }

  # Internal LoadBalancer for the cluster (peer-worker) listener
  lb_cluster_annotations = {
    "cloud.google.com/load-balancer-type" = "Internal"
  }

  # PodDisruptionBudget requires >= 2 replicas; disable automatically for single-replica installs.
  pdb_enabled = var.controller_replicas >= 2
}

# ---------------------------------------------------------------------------
# Helm release — boundary-controller
# ---------------------------------------------------------------------------

resource "helm_release" "boundary_controller" {
  name             = var.release_name
  namespace        = kubernetes_namespace_v1.boundary.metadata[0].name
  chart            = var.chart_path
  repository       = var.chart_repository != "" ? var.chart_repository : null
  version          = var.chart_version != "" ? var.chart_version : null
  create_namespace = false # Namespace managed by kubernetes_namespace_v1 above
  wait             = false # Integration test uses port-forward; LB IPs not required
  timeout          = 900   # 15 min — allows for image pull on first deploy
  upgrade_install  = true  # Install-or-upgrade (handles stale failed releases)
  cleanup_on_fail  = true  # Clean up on failure to avoid blocking retries

  depends_on = [
    kubernetes_secret_v1.boundary_controller,
    terraform_data.postgres,
  ]

  # -----------------------------------------------------------------------
  # Individual value overrides via set blocks
  # -----------------------------------------------------------------------

  set = [
    {
      name  = "image.tag"
      value = var.image_tag
    },
    {
      name  = "controller.replicas"
      value = var.controller_replicas
    },
    {
      name  = "tls.disabled"
      value = var.tls_disabled
    },
    {
      name  = "controller.secretRefs.secretName"
      value = kubernetes_secret_v1.boundary_controller.metadata[0].name
    },
    {
      name  = "controller.secretRefs.validateExisting"
      value = "true"
    },
    {
      name  = "controller.service.api.type"
      value = var.api_service_type
    },
    {
      name  = "bootstrapAdminAuthMethod.runOnUpgrade"
      value = "true"
    },
    {
      name  = "bootstrapAdminAuthMethod.waitTimeoutSeconds"
      value = "300"
    },
    {
      name  = "podDisruptionBudget.enabled"
      value = tostring(local.pdb_enabled)
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "boundary-controller"
    },
  ]

  # -----------------------------------------------------------------------
  # Rendered values: AEAD KMS config + LB annotations
  # Multiline strings and annotation maps must go in `values`, not `set`.
  # -----------------------------------------------------------------------

  values = [
    templatefile("${path.module}/templates/helm-values.yaml.tpl", {
      tls_disabled           = var.tls_disabled
      lb_api_annotations     = local.lb_api_annotations
      lb_cluster_annotations = local.lb_cluster_annotations
    }),
    # Caller-supplied overrides have the highest precedence (last wins in Helm).
    var.additional_helm_values,
  ]
}
