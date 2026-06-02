# Copyright IBM Corp. 2026

output "eks_cluster_name" {
  description = "Name of the provisioned EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint of the EKS cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "eks_cluster_version" {
  description = "Kubernetes version of the EKS cluster."
  value       = aws_eks_cluster.this.version
}

output "vpc_id" {
  description = "ID of the VPC created for the EKS cluster."
  value       = aws_vpc.this.id
}

output "helm_release_name" {
  description = "Name of the deployed Helm release."
  value       = helm_release.boundary_controller.name
}

output "helm_release_namespace" {
  description = "Namespace the release was deployed into."
  value       = helm_release.boundary_controller.namespace
}

output "helm_release_status" {
  description = "Status of the Helm release."
  value       = helm_release.boundary_controller.status
}

output "kms_root_key_arn" {
  description = "ARN of the Boundary root KMS key."
  value       = aws_kms_key.root.arn
}

output "kms_recovery_key_arn" {
  description = "ARN of the Boundary recovery KMS key."
  value       = aws_kms_key.recovery.arn
}

output "kms_worker_auth_key_arn" {
  description = "ARN of the Boundary worker-auth KMS key."
  value       = aws_kms_key.worker_auth.arn
}

output "irsa_role_arn" {
  description = "ARN of the IRSA role assigned to the controller pod (empty if create_irsa_role=false)."
  value       = var.create_irsa_role ? aws_iam_role.boundary_controller[0].arn : ""
}

output "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount used by the controller."
  value       = kubernetes_service_account_v1.boundary_controller.metadata[0].name
}
