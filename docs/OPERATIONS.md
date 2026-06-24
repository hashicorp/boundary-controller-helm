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
- Sensitive values are not stored in the ConfigMap. They are sourced from an existing Kubernetes Secret via `valueFrom.secretKeyRef` in controller and hook job containers.
- The ops Service defaults to `ClusterIP` and is not exposed externally.
- The cluster Service defaults to `ClusterIP` on port `9201` for internal worker registration and controller cluster traffic. Review service exposure carefully if you override `controller.service.*`.

## Prerequisites Checklist

Before installing or upgrading, confirm the following:

- A Kubernetes Secret exists in the target namespace with the keys referenced by `secretRefs.secretName` and `secretRefs.keys.*`.
- PostgreSQL is reachable from the cluster and the configured user has the required permissions.
- Your selected KMS provider is provisioned and the controller has the required IAM/RBAC permissions.
- For multi-replica deployments, `public_cluster_addr` is set to an address workers can reach.
- A Kubernetes TLS Secret matching `tls.secretName` exists when TLS is enabled.

## Installation Verification

After install or upgrade, verify the release state:

```bash
kubectl get pods -n boundary
kubectl get svc -n boundary
kubectl get jobs -n boundary
kubectl logs deployment/boundary-controller -n boundary
```

Confirm that:

- Controller pods become Ready.
- Database hook Jobs complete successfully when enabled.
- The bootstrap admin Job completes successfully when enabled.
- The API endpoint is reachable from the intended client network.
- Controller logs do not show database, KMS, or listener startup errors.

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

## Values Reference

The following tables list every Helm value, its default, and a description.

### Naming and namespace values

| Key | Default | Description |
| --- | --- | --- |
| `nameOverride` | `""` | Overrides the chart-generated resource base name |
| `fullnameOverride` | `""` | Fully overrides the chart-generated resource name |
| `namespace` | `""` | Overrides the namespace for namespaced resources. Empty uses the Helm release namespace. |

### Image values

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `hashicorp/boundary-enterprise` | Controller image repository |
| `image.tag` | `""` | Controller image tag. When empty, the chart uses `Chart.appVersion`. |
| `image.pullPolicy` | `IfNotPresent` | Kubernetes image pull policy |
| `imagePullSecrets` | `[]` | Optional image pull secrets for private registries |

### TLS values

| Key | Default | Description |
| --- | --- | --- |
| `tls.disabled` | `false` | When `true`, disables TLS: no Secret is mounted and probes use HTTP. Default `false` enables TLS with HTTPS probes. |
| `tls.secretName` | `boundary-controller-tls` | Name of the Kubernetes TLS Secret mounted when TLS is enabled |
| `tls.mountPath` | `/etc/boundary/tls` | Container path where the TLS Secret is mounted |

### Secret reference values

| Key | Default | Description |
| --- | --- | --- |
| `secretRefs.secretName` | `boundary-controller-secrets` | Existing Secret that contains database, license, and bootstrap admin values |
| `secretRefs.validateExisting` | `false` | When `true`, validates the referenced Secret and required keys during rendering |
| `secretRefs.keys.databaseUrl` | `database-url` | Secret key injected as `BOUNDARY_PG_URL` |
| `secretRefs.keys.migrationUrl` | `migration-url` | Secret key injected as `BOUNDARY_PG_MIGRATION_URL` when referenced in `controller.config` |
| `secretRefs.keys.license` | `license` | Secret key injected as `BOUNDARY_LICENSE` |
| `secretRefs.keys.adminUsername` | `admin-username` | Secret key used by the bootstrap admin Job |
| `secretRefs.keys.adminPassword` | `admin-password` | Secret key used by the bootstrap admin Job |

### Controller runtime values

| Key | Default | Description |
| --- | --- | --- |
| `controller.replicas` | `2` | Number of controller replicas in the Deployment |
| `controller.rollingUpdate.maxUnavailable` | `1` | Maximum unavailable pods during a rolling update |
| `controller.rollingUpdate.maxSurge` | `1` | Maximum extra pods during a rolling update |
| `controller.config` | Embedded sample HCL | Boundary controller HCL stored in a ConfigMap and mounted into the controller container and hook Jobs |

### Listener Service values

#### API Service

