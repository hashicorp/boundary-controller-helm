# Copyright IBM Corp. 2026

# ---------------------------------------------------------------------------
# AWS / EKS
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region where the EKS cluster will be created."
  type        = string
  default     = "us-east-1"
}

variable "eks_cluster_name" {
  description = "Name for the EKS cluster (also used to name VPC, subnets, IAM roles)."
  type        = string
  default     = "boundary-controller-cluster"
}

variable "eks_kubernetes_version" {
  description = "Kubernetes version for the EKS cluster. Must satisfy the chart's kubeVersion (>= 1.34)."
  type        = string
  default     = "1.34"
}

# ---------------------------------------------------------------------------
# EKS Node Group
# ---------------------------------------------------------------------------

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# Helm release
# ---------------------------------------------------------------------------

variable "chart_path" {
  description = "Local chart path or chart name (for repository-based installs)."
  type        = string
  default     = "../../../../"
}

variable "chart_repository" {
  description = "Helm repository URL used when deploying a released chart (leave blank for local path installs)."
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
  description = "Chart version to deploy (typically set for repository-based installs)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Boundary secrets (stored in a pre-existing K8s Secret or passed here)
# ---------------------------------------------------------------------------

variable "boundary_db_url" {
  description = "PostgreSQL connection string, e.g. postgresql://user:pass@host:5432/boundary?sslmode=require"
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
# AWS KMS key aliases
# ---------------------------------------------------------------------------

variable "kms_root_key_alias" {
  description = "Alias for the Boundary root KMS key."
  type        = string
  default     = "alias/boundary-root"
}

variable "kms_recovery_key_alias" {
  description = "Alias for the Boundary recovery KMS key."
  type        = string
  default     = "alias/boundary-recovery"
}

variable "kms_worker_auth_key_alias" {
  description = "Alias for the Boundary worker-auth KMS key."
  type        = string
  default     = "alias/boundary-worker-auth"
}

# ---------------------------------------------------------------------------
# IAM / IRSA
# ---------------------------------------------------------------------------

variable "create_irsa_role" {
  description = "Whether to create an IAM role for service accounts (IRSA) for KMS access."
  type        = bool
  default     = true
}

variable "irsa_role_name" {
  description = "Name of the IAM role created for IRSA."
  type        = string
  default     = "boundary-controller-role"
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
  description = "Kubernetes service type for the Boundary API listener (LoadBalancer recommended for EKS)."
  type        = string
  default     = "LoadBalancer"
}

variable "enable_nlb_annotations" {
  description = "Add AWS NLB annotations to the API and cluster services (requires AWS Load Balancer Controller)."
  type        = bool
  default     = true
}

variable "tls_disabled" {
  description = "Disable TLS on Boundary listeners (set false and supply a TLS secret for production)."
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Boundary Enterprise image tag."
  type        = string
  default     = "0.21.3-ent"
}

variable "additional_helm_values" {
  description = "Additional Helm values as a YAML string merged last (highest precedence)."
  type        = string
  default     = ""
}
