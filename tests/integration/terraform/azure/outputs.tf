# Copyright IBM Corp. 2026

output "resource_group_name" {
  description = "Name of the Azure Resource Group used for AKS integration resources."
  value       = azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  description = "Name of the provisioned AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "aks_cluster_fqdn" {
  description = "FQDN of the AKS API server."
  value       = azurerm_kubernetes_cluster.this.fqdn
}

output "aks_cluster_kubernetes_version" {
  description = "Kubernetes version of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.kubernetes_version
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

output "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount used by the controller."
  value       = kubernetes_service_account_v1.boundary_controller.metadata[0].name
}
