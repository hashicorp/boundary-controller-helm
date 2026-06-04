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
# GCP Cloud KMS — key ring + 3 crypto keys (root / recovery / worker-auth)
# ---------------------------------------------------------------------------

# Ensure the Cloud KMS API is enabled before creating any KMS resources.
resource "google_project_service" "cloudkms" {
  project            = var.gcp_project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

# GCP API enablement is eventually consistent; wait 60 s for propagation before
# creating KMS resources to avoid an immediate 403 "API not enabled" error.
resource "time_sleep" "wait_for_kms_api" {
  create_duration = "60s"
  depends_on      = [google_project_service.cloudkms]
}

# Import the key ring if it already exists (GCP KMS key rings are permanent and
# cannot be deleted, so re-runs must adopt the existing resource).
import {
  to = google_kms_key_ring.boundary
  id = "projects/${var.gcp_project_id}/locations/${var.kms_location}/keyRings/${var.kms_key_ring_name}"
}

resource "google_kms_key_ring" "boundary" {
  name     = var.kms_key_ring_name
  location = var.kms_location
  project  = var.gcp_project_id

  depends_on = [time_sleep.wait_for_kms_api]
}

resource "google_kms_crypto_key" "root" {
  name     = var.kms_root_key_name
  key_ring = google_kms_key_ring.boundary.id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }

  lifecycle {
    # Allow keys to be destroyed when running terraform destroy
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key" "recovery" {
  name     = var.kms_recovery_key_name
  key_ring = google_kms_key_ring.boundary.id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key" "worker_auth" {
  name     = var.kms_worker_auth_key_name
  key_ring = google_kms_key_ring.boundary.id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# ---------------------------------------------------------------------------
# GCP IAM Service Account — controller pod identity via Workload Identity
# ---------------------------------------------------------------------------

resource "google_service_account" "boundary_controller" {
  account_id   = var.gsa_name
  display_name = "Boundary Controller GKE Service Account"
  project      = var.gcp_project_id
}

# Grant Encrypter/Decrypter on all three KMS crypto keys
resource "google_kms_crypto_key_iam_member" "root_access" {
  crypto_key_id = google_kms_crypto_key.root.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.boundary_controller.email}"
}

resource "google_kms_crypto_key_iam_member" "recovery_access" {
  crypto_key_id = google_kms_crypto_key.recovery.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.boundary_controller.email}"
}

resource "google_kms_crypto_key_iam_member" "worker_auth_access" {
  crypto_key_id = google_kms_crypto_key.worker_auth.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.boundary_controller.email}"
}

# Grant Viewer on the key ring so the GSA can call cryptoKeys.get (key-existence
# check performed by the Boundary KMS plugin before encrypt/decrypt).
# roles/cloudkms.cryptoKeyEncrypterDecrypter intentionally omits this permission.
resource "google_kms_key_ring_iam_member" "kms_viewer" {
  key_ring_id = google_kms_key_ring.boundary.id
  role        = "roles/cloudkms.viewer"
  member      = "serviceAccount:${google_service_account.boundary_controller.email}"
}

# Workload Identity binding: allow the K8s ServiceAccount to impersonate the GCP SA
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.boundary_controller.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project_id}.svc.id.goog[${var.release_namespace}/${var.release_name}]"
}

# ---------------------------------------------------------------------------
# Kubernetes ServiceAccount (annotated for Workload Identity)
# ---------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "boundary_controller" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace_v1.boundary.metadata[0].name

    # This annotation links the K8s SA to the GCP SA for Workload Identity
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.boundary_controller.email
    }

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = var.release_name
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
    kubernetes_service_account_v1.boundary_controller,
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
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.boundary_controller.metadata[0].name
    },
    {
      name  = "controller.service.api.type"
      value = var.api_service_type
    },
    {
      name  = "bootstrapAdmin.runOnUpgrade"
      value = "true"
    },
    {
      name  = "bootstrapAdmin.waitTimeoutSeconds"
      value = "300"
    },
    {
      name  = "podDisruptionBudget.enabled"
      value = tostring(local.pdb_enabled)
    },
  ]

  # -----------------------------------------------------------------------
  # Rendered values: GCP KMS config + LB annotations
  # Multiline strings and annotation maps must go in `values`, not `set`.
  # -----------------------------------------------------------------------

  values = [
    templatefile("${path.module}/templates/helm-values.yaml.tpl", {
      tls_disabled        = var.tls_disabled
      gcp_project_id      = var.gcp_project_id
      kms_location        = var.kms_location
      kms_key_ring        = var.kms_key_ring_name
      kms_root_key        = var.kms_root_key_name
      kms_recovery_key    = var.kms_recovery_key_name
      kms_worker_auth_key = var.kms_worker_auth_key_name
      lb_api_annotations  = local.lb_api_annotations
      lb_cluster_annotations = local.lb_cluster_annotations
    }),
    # Caller-supplied overrides have the highest precedence (last wins in Helm).
    var.additional_helm_values,
  ]
}
