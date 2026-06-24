# Copyright IBM Corp. 2026

# ---------------------------------------------------------------------------
# Provider configuration
# ---------------------------------------------------------------------------

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id != "" ? var.azure_subscription_id : null
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.azure_location

  tags = {
    ManagedBy = "terraform"
  }
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.aks_cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.aks_cluster_name
  kubernetes_version  = var.aks_kubernetes_version != "" ? var.aks_kubernetes_version : null

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    node_count                  = var.node_count
    os_disk_type                = "Managed"
    type                        = "VirtualMachineScaleSets"
    temporary_name_for_rotation = "sysrot"
  }

  identity {
    type = "SystemAssigned"
  }

  role_based_access_control_enabled = true

  tags = {
    ManagedBy = "terraform"
  }
}

provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "aks-${var.aks_cluster_name}"
}

provider "helm" {
  kubernetes = {
    config_path    = pathexpand("~/.kube/config")
    config_context = "aks-${var.aks_cluster_name}"
  }
}

# ---------------------------------------------------------------------------
# Kubernetes namespace and runtime secret
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "boundary" {
  metadata {
    name = var.release_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_service_account_v1" "boundary_controller" {
  metadata {
    name      = var.release_name
    namespace = kubernetes_namespace_v1.boundary.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = var.release_name
    }
  }
}

resource "kubernetes_secret_v1" "boundary_controller" {
  metadata {
    name      = "boundary-controller-secrets"
    namespace = kubernetes_namespace_v1.boundary.metadata[0].name
  }

  data = {
    "database-url"   = var.boundary_db_url
    "license"        = var.boundary_license
    "admin-username" = var.boundary_admin_username
    "admin-password" = var.boundary_admin_password
  }

  type = "Opaque"
}

locals {
  api_annotations = var.enable_azure_lb_annotations ? {
    "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/health"
  } : {}

  cluster_annotations = var.enable_azure_lb_annotations && var.cluster_service_internal ? {
    "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
  } : {}
}

# ---------------------------------------------------------------------------
# Deploy in-cluster PostgreSQL before chart pre-install db init hook
# ---------------------------------------------------------------------------

resource "terraform_data" "postgres" {
  triggers_replace = {
    cluster_name  = azurerm_kubernetes_cluster.this.name
    postgres_yaml = filemd5("${path.module}/../../postgres.yaml")
  }

  depends_on = [
    azurerm_kubernetes_cluster.this,
    kubernetes_namespace_v1.boundary,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      az aks get-credentials \
        --resource-group ${azurerm_resource_group.this.name} \
        --name ${azurerm_kubernetes_cluster.this.name} \
        --overwrite-existing \
        --context aks-${azurerm_kubernetes_cluster.this.name}
      kubectl apply -f ${path.module}/../../postgres.yaml \
        --context aks-${azurerm_kubernetes_cluster.this.name}
      kubectl wait --for=condition=ready pod \
        -n ${var.release_namespace} \
        --context aks-${azurerm_kubernetes_cluster.this.name} \
        -l app=postgres \
        --timeout=180s
    EOT
  }
}

# ---------------------------------------------------------------------------
# Helm release — boundary-controller
# ---------------------------------------------------------------------------

resource "helm_release" "boundary_controller" {
  name             = var.release_name
  namespace        = kubernetes_namespace_v1.boundary.metadata[0].name
  chart            = var.chart_path
  version          = var.chart_version != "" ? var.chart_version : null
  create_namespace = false
  wait             = false
  timeout          = 900
  upgrade_install  = true
  cleanup_on_fail  = true

  depends_on = [
    kubernetes_secret_v1.boundary_controller,
    kubernetes_service_account_v1.boundary_controller,
    terraform_data.postgres,
  ]

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
  ]

  values = [
    templatefile("${path.module}/templates/helm-values.yaml.tpl", {
      tls_disabled        = var.tls_disabled
      api_annotations     = local.api_annotations
      cluster_annotations = local.cluster_annotations
    }),
    var.additional_helm_values,
  ]
}