| Key | Default | Description |
| --- | --- | --- |
| `controller.service.api.type` | `LoadBalancer` | Kubernetes Service type for Boundary API traffic |
| `controller.service.api.port` | `9200` | Service port for API traffic |
| `controller.service.api.targetPort` | `9200` | Container port targeted by the API Service. Must match the API listener in `controller.config`. |
| `controller.service.api.annotations` | `{}` | Annotations added to the API Service |

#### Cluster Service

| Key | Default | Description |
| --- | --- | --- |
| `controller.service.cluster.type` | `ClusterIP` | Kubernetes Service type for worker registration and controller cluster traffic |
| `controller.service.cluster.port` | `9201` | Service port for cluster traffic |
| `controller.service.cluster.targetPort` | `9201` | Container port targeted by the cluster Service. Must match the cluster listener in `controller.config`. |
| `controller.service.cluster.annotations` | `{}` | Annotations added to the cluster Service |

#### Ops Service

| Key | Default | Description |
| --- | --- | --- |
| `controller.service.ops.type` | `ClusterIP` | Kubernetes Service type for health and metrics traffic |
| `controller.service.ops.port` | `9203` | Service port for the operations endpoint |
| `controller.service.ops.targetPort` | `9203` | Container port targeted by the ops Service. Must match the ops listener in `controller.config`. |
| `controller.service.ops.annotations` | `{}` | Annotations added to the ops Service |

### Probe values

Probe schemes are auto-derived from `tls.disabled`: `HTTPS` when `tls.disabled=false`, `HTTP` when `tls.disabled=true`. Override per-probe with `scheme` if needed.

| Key | Default | Description |
| --- | --- | --- |
| `controller.livenessProbe.scheme` | `""` | Probe scheme for `/health` on the ops listener. Auto-derived from `tls.disabled`. Override if needed. |
| `controller.livenessProbe.initialDelaySeconds` | `60` | Initial liveness probe delay |
| `controller.livenessProbe.periodSeconds` | `10` | Liveness probe period |
| `controller.livenessProbe.failureThreshold` | `3` | Liveness probe failure threshold |
| `controller.livenessProbe.timeoutSeconds` | `5` | Liveness probe timeout |
| `controller.readinessProbe.scheme` | `""` | Readiness probe scheme for `/health` on the ops listener. Auto-derived from `tls.disabled`. Override if needed. |
| `controller.readinessProbe.initialDelaySeconds` | `15` | Initial readiness probe delay |
| `controller.readinessProbe.periodSeconds` | `10` | Readiness probe period |
| `controller.readinessProbe.failureThreshold` | `3` | Readiness probe failure threshold |
| `controller.readinessProbe.timeoutSeconds` | `5` | Readiness probe timeout |

### Resource values

| Key | Default | Description |
| --- | --- | --- |
| `controller.resources.requests.cpu` | `250m` | CPU request for the controller container |
| `controller.resources.requests.memory` | `512Mi` | Memory request for the controller container |
| `controller.resources.limits.cpu` | `500m` | CPU limit for the controller container |
| `controller.resources.limits.memory` | `1Gi` | Memory limit for the controller container |

### Database job values

| Key | Default | Description |
| --- | --- | --- |
| `database.init.enabled` | `false` | Runs the pre-install database initialization Job |
| `database.migrate.enabled` | `false` | Runs the pre-upgrade database migration Job |
| `database.repair.version` | `""` | When set with `database.migrate.enabled=true`, also runs a pre-upgrade repair migration Job for the specified version |
| `database.resources.requests.cpu` | `100m` | CPU request for database Jobs |
| `database.resources.requests.memory` | `128Mi` | Memory request for database Jobs |
| `database.resources.limits.cpu` | `500m` | CPU limit for database Jobs |
| `database.resources.limits.memory` | `512Mi` | Memory limit for database Jobs |

### Bootstrap admin values

