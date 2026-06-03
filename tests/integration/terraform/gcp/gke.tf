# Copyright IBM Corp. 2026
# Provisions: VPC network, subnet (with secondary ranges for pods/services),
# a zonal GKE cluster with Workload Identity enabled, and a fixed-size node pool.

# ---------------------------------------------------------------------------
# VPC Network
# ---------------------------------------------------------------------------

resource "google_compute_network" "this" {
  name                    = "${var.gke_cluster_name}-vpc"
  auto_create_subnetworks = false
  project                 = var.gcp_project_id
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.gke_cluster_name}-subnet"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.gcp_region
  network       = google_compute_network.this.id
  project       = var.gcp_project_id

  # Secondary ranges required for VPC-native (alias-IP) GKE networking
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

# ---------------------------------------------------------------------------
# GKE Cluster — zonal, Workload Identity enabled
# ---------------------------------------------------------------------------

resource "google_container_cluster" "this" {
  name    = var.gke_cluster_name
  # A zone (not a region) creates a zonal cluster — simpler and cheaper for CI.
  location = var.gke_zone
  project  = var.gcp_project_id

  network    = google_compute_network.this.name
  subnetwork = google_compute_subnetwork.this.name

  # Remove the automatically created default node pool; we manage our own below.
  remove_default_node_pool = true
  initial_node_count       = 1

  min_master_version = var.gke_kubernetes_version != "" ? var.gke_kubernetes_version : null

  # Workload Identity — allows K8s ServiceAccounts to impersonate GCP IAM SAs
  workload_identity_config {
    workload_pool = "${var.gcp_project_id}.svc.id.goog"
  }

  # VPC-native networking uses alias IP ranges defined on the subnet above
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Disable legacy basic-auth and client-certificate issuance
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Allow Terraform destroy to delete the cluster without protection
  deletion_protection = false

  lifecycle {
    # Ignore GKE-managed upgrades to the master version between applies
    ignore_changes = [min_master_version]
  }
}

# ---------------------------------------------------------------------------
# GKE Node Pool — 2-node fixed pool for integration testing
# ---------------------------------------------------------------------------

resource "google_container_node_pool" "this" {
  name     = "${var.gke_cluster_name}-node-pool"
  location = var.gke_zone
  cluster  = google_container_cluster.this.name
  project  = var.gcp_project_id

  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-balanced"

    # cloud-platform scope is required for Workload Identity metadata server access
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # GKE_METADATA mode exposes the Workload Identity metadata server on each node
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      ManagedBy = "terraform"
      cluster   = var.gke_cluster_name
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
