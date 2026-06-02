# Copyright IBM Corp. 2026
# This file is rendered by Terraform's templatefile() function.
# Variables: tls_disabled, api_annotations, cluster_annotations

controller:
  config: |
    disable_mlock = true

    listener "tcp" {
      address = "0.0.0.0:9200"
      purpose = "api"
      tls_disable = ${tls_disabled}
    }

    listener "tcp" {
      address = "0.0.0.0:9201"
      purpose = "cluster"
    }

    listener "tcp" {
      address = "0.0.0.0:9203"
      purpose = "ops"
      tls_disable = ${tls_disabled}
    }

    controller {
      name = "boundary-controller"
      description = "Boundary Controller running on AKS"
      public_cluster_addr = "{{ printf "%s:9201" (include "boundary.controller.clusterServiceName" .) }}"
      license = "env://BOUNDARY_LICENSE"

      database {
        url = "env://BOUNDARY_PG_URL"
      }

      graceful_shutdown_wait_duration = "10s"
    }

    # Integration testing uses static AEAD keys to avoid external KMS dependencies.
    kms "aead" {
      purpose   = "root"
      aead_type = "aes-gcm"
      key       = "8fZBjCUfN0TzjEGLQldGY4+iE9AkOvCfjh7+p0GtRBQ="
      key_id    = "aks-root"
    }

    kms "aead" {
      purpose   = "worker-auth"
      aead_type = "aes-gcm"
      key       = "GQ7m2L5rWy90P1xvR8wzWQvV54nA9M4V3x3K8Fv5YyQ="
      key_id    = "aks-worker-auth"
    }

    kms "aead" {
      purpose   = "recovery"
      aead_type = "aes-gcm"
      key       = "L0t7m4mP6jS2hD9Qx1bYf3nV7kR5cW8pE2uA9zN6qHs="
      key_id    = "aks-recovery"
    }

    events {
      audit_enabled = true
      observations_enabled = true
      sysevents_enabled = true
      telemetry_enabled = true
      sink "stderr" {
        name = "default"
        event_types = ["*"]
        format = "cloudevents-json"
      }
    }

  service:
    api:
      annotations:
%{ for k, v in api_annotations ~}
        ${k}: "${v}"
%{ endfor ~}
    cluster:
      annotations:
%{ for k, v in cluster_annotations ~}
        ${k}: "${v}"
%{ endfor ~}
