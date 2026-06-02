# Copyright IBM Corp. 2026
# This file is rendered by Terraform's templatefile() function.
# Variables: tls_disabled, aws_region, kms_root_alias, kms_recovery_alias,
#            kms_worker_alias, nlb_api_annotations, nlb_cluster_annotations

controller:
  config: |
    disable_mlock = true

    listener "tcp" {
      address = "0.0.0.0:9200"
      purpose = "api"
      tls_disable   = ${tls_disabled}
      tls_cert_file = "/etc/boundary/tls/tls.crt"
      tls_key_file  = "/etc/boundary/tls/tls.key"
    }

    listener "tcp" {
      address = "0.0.0.0:9201"
      purpose = "cluster"
    }

    listener "tcp" {
      address = "0.0.0.0:9203"
      purpose = "ops"
      tls_disable   = ${tls_disabled}
      tls_cert_file = "/etc/boundary/tls/tls.crt"
      tls_key_file  = "/etc/boundary/tls/tls.key"
    }

    controller {
      name        = "boundary-controller"
      description = "Boundary Controller running on EKS"
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

    kms "awskms" {
      purpose    = "root"
      region     = "${aws_region}"
      kms_key_id = "${kms_root_alias}"
    }

    kms "awskms" {
      purpose    = "recovery"
      region     = "${aws_region}"
      kms_key_id = "${kms_recovery_alias}"
    }

    kms "awskms" {
      purpose    = "worker-auth"
      region     = "${aws_region}"
      kms_key_id = "${kms_worker_alias}"
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
%{ for k, v in nlb_api_annotations ~}
        ${k}: "${v}"
%{ endfor ~}
    cluster:
      annotations:
%{ for k, v in nlb_cluster_annotations ~}
        ${k}: "${v}"
%{ endfor ~}
