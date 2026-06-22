# Boundary Controller Helm Chart

## Security Model

The chart runs controller containers with restricted Kubernetes security settings:

- Runs as non-root (`runAsUser: 100`, `runAsGroup: 1000`)
- Drops all Linux capabilities
- Disables privilege escalation
- Sets `SKIP_SETCAP=1` to avoid capability modification at startup
- Enforces `RuntimeDefault` seccomp profile
- Sets `fsGroup: 1000` so mounted volumes are accessible by the container user
- Uses `fsGroupChangePolicy: OnRootMismatch` to avoid unnecessary recursive ownership changes on every mount

Operational implications:

- `disable_mlock = true` should remain set in the controller configuration when using this deployment model.
- Secret validation (`secretRefs.validateExisting`) is opt-in; when enabled, Helm validates that the Secret exists before any resources are created.



## Configuration Model

The chart splits configuration into two distinct layers.

### 1. Boundary runtime configuration

The actual controller behavior is defined by `controller.config`, which is supplied as raw HCL content. The chart stores it in a ConfigMap and mounts it into all controller containers and hook job containers.

Important characteristics:

- The chart renders `controller.config` through Helm's `tpl` function, so Helm template expressions inside the HCL are evaluated.
- The chart validates that `tls_cert_file` and `tls_key_file` paths are aligned with `tls.mountPath` when `tls.disabled=false`.
- The chart validates that AEAD `env://` key indirection is not used inside `kms` blocks (Boundary does not support this).
- The operator is responsible for keeping listener ports, KMS stanzas, and cluster addresses aligned with the Kubernetes resources.
- The chart does not validate the HCL content of `controller.config` beyond the checks listed above. Ensuring the configuration is syntactically and semantically correct is the operator's responsibility.

### 2. Kubernetes infrastructure configuration

Kubernetes-specific settings control how the controller runs in Kubernetes — image, resources, services, security contexts, scheduling, and service account configuration. These do not replace or generate the Boundary runtime configuration. See [values.yaml](values.yaml) for the full list of available values.

## Required Controller Configuration

This chart ships with an embedded default `controller.config` that uses `aead` for KMS. AEAD is suitable for development and testing only — keys are stored in plaintext in the ConfigMap. Replace with a proper KMS provider before deploying to production.

At minimum, a usable controller config must include:

- Listener blocks for `api`, `cluster`, and `ops` traffic
- A `controller` block with `name`, `license`, and `database.url`
- `public_cluster_addr` so workers can reach the cluster listener. If `controller.service.cluster.type=LoadBalancer`, set this to the externally reachable LoadBalancer address (DNS name or IP with port `9201`) after the Service is provisioned, then apply an update. You can also source it from an env var (for example `public_cluster_addr = "env://BOUNDARY_PUBLIC_CLUSTER_ADDR"`) when using `extraEnv`.
- At least three KMS stanzas: `root`, `recovery`, and `worker-auth`

Example:

```hcl
disable_mlock = true

listener "tcp" {
  address       = "0.0.0.0:9200"
  purpose       = "api"
  tls_cert_file = "/etc/boundary/tls/tls.crt"
  tls_key_file  = "/etc/boundary/tls/tls.key"
}

listener "tcp" {
  address       = "0.0.0.0:9201"
  purpose       = "cluster"
}

listener "tcp" {
  address       = "0.0.0.0:9203"
  purpose       = "ops"
  tls_cert_file = "/etc/boundary/tls/tls.crt"
  tls_key_file  = "/etc/boundary/tls/tls.key"
}

controller {
  name                            = "boundary-controller"
  description                     = "Boundary Controller running in Kubernetes"
  public_cluster_addr             = "boundary-cluster:9201"
  license                         = "env://BOUNDARY_LICENSE"
  graceful_shutdown_wait_duration = "10s"
  database {
    url = "env://BOUNDARY_PG_URL"
  }
}

# AEAD is for development and testing only — keys are stored in plaintext.
# Replace with a production KMS provider before deploying to production.
kms "aead" {
  purpose   = "root"
  aead_type = "aes-gcm"
  key       = "sP1fnF5Xz85RrXyELHFeZg9Ad2qt4Z4bgNHVGtD6ung="
}

kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "8fZBjCUfozI8/xQhAFb0LRHuUFb/tDMGVJzCmVm0R+8="
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "iHdyGULJrLHmEBzMt8n3g6a4w8xm5jJZKQBr0+6OZIA="
}
```

Because the chart evaluates `controller.config` with Helm `tpl`, Helm template expressions inside the HCL are supported. For example, `{{ include "boundary.controller.clusterServiceName" . }}` resolves to the cluster Service name at render time.

## TLS

TLS is required for the API listener on port 9200. The chart must be deployed with `tls.disabled=false` and a valid Kubernetes TLS Secret present. The chart expects a TLS Secret named by `tls.secretName` containing `tls.crt` and `tls.key`. That Secret is mounted at `tls.mountPath` in all controller and job containers.

The chart validates that `controller.config` references `tls.mountPath` for both `tls_cert_file` and `tls_key_file`. If the paths do not match, rendering fails with an actionable error.

To enable TLS:

1. Set `tls.disabled=false`
2. Configure `controller.config` listeners with `tls_disable = false` and cert/key file paths under `tls.mountPath`

The liveness and readiness probe schemes are auto-derived from `tls.disabled`:

- `HTTPS` when `tls.disabled=false`
- `HTTP` when `tls.disabled=true`