| Key | Default | Description |
| --- | --- | --- |
| `bootstrapAdmin.enabled` | `false` | Runs the bootstrap admin Job after install |
| `bootstrapAdmin.runOnUpgrade` | `false` | Also runs the bootstrap admin Job after upgrades when `true` |
| `bootstrapAdmin.waitTimeoutSeconds` | `120` | Maximum time the bootstrap Job waits for the controller API to become reachable |
| `bootstrapAdmin.authMethodName` | `bootstrap-auth-method` | Name of the password auth method created or reused by the Job |
| `bootstrapAdmin.userResourceName` | `bootstrap-admin` | Boundary user resource name created or reused by the Job |
| `bootstrapAdmin.accountResourceName` | `bootstrap-admin` | Boundary account resource name created or reused by the Job |
| `bootstrapAdmin.roleName` | `bootstrap-global-admin` | Boundary role name created or reused by the Job |
| `bootstrapAdmin.resources.requests.cpu` | `100m` | CPU request for the bootstrap Job |
| `bootstrapAdmin.resources.requests.memory` | `128Mi` | Memory request for the bootstrap Job |
| `bootstrapAdmin.resources.limits.cpu` | `500m` | CPU limit for the bootstrap Job |
| `bootstrapAdmin.resources.limits.memory` | `512Mi` | Memory limit for the bootstrap Job |

### Security context values

| Key | Default | Description |
| --- | --- | --- |
| `podSecurityContext.runAsUser` | `100` | UID the pod runs as |
| `podSecurityContext.runAsGroup` | `1000` | GID the pod runs as |
| `podSecurityContext.runAsNonRoot` | `true` | Requires the container to run as a non-root user |
| `podSecurityContext.fsGroup` | `1000` | GID applied to mounted volumes |
| `podSecurityContext.fsGroupChangePolicy` | `OnRootMismatch` | Controls when Kubernetes recursively changes volume ownership |
| `podSecurityContext.seccompProfile.type` | `RuntimeDefault` | Seccomp profile applied to the pod |
| `containerSecurityContext.runAsNonRoot` | `true` | Requires the container to run as non-root |
| `containerSecurityContext.runAsUser` | `100` | UID the container runs as |
| `containerSecurityContext.runAsGroup` | `1000` | GID the container runs as |
| `containerSecurityContext.allowPrivilegeEscalation` | `false` | Prevents the process from gaining additional privileges |
| `containerSecurityContext.readOnlyRootFilesystem` | `true` | Mounts the container root filesystem as read-only |
| `containerSecurityContext.capabilities.drop` | `["ALL"]` | Linux capabilities dropped from the container |
| `containerSecurityContext.seccompProfile.type` | `RuntimeDefault` | Seccomp profile applied to the container |

### ServiceAccount values

| Key | Default | Description |
| --- | --- | --- |
| `serviceAccount.name` | `default` | Existing ServiceAccount used by the Deployment and hook Jobs. The chart does not create a ServiceAccount. |
| `serviceAccount.automountServiceAccountToken` | `false` | Controls whether the pod service account token is mounted |

### Availability and shutdown values

| Key | Default | Description |
| --- | --- | --- |
| `podDisruptionBudget.enabled` | `true` | Creates a PodDisruptionBudget for controller pods |
| `podDisruptionBudget.minAvailable` | `1` | Minimum available controller pods during voluntary disruptions |
| `podDisruptionBudget.maxUnavailable` | not set | Optional alternative to `minAvailable`. Use only one of the two. |
| `terminationGracePeriodSeconds` | `15` | Kubernetes termination grace period before SIGKILL. Must exceed `graceful_shutdown_wait_duration` in `controller.config`. |

### Scheduling values

| Key | Default | Description |
| --- | --- | --- |
| `podAnnotations` | `{}` | Additional pod annotations |
| `nodeSelector` | `{}` | Node selector constraints |
| `tolerations` | `[]` | Pod tolerations |
| `affinity` | `{}` | Pod affinity rules |

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

TLS for the API listener (port 9200) and ops listener (port 9203) is controlled by two independent settings:

- `tls.disabled` — Helm value that controls whether the TLS Secret is mounted and whether probes use HTTPS or HTTP.
- `tls_disable` inside `controller.config` — HCL field in each listener block that tells the Boundary process itself whether to use TLS.

These two settings are **independent**. The default `controller.config` in `values.yaml` uses plain literal values — there are no Helm template expressions in the listener blocks. When you change `tls.disabled`, you must also manually update the `tls_disable`, `tls_cert_file`, and `tls_key_file` fields in your `controller.config` override to match.

### Enabling TLS — Helm values

