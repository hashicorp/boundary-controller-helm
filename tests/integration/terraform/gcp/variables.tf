# Copyright IBM Corp. 2026

# ---------------------------------------------------------------------------
# GCP / GKE
# ---------------------------------------------------------------------------

variable "gcp_project_id" {
  description = "GCP project ID where the GKE cluster will be created."
  type        = string
}

variable "gcp_region" {
  description = "GCP region for the GKE cluster and KMS key ring."
  type        = string
  default     = "us-central1"
}

variable "gke_zone" {
  description = "GCP zone for the zonal GKE cluster (e.g. us-central1-a)."
  type        = string
  default     = "us-central1-a"
}

variable "gke_cluster_name" {
  description = "Name for the GKE cluster (also used to name the VPC and subnet)."
  type        = string
  default     = "boundary-controller-cluster"
}

variable "gke_kubernetes_version" {
  description = "Minimum Kubernetes master version for the GKE cluster (e.g. '1.31'). Leave empty to use the GKE release-channel default."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# GKE Node Pool
# ---------------------------------------------------------------------------

variable "node_machine_type" {
  description = "Machine type for GKE worker nodes."
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Number of nodes in the pool (fixed size — appropriate for integration testing)."
  type        = number
  default     = 2
}

variable "node_disk_size_gb" {
  description = "Boot-disk size in GiB for each node."
  type        = number
  default     = 50
}

# ---------------------------------------------------------------------------
# Helm release
# ---------------------------------------------------------------------------

variable "chart_path" {
  description = "Local chart path or OCI reference used when chart_repository is blank."
  type        = string
  default     = "../../../../"
}

variable "chart_repository" {
  description = "Helm repository URL. Leave blank for local-path or OCI installs."
  type        = string
  default     = ""
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "boundary-controller"
}

variable "release_namespace" {
  description = "Kubernetes namespace to deploy into (created if absent)."
  type        = string
  default     = "boundary"
}

variable "chart_version" {
  description = "Chart version to deploy. Leave empty for local chart installs."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Boundary secrets
# ---------------------------------------------------------------------------

variable "boundary_db_url" {
  description = "PostgreSQL connection string. Defaults to the in-cluster PostgreSQL deployed by this Terraform config."
  type        = string
  sensitive   = true
  default     = "postgresql://boundary:boundary-test-pw@postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable"
}

variable "boundary_license" {
  description = "HashiCorp Boundary Enterprise license string."
  type        = string
  sensitive   = true
}

variable "boundary_admin_username" {
  description = "Bootstrap admin login name."
  type        = string
  default     = "admin"
}

variable "boundary_admin_password" {
  description = "Bootstrap admin password."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# GCP Cloud KMS
# ---------------------------------------------------------------------------

variable "kms_location" {
  description = "Location for the GCP KMS key ring (e.g. 'global' or a GCP region like 'us-central1')."
  type        = string
  default     = "global"
}

variable "kms_key_ring_name" {
  description = "Name of the GCP KMS key ring to create."
  type        = string
  default     = "boundary-key-ring"
}

variable "kms_root_key_name" {
  description = "Name of the GCP KMS crypto key used for Boundary root sealing."
  type        = string
  default     = "boundary-root"
}

variable "kms_recovery_key_name" {
  description = "Name of the GCP KMS crypto key used for Boundary recovery."
  type        = string
  default     = "boundary-recovery"
}

variable "kms_worker_auth_key_name" {
  description = "Name of the GCP KMS crypto key used for Boundary worker authentication."
  type        = string
  default     = "boundary-worker-auth"
}

# ---------------------------------------------------------------------------
# Workload Identity
# ---------------------------------------------------------------------------

variable "gsa_name" {
  description = "Short account ID (without @project.iam.gserviceaccount.com) for the controller GCP IAM service account."
  type        = string
  default     = "boundary-controller-sa"
}

# ---------------------------------------------------------------------------
# Helm values overrides
# ---------------------------------------------------------------------------

variable "controller_replicas" {
  description = "Number of Boundary controller replicas."
  type        = number
  default     = 1
}

variable "api_service_type" {
  description = "Kubernetes service type for the Boundary API listener (LoadBalancer recommended for GKE)."
  type        = string
  default     = "LoadBalancer"
}

variable "tls_disabled" {
  description = "Disable TLS on Boundary listeners (set false and supply a TLS secret for production)."
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Boundary Enterprise image tag."
  type        = string
  default     = "0.21-ent"
}

variable "additional_helm_values" {
  description = "Additional Helm values as a YAML string merged last (highest precedence)."
  type        = string
  default     = ""
}