## Common Configuration Patterns

### Database ops flags

Use these values to control database operational hooks:

```yaml
database:
  init:
    enabled: true
  migrate:
    enabled: false
  repair:
    version: ""
```

### Disable bootstrap admin

If you manage admin accounts externally, disable the bootstrap job:

```yaml
bootstrapAdmin:
  enabled: false
```

### Check hook job status

Use these commands to inspect the status and logs of the database and bootstrap hook jobs after install or upgrade.

Check whether jobs completed successfully:

```bash
kubectl get jobs -n boundary
```

View logs for the database init job:

```bash
kubectl logs -n boundary job/boundary-controller-init-db
```

View logs for the bootstrap admin job:

```bash
kubectl logs -n boundary job/boundary-controller-bootstrap-admin
```

### External secret providers

To use an external secret provider, configure the [External Secrets Operator](https://external-secrets.io) with your provider backend to sync the required values into a Kubernetes Secret before install. Set `secretRefs.secretName` to match the Secret name the operator creates. The chart reads it the same way as a manually created Secret.

### Offline rendering without cluster access

Secret validation requires a live cluster connection. Disable it for `helm template` runs:

```yaml
secretRefs:
  validateExisting: false
```

## Operations

### Rollback

If an upgrade fails or causes issues, use `helm rollback` to revert to a previous release state.

View release history to find the revision to roll back to:

```bash
helm history boundary-controller -n boundary
```

Roll back to the previous revision:

```bash
helm rollback boundary-controller -n boundary
```

Roll back to a specific revision:

```bash
helm rollback boundary-controller <revision> -n boundary
```

Database migrations are **not automatically reversed** on Helm rollback. If a migration was applied during the failed upgrade, restore the database from the pre-migration backup.


## Monitoring

### Health

The ops listener (port 9203) on the internal cluster Service (`ClusterIP`) exposes the `/health` endpoint used by the Kubernetes liveness and readiness probes. It is not reachable externally. Use `kubectl port-forward` to access it manually:

```bash
kubectl port-forward -n boundary svc/boundary-controller-ops 9203:9203
curl http://localhost:9203/health
```

If `tls.disabled=false` and your ops listener uses TLS, use:

```bash
curl -k https://localhost:9203/health
```

See [Monitor health](https://developer.hashicorp.com/boundary/docs/monitor/health) for the full response schema and shutdown grace period configuration.

### Metrics

Boundary controllers expose Prometheus-compatible metrics on the ops listener. See [Monitor metrics](https://developer.hashicorp.com/boundary/docs/monitor/metrics) for the full list of available metrics and labeling conventions, and the [Visualize metrics with Prometheus](https://developer.hashicorp.com/boundary/tutorials/self-managed-deployment/prometheus-metrics) tutorial for an end-to-end setup.

If you use the Prometheus Operator, create a ServiceMonitor targeting the cluster Service:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: boundary-controller
  namespace: boundary
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: boundary-controller
      app.kubernetes.io/component: controller
  endpoints:
  - port: ops
    path: /metrics
    scheme: https
    tlsConfig:
      insecureSkipVerify: true
    interval: 30s
```

### Event Logging

Boundary uses a structured [CloudEvents](https://cloudevents.io)-based event system for observability, auditing, and error reporting. This replaces traditional log levels. Configure event sinks in the `events` block of `controller.config`:

```hcl
events {
  audit_enabled        = true
  observations_enabled = true
  sysevents_enabled    = true

  sink "stderr" {
    name        = "all-events"
    description = "All events to stderr"
    event_types = ["*"]
    format      = "hclog-text"
  }

  sink "file" {
    name        = "audit-sink"
    description = "Audit events to file"
    event_types = ["audit"]
    format      = "hclog-text"
    file {
      path      = "/var/log/boundary"
      file_name = "audit.log"
    }
  }
}
```

For full sink configuration options and event filtering, see the official docs:

- [Filter events](https://developer.hashicorp.com/boundary/docs/monitor/events/filter-events)
- [Common sink parameters](https://developer.hashicorp.com/boundary/docs/monitor/events/common)
- [File sink](https://developer.hashicorp.com/boundary/docs/monitor/events/file)
- [Stderr sink](https://developer.hashicorp.com/boundary/docs/monitor/events/stderr)
- [Event filtering tutorial](https://developer.hashicorp.com/boundary/tutorials/self-managed-deployment/event-logging)

### Alerting Recommendations

Set up alerts for:

1. **Pod Availability**: Alert if available replicas < desired replicas
2. **Pod Restarts**: Alert on pods restarting more than 3 times in 10 minutes
3. **Database Connectivity**: Alert on database connection failures in event logs
4. **KMS Access Issues**: Alert on KMS authentication failures in event logs
5. **Resource Exhaustion**: Alert on high CPU/memory usage (>80% of limits)
6. **Certificate Expiration**: Alert 30 days before TLS cert expiry
7. **Failed Hook Jobs**: Alert if database init or migration jobs fail

## Testing

The chart includes comprehensive acceptance tests for validation before deployment. See [docs/TESTING.md](docs/TESTING.md) for detailed testing documentation.

## Known Limitations

The current chart intentionally does not attempt to solve the following problems:

- Horizontal pod autoscaling
- TLS certificate issuance or renewal — the chart expects a pre-existing Kubernetes TLS Secret (`tls.crt` / `tls.key`); it does not integrate with cert-manager, ACM, or any other certificate authority
- Ingress or DNS automation