Set `tls.disabled: false` in your values override so the chart mounts the TLS Secret and switches probes to HTTPS. Then create a Kubernetes TLS Secret whose name matches `tls.secretName` (default: `boundary-controller-tls`):

```bash
kubectl create secret tls boundary-controller-tls \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n boundary
```

### Enabling TLS — controller config

In your `controller.config` override, update the TLS fields in each listener to match `tls.mountPath` (default: `/etc/boundary/tls`):

```hcl
listener "tcp" {
  address       = "0.0.0.0:9200"
  purpose       = "api"
  tls_disable   = false
  tls_cert_file = "/etc/boundary/tls/tls.crt"
  tls_key_file  = "/etc/boundary/tls/tls.key"
}

listener "tcp" {
  address       = "0.0.0.0:9203"
  purpose       = "ops"
  tls_disable   = false
  tls_cert_file = "/etc/boundary/tls/tls.crt"
  tls_key_file  = "/etc/boundary/tls/tls.key"
}
```

If you change `tls.mountPath` from its default, update the `tls_cert_file` / `tls_key_file` paths to match.

The chart validates that `tls_cert_file` and `tls_key_file` paths are aligned with `tls.mountPath` when `tls.disabled=false`. If the paths do not match, rendering fails with an actionable error.

Alternatively, because `controller.config` is evaluated through Helm's `tpl` function, you can use Helm template expressions scoped to just the TLS fields to keep them in sync automatically:

```hcl
  tls_disable   = {{ .Values.tls.disabled }}
  tls_cert_file = "{{ .Values.tls.mountPath }}/tls.crt"
  tls_key_file  = "{{ .Values.tls.mountPath }}/tls.key"
```

With this approach, flipping `tls.disabled` in your values automatically updates both the Helm-side behaviour (Secret mount, probe scheme) and the HCL passed to the Boundary process.

### Disabling TLS (development/testing only)

The default `values.yaml` ships with TLS **enabled** (`tls.disabled: false`). For local development or testing, disable TLS in your values override:

```yaml
tls:
  disabled: true
```

The embedded default `controller.config` in `values.yaml` already sets `tls_disable = true` in each listener. If you use TLS in production, update those listener fields to match `tls.mountPath` as shown in the sections above.

### Liveness and readiness probes

Probe schemes are auto-derived from `tls.disabled`:

- `HTTPS` when `tls.disabled: false`
- `HTTP` when `tls.disabled: true`

Override per-probe with `controller.livenessProbe.scheme` / `controller.readinessProbe.scheme` if needed.


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

### Upgrade preparation checklist

Before upgrading the chart or Boundary version:

- Back up PostgreSQL before any upgrade that may include schema changes.
- Test the upgrade in a non-production environment first.
- Review Boundary and chart compatibility, including any required configuration changes.
- Verify KMS access, Secret contents, and service exposure assumptions before rollout.
- Ensure the cluster has enough capacity for the rollout strategy.

### Database migration workflow

Database migrations are operationally different from ordinary chart upgrades. `boundary database migrate` requires exclusive access to the database schema, so active controllers should be scaled down before running migration hooks.

Scale controllers to zero before running a migration-oriented upgrade:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --wait
```

Run migration as a one-time action:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --set database.migrate.enabled=true \
  --wait
```

If a failed migration requires repair, set `database.repair.version` to the failed version id and rerun the upgrade:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --set database.migrate.enabled=true \
  --set database.repair.version=<version_id> \
  --wait
```

Operational notes:

- Treat `database.migrate.enabled` and `database.repair.version` as one-time operational flags rather than persistent values.
- Helm rollback does not reverse database schema changes.
- If you use CLI `--set` overrides for one-time migration flags, follow up with a normal upgrade using your versioned values so those overrides do not persist unexpectedly.

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

### Uninstall behavior

```bash
helm uninstall boundary-controller -n boundary
```

Operational notes:

- `helm uninstall` removes release-managed resources created by the chart, but does not remove the PostgreSQL database.
- Hook Jobs are ephemeral operational resources and may remain briefly after uninstall until Kubernetes garbage collection removes them.
- Hook Jobs use `ttlSecondsAfterFinished`, so completed or failed Jobs are cleaned up automatically after their TTL expires.
- Hook Jobs use `backoffLimit`, so Kubernetes may retry failed Jobs before marking them failed.

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
