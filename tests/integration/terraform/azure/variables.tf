# Copyright IBM Corp. 2026

# ---------------------------------------------------------------------------
# Azure / AKS
# ---------------------------------------------------------------------------

variable "azure_subscription_id" {
  description = "Azure subscription ID (optional when az CLI already has active subscription)."
  type        = string
  default     = ""
}

variable "azure_location" {
  description = "Azure region where AKS resources will be created."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Azure Resource Group name for AKS integration resources."
  type        = string
  default     = "rg-boundary-controller-aks"
}

variable "aks_cluster_name" {
  description = "AKS cluster name."
  type        = string
  default     = "boundary-controller-aks"
}

variable "aks_kubernetes_version" {
  description = "Kubernetes version for AKS cluster. Leave empty for provider default."
  type        = string
  default     = ""
}

variable "node_vm_size" {
  description = "VM size for AKS system node pool."
  type        = string
  default     = "Standard_D4s_v4"
}

variable "node_count" {
  description = "Node count for AKS system node pool."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# Helm release
# ---------------------------------------------------------------------------

variable "chart_path" {
  description = "Path to the boundary-controller Helm chart directory (relative to this module or absolute)."
  type        = string
  default     = "../../../../"
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
  description = "Chart version to deploy (leave blank when using a local path)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Boundary secrets
# ---------------------------------------------------------------------------

variable "boundary_db_url" {
  description = "PostgreSQL connection string."
  type        = string
  sensitive   = true
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
# Helm values overrides
# ---------------------------------------------------------------------------

variable "controller_replicas" {
  description = "Number of Boundary controller replicas."
  type        = number
  default     = 2
}

variable "api_service_type" {
  description = "Kubernetes service type for Boundary API listener."
  type        = string
  default     = "LoadBalancer"
}

variable "enable_azure_lb_annotations" {
  description = "Add Azure Load Balancer annotations for API and cluster services."
  type        = bool
  default     = true
}

variable "cluster_service_internal" {
  description = "Whether cluster service should be internal to VNet."
  type        = bool
  default     = true
}

variable "tls_disabled" {
  description = "Disable TLS on Boundary listeners for integration tests."
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
