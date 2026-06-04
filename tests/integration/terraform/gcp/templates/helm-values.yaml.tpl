# Copyright IBM Corp. 2026
# This file is rendered by Terraform's templatefile() function.
# Variables: tls_disabled, gcp_project_id, kms_location, kms_key_ring,
#            kms_root_key, kms_recovery_key, kms_worker_auth_key,
#            lb_api_annotations, lb_cluster_annotations

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

    kms "gcpckms" {
      purpose    = "root"
      project    = "${gcp_project_id}"
      region     = "${kms_location}"
      key_ring   = "${kms_key_ring}"
      crypto_key = "${kms_root_key}"
    }

    kms "gcpckms" {
      purpose    = "recovery"
      project    = "${gcp_project_id}"
      region     = "${kms_location}"
      key_ring   = "${kms_key_ring}"
      crypto_key = "${kms_recovery_key}"
    }

    kms "gcpckms" {
      purpose    = "worker-auth"
      project    = "${gcp_project_id}"
      region     = "${kms_location}"
      key_ring   = "${kms_key_ring}"
      crypto_key = "${kms_worker_auth_key}"
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

# Workload Identity requires the projected service account token to be mounted
# so the GKE metadata server can exchange it for a GCP identity.
# The chart default is false; override to true for GKE + Cloud KMS deployments.
serviceAccount:
  automountServiceAccountToken: true
