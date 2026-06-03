# Copyright IBM Corp. 2026

output "gke_cluster_name" {
  description = "Name of the provisioned GKE cluster."
  value       = google_container_cluster.this.name
}

output "gke_cluster_endpoint" {
  description = "API server endpoint of the GKE cluster (without https://)."
  value       = google_container_cluster.this.endpoint
}

output "gke_cluster_location" {
  description = "Zone of the GKE cluster."
  value       = google_container_cluster.this.location
}

output "gke_cluster_master_version" {
  description = "Kubernetes master version running on the cluster."
  value       = google_container_cluster.this.master_version
}

output "vpc_network_name" {
  description = "Name of the VPC network created for the cluster."
  value       = google_compute_network.this.name
}

output "kube_context" {
  description = "kubectl context name for the GKE cluster (set by gcloud container clusters get-credentials)."
  value       = "gke_${var.gcp_project_id}_${var.gke_zone}_${google_container_cluster.this.name}"
}

output "helm_release_name" {
  description = "Name of the deployed Helm release."
  value       = helm_release.boundary_controller.name
}

output "helm_release_namespace" {
  description = "Namespace the Helm release was deployed into."
  value       = helm_release.boundary_controller.namespace
}

output "helm_release_status" {
  description = "Status of the Helm release."
  value       = helm_release.boundary_controller.status
}

output "kms_key_ring_id" {
  description = "Fully-qualified ID of the GCP KMS key ring."
  value       = google_kms_key_ring.boundary.id
}

output "kms_root_key_id" {
  description = "Fully-qualified ID of the Boundary root KMS crypto key."
  value       = google_kms_crypto_key.root.id
}

output "kms_recovery_key_id" {
  description = "Fully-qualified ID of the Boundary recovery KMS crypto key."
  value       = google_kms_crypto_key.recovery.id
}

output "kms_worker_auth_key_id" {
  description = "Fully-qualified ID of the Boundary worker-auth KMS crypto key."
  value       = google_kms_crypto_key.worker_auth.id
}

output "gsa_email" {
  description = "Email address of the GCP IAM service account used by the controller pod."
  value       = google_service_account.boundary_controller.email
}

output "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount used by the controller."
  value       = kubernetes_service_account_v1.boundary_controller.metadata[0].name
}
