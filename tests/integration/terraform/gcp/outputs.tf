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
