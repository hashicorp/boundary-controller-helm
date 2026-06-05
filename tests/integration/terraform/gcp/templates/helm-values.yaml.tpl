# Copyright IBM Corp. 2026
# This file is rendered by Terraform's templatefile() function.
# Variables: tls_disabled, lb_api_annotations, lb_cluster_annotations

controller:
  config: |
    disable_mlock = true

    listener "tcp" {
      address = "0.0.0.0:9200"
      purpose = "api"
      tls_disable   = ${tls_disabled}
%{ if !tls_disabled ~}
      tls_cert_file = "/etc/boundary/tls/tls.crt"
      tls_key_file  = "/etc/boundary/tls/tls.key"
%{ endif ~}
    }

    listener "tcp" {
      address = "0.0.0.0:9201"
      purpose = "cluster"
    }

    listener "tcp" {
      address = "0.0.0.0:9203"
      purpose = "ops"
      tls_disable   = ${tls_disabled}
%{ if !tls_disabled ~}
      tls_cert_file = "/etc/boundary/tls/tls.crt"
      tls_key_file  = "/etc/boundary/tls/tls.key"
%{ endif ~}
    }

    controller {
      name        = "boundary-controller"
      description = "Boundary Controller running on GKE"
      license     = "env://BOUNDARY_LICENSE"

      database {
        url = "env://BOUNDARY_PG_URL"
      }

      graceful_shutdown_wait_duration = "10s"

      api_rate_limit {
        resources = ["*"]
        actions   = ["*"]
        per       = "total"
        limit     = 500
        period    = "1s"
      }

      api_rate_limit {
        resources = ["*"]
        actions   = ["*"]
        per       = "ip-address"
        limit     = 100
        period    = "1s"
      }

      api_rate_limit {
        resources = ["*"]
        actions   = ["*"]
        per       = "auth-token"
        limit     = 100
        period    = "1s"
      }
    }

    # Integration testing uses static AEAD keys to avoid external KMS dependencies.
    kms "aead" {
      purpose   = "root"
      aead_type = "aes-gcm"
      key       = "UBsMiKsMh0mIzjPx8e7e1LbC5wFvHCuFZPUlIDcTRuE="
      key_id    = "gke-root"
    }

    kms "aead" {
      purpose   = "recovery"
      aead_type = "aes-gcm"
      key       = "QkYpNd6X4oTjcWlM2rGhFsV8zEu0Aw3Kn9qZb7PiRe5="
      key_id    = "gke-recovery"
    }

    kms "aead" {
      purpose   = "worker-auth"
      aead_type = "aes-gcm"
      key       = "Rl3TbZ7KnP9vE4cXoUq1YmFd0sSg2wHjA6Ni8xBkLye="
      key_id    = "gke-worker-auth"
    }

    events {
      audit_enabled        = true
      observations_enabled = true
      sysevents_enabled    = true
      telemetry_enabled    = true
      sink "stderr" {
        name        = "default"
        event_types = ["*"]
        format      = "cloudevents-json"
      }
    }

  service:
    api:
      annotations:
%{ for k, v in lb_api_annotations ~}
        ${k}: "${v}"
%{ endfor ~}
    cluster:
      annotations:
%{ for k, v in lb_cluster_annotations ~}
        ${k}: "${v}"
%{ endfor ~}
