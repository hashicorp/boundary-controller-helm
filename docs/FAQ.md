# Boundary Controller Helm Chart — FAQ

## Installation

### Why does `helm install` fail immediately with a "Secret not found" error?

`controller.secretRefs.validateExisting` defaults to `false` in `values.yaml` but if you have set it to `true`, the chart validates that the Kubernetes Secret exists and contains all required keys at render time. Install fails if the Secret is absent or missing a key.

Either create the Secret before installing:

```bash
kubectl create secret generic boundary-controller-secrets \
  --namespace boundary \
  --from-literal=database-url="postgres://..." \
  --from-literal=license="<license>" \
  --from-literal=admin-username="admin" \
  --from-literal=admin-password="<password>"
```

Or disable validation for offline / dry-run use:

```yaml
controller:
  secretRefs:
    validateExisting: false
```

---

### Why does rendering fail with `controller.config uses env://BOUNDARY_KMS_*`?

Boundary AEAD KMS stanzas do not support `env://` key indirection at runtime. The chart catches this at render time and fails with:

```
controller.config uses env://BOUNDARY_KMS_* inside AEAD kms blocks. Boundary AEAD keys do not support env:// indirection.
```

For production use an external KMS stanza (`awskms`, `gcpckms`, `azurekeyvault`, or `transit`) that fetches the key from a key management service. For local testing only, inline the raw AEAD key directly in the `kms` block instead of referencing it via `env://`.

---

### Why does rendering fail with a `tls_cert_file` path error?

When `tls.disabled=false` (the default), the chart validates that `controller.config` contains `tls_cert_file` and `tls_key_file` paths that match `tls.mountPath`. If the paths in your HCL do not match — for example because you customised `tls.mountPath` without updating the listener blocks — rendering fails with:

```
tls.disabled=false but controller.config is missing expected cert path "/etc/boundary/tls/tls.crt"
```

Keep the paths in your `listener` blocks aligned with `tls.mountPath`, or update `tls.mountPath` to match your HCL. If you are disabling TLS entirely, set `tls.disabled=true` and add `tls_disable = true` to each listener.

---

### Can I run `helm template` without a live cluster?

Yes. Secret validation requires cluster access and is skipped when `controller.secretRefs.validateExisting=false` (the default). If you have set it to `true`, disable it for offline rendering:

```bash
helm template boundary-controller . \
  --namespace boundary \
  --set controller.secretRefs.validateExisting=false \
  -f my-values.yaml
```

---

## Performance & Scaling

### How do I scale controller replicas?

Set `controller.replicas` in your values file. Two replicas is the default and matches the PodDisruptionBudget default of `minAvailable=1`:

```yaml
controller:
  replicas: 3
```

For multi-replica deployments `public_cluster_addr` must be set in `controller.config` to a stable address that all workers can reach — typically the DNS name of the cluster Service. If this is not set, workers will attempt to register against an individual pod IP, which breaks when that pod is replaced. The chart default uses the template helper `{{ include "boundary.controller.clusterServiceName" . }}:9201` which resolves to the cluster Service DNS name automatically.

The PodDisruptionBudget (`podDisruptionBudget.minAvailable=1`) guarantees at least one replica remains available during voluntary disruptions such as node drains and cluster upgrades. Increasing replicas without also reviewing `minAvailable` may leave only one replica protected during a drain.

---

### What resource limits should I set for production?

The chart defaults are conservative starting points:

| | CPU request | CPU limit | Memory request | Memory limit |
|---|---|---|---|---|
| Default | `250m` | `500m` | `512Mi` | `1Gi` |

A controller handling moderate API and session load (hundreds of concurrent sessions, multiple workers) typically needs `500m`–`1000m` CPU and `512Mi`–`1Gi` memory. Monitor actual usage with:

```bash
kubectl top pods -n boundary
```

Adjust limits upward if you see CPU throttling (check `container_cpu_throttled_seconds_total` in Prometheus) or OOMKill events (`kubectl describe pod -n boundary`). Set requests close to your observed p95 usage and limits at 2x requests to allow for bursts without throttling healthy pods.

---

### How do I configure API rate limiting?

The default `controller.config` in `values.yaml` includes three `api_rate_limit` blocks as a starting point:

- **Total**: 500 requests/second across all resources and actions — protects the controller from aggregate overload.
- **Per IP address**: 100 requests/second per client IP — limits a single misbehaving or compromised host from exhausting the total.
- **Per auth token**: 100 requests/second per authenticated token — prevents one user from consuming the entire per-IP budget.

Adjust these based on your environment. A deployment serving many automated workers making frequent heartbeat calls may need higher per-IP and per-token limits. A deployment with strict multi-tenancy requirements may need lower per-token limits. See the [Boundary rate limiting documentation](https://developer.hashicorp.com/boundary/docs/configuration/controller#api_rate_limit-parameters) for all available parameters.

---

## Networking & Services

### Why are there three separate Services?

Each Boundary listener has a distinct purpose and different exposure requirements:

| Service | Port | Default type | Purpose |
|---|---|---|---|
| `boundary-controller` | 9200 | `LoadBalancer` | Client API traffic — Boundary CLI, UI, and Terraform provider connect here |
| `boundary-controller-cluster` | 9201 | `LoadBalancer` | Worker registration — self-managed workers dial this address to join the cluster |
| `boundary-controller-ops` | 9203 | `ClusterIP` | Health checks and Prometheus metrics — internal only |

Separating them allows different exposure strategies: the API Service can be internet-facing while the cluster Service is internal-only, and the ops Service never leaves the cluster. It also makes firewall rules and Service annotations more precise.

---

### How do I expose the API Service with an internal load balancer?

Add the appropriate annotation to `controller.service.api.annotations` for your cloud provider:

**AWS (NLB internal):**
```yaml
controller:
  service:
    api:
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "external"
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
```

**GCP (internal passthrough NLB):**
```yaml
controller:
  service:
    api:
      annotations:
        networking.gke.io/load-balancer-type: "Internal"
```

**Azure (internal):**
```yaml
controller:
  service:
    api:
      annotations:
        service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

Apply the same pattern to `controller.service.cluster.annotations` if the cluster listener also needs to be internal.

---

### Can I change the default listener ports?

Yes, but you must update both the chart values and `controller.config` together — the chart does not synchronise them automatically.

Example: change the API listener from 9200 to 8200:

```yaml
controller:
  service:
    api:
      port: 8200
      targetPort: 8200
  config: |
    listener "tcp" {
      address = "0.0.0.0:8200"
      purpose = "api"
      tls_disable = true
    }
    # ... cluster (9201), ops (9203), controller, kms blocks
```

The liveness and readiness probes target port `9203` (ops) by `targetPort` name — those do not need to change unless you also change the ops port.

---

### How do I configure CORS for the API listener?

Add a `cors_enabled` and `cors_allowed_origins` stanza to the `api` listener block in `controller.config`:

```hcl
listener "tcp" {
  address     = "0.0.0.0:9200"
  purpose     = "api"
  tls_disable = true

  cors_enabled         = true
  cors_allowed_origins = ["https://boundary.example.com"]
}
```

Use `["*"]` only in development environments. In production, restrict `cors_allowed_origins` to the exact origins that host the Boundary UI. See the [Boundary listener documentation](https://developer.hashicorp.com/boundary/docs/configuration/listener/tcp) for all available CORS parameters.

---

## Configuration

### What is the minimum required `controller.config`?

At minimum the config must include:

- Three `listener "tcp"` blocks for `api` (9200), `cluster` (9201), and `ops` (9203)
- A `controller` block with `name`, `license`, `public_cluster_addr`, and `database.url`
- Three `kms` stanzas with purposes `root`, `recovery`, and `worker-auth`

See [Required Controller Configuration](../README.md#required-controller-configuration) for a full example.

---

### How do I set `public_cluster_addr` to the cluster Service address automatically?

The chart exposes a template helper that resolves to the cluster Service name. Use it inside `controller.config` (the field is evaluated with `tpl`):

```hcl
controller {
  public_cluster_addr = "{{ include "boundary.controller.clusterServiceName" . }}:9201"
}
```

This resolves to `boundary-controller-cluster:9201` by default, which is the DNS name of the cluster Service inside the cluster.

---

### How do I use a KMS other than AWS KMS?

Replace the `kms "awskms"` stanzas in `controller.config` with the appropriate provider block. Supported providers:

| Provider | Stanza type | Auth mechanism |
|---|---|---|
| AWS KMS | `awskms` | IRSA, instance profile, or static credentials |
| GCP Cloud KMS | `gcpckms` | Workload Identity |
| Azure Key Vault | `azurekeyvault` | Managed Identity |
| Vault Transit | `transit` | Vault token or Vault Agent |

See the [Common Deployment Patterns](../README.md#common-deployment-patterns) section in the README for cloud-specific guidance and links to Boundary KMS documentation.

---

### How do I supply cloud KMS credentials to the controller pod?

The recommended approach is to use your cloud provider's workload identity mechanism so no long-lived credentials are needed:

- **AWS**: Annotate the ServiceAccount with an IAM role ARN (`eks.amazonaws.com/role-arn`) and set `serviceAccount.create=true`.
- **GCP**: Annotate the ServiceAccount with a GCP service account email (`iam.gke.io/gcp-service-account`).
- **Azure**: Use Azure Workload Identity annotations on the ServiceAccount.
- **Vault**: Inject a token or AppRole credentials via the [Vault Agent Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector) as an environment variable or file, and reference it in the `transit` KMS stanza.

---

### How do I supply the database URL securely?

Add the connection string to the Kubernetes Secret under the key configured by `controller.secretRefs.keys.databaseUrl` (default `database-url`). The chart injects it as `BOUNDARY_PG_URL` into all containers. Reference it in `controller.config` as:

```hcl
controller {
  database {
    url = "env://BOUNDARY_PG_URL"
  }
}
```

Use `sslmode=require` or higher in the connection string for production databases.

---

### How do I use a separate migration database user?

Add the migration connection string to the Secret under the key configured by `controller.secretRefs.keys.migrationUrl` (default `migration-url`). Then set `migration_url` in `controller.config`:

```hcl
controller {
  database {
    url           = "env://BOUNDARY_PG_URL"
    migration_url = "env://BOUNDARY_PG_MIGRATION_URL"
  }
}
```

Uncomment `# migrationUrl: "migration-url"` under `controller.secretRefs.keys` in your values file so the chart knows to inject that Secret key.

---

### How do I disable TLS?

Set `tls.disabled=true`, add `tls_disable = true` to each listener in `controller.config`, and update the probe schemes:

```yaml
tls:
  disabled: true

controller:
  livenessProbe:
    scheme: HTTP
  readinessProbe:
    scheme: HTTP
  config: |
    listener "tcp" {
      address     = "0.0.0.0:9200"
      purpose     = "api"
      tls_disable = true
    }
    # ... remaining listeners and controller/kms blocks
```

---

### The chart sets `disable_mlock = true`. Is that safe?

Yes, for Kubernetes deployments. The controller containers run as a non-root user with all Linux capabilities dropped, so they cannot call `mlock(2)`. Setting `disable_mlock = true` in `controller.config` tells Boundary not to attempt it. This is the recommended setting for containerised deployments.

---

### Can I use Helm template functions inside `controller.config`?

Yes. The chart renders `controller.config` through Helm's `tpl` function, so any valid Helm template expression is evaluated before the config is written to the ConfigMap.

Useful examples:

```hcl
controller {
  # Resolve the cluster Service DNS name at render time
  public_cluster_addr = "{{ include \"boundary.controller.clusterServiceName\" . }}:9201"

  # Reference a value from values.yaml
  name = "{{ .Values.nameOverride | default \"boundary-controller\" }}"
}
```

Be careful with special characters — HCL strings use `"` and Helm template delimiters also use `"`, so escaping is required when embedding template expressions inline in a YAML block scalar as shown above.

---

### How do I configure the database connection pool size?

Set `max_open_connections` inside the `database` block of `controller.config`:

```hcl
controller {
  database {
    url                 = "env://BOUNDARY_PG_URL"
    max_open_connections = 25
  }
}
```

The default when unset is determined by Boundary's internal logic. For production deployments with multiple replicas, the total connections to PostgreSQL is `max_open_connections × replicas`. Ensure your PostgreSQL `max_connections` setting can accommodate this. A starting point is `max_open_connections = 10`–`25` per replica, tuned based on observed `pg_stat_activity` connection counts.

---

### How do I add custom environment variables to the controller container?

The chart does not expose a generic `extraEnv` field. The intended pattern is to source all sensitive values from the Kubernetes Secret via `env://` references in `controller.config`, which the chart injects as named environment variables. For non-sensitive values, use Helm template expressions directly inside `controller.config` (it is evaluated with `tpl`).

If you require additional environment variables beyond what the chart injects, fork or extend the chart by modifying `templates/deployment.yaml` to add an `env` entry, or use a Helm post-renderer.

---

## Upgrades

### How do I run a database migration?

Scale the Deployment to zero first (migrations cannot acquire an exclusive PostgreSQL advisory lock while live controllers are connected), then run the upgrade with the migrate flag:

```bash
# Step 1 — drain connections
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.replicas=0

# Step 2 — migrate and bring controllers back up
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.database.migrate.enabled=true
```

Do not persist `controller.database.migrate.enabled=true` in your values file — it is a one-time flag.

> Always back up the database before running a migration. Migrations are not automatically reversed on Helm rollback.

---

### How do I run a migration repair?

Pass both `controller.database.migrate.enabled=true` and `controller.database.repair.version` together. The repair job runs first (hook weight `-10`), then the migrate job (hook weight `-5`):

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.database.migrate.enabled=true \
  --set controller.database.repair.version=20240111120000
```

The repair version must match the format `YYYYMMDDHHMMSS` or `SEQUENCE/YYYYMMDDHHMMSS` (e.g. `0/20240111120000`). The chart validates the format at render time.

---

### What happens to hook Jobs on rollback?

Helm rollback does not reverse database migrations. The `pre-upgrade` hook jobs (`init-db`, `database-migration`, `database-repair`) are not re-run during rollback. If a migration produced an unexpected schema state, restore the database from a backup and then roll back the Helm release.

Hook jobs have `ttlSecondsAfterFinished: 3600` and are deleted automatically one hour after they complete. To delete them immediately:

```bash
kubectl delete jobs -n boundary -l app.kubernetes.io/instance=boundary-controller
```

---

### Can I roll back the chart after a successful migration?

You can roll back the Kubernetes resources with `helm rollback`, but the database schema is not reversed. Running an older Boundary binary against a schema that was migrated forward will likely fail. Restore the database from a pre-migration backup if you need to fully revert.

---

### What is the difference between `terminationGracePeriodSeconds` and `graceful_shutdown_wait_duration`?

They operate at different layers:

| Setting | Default | Layer | Meaning |
|---|---|---|---|
| `graceful_shutdown_wait_duration` (in `controller.config`) | `10s` | Boundary | How long Boundary waits for in-flight requests to complete after receiving SIGTERM before forcefully closing connections |
| `terminationGracePeriodSeconds` (chart value) | `15s` | Kubernetes | How long Kubernetes waits between sending SIGTERM and sending SIGKILL |

`terminationGracePeriodSeconds` must be greater than `graceful_shutdown_wait_duration`, otherwise Kubernetes sends SIGKILL before Boundary finishes its graceful shutdown. The 5-second gap in the defaults (`15s` vs `10s`) gives Boundary time to drain and then exit cleanly before Kubernetes forcefully kills the container.

If you increase `graceful_shutdown_wait_duration` in `controller.config`, increase `terminationGracePeriodSeconds` by the same amount.

---

### What happens during a rolling update?

With the default `RollingUpdate` strategy (`maxUnavailable=1`, `maxSurge=1`) and `replicas=2`:

1. Kubernetes creates one new pod (surge), bringing total pods temporarily to 3.
2. Once the new pod passes its readiness probe, one old pod receives SIGTERM.
3. Boundary's `graceful_shutdown_wait_duration` (default `10s`) allows in-flight API requests to complete.
4. The pod exits; Kubernetes replaces the remaining old pod using the same cycle.

The PodDisruptionBudget (`minAvailable=1`) ensures that voluntary disruptions (node drains, cluster upgrades) cannot evict both pods simultaneously, keeping at least one replica serving traffic throughout.

Active sessions are maintained by workers, not controllers. A controller restart during an active session does not drop the session — workers continue proxying traffic until the session expires or is terminated.

---

### What is the backup and restore strategy?

All controller state lives in PostgreSQL. Controller pods are stateless and can be replaced or scaled without data loss.

**Backup:**
- Take regular PostgreSQL backups using your managed database provider's snapshot feature or `pg_dump`.
- Back up KMS keys (or ensure your KMS provider — AWS KMS, Vault, etc. — has its own backup and disaster recovery). If the root KMS key is lost, the Boundary database cannot be decrypted.
- Store Helm values files and the Boundary Enterprise license in version control or a secrets manager.

**Restore:**
1. Restore the PostgreSQL database from backup.
2. Ensure the KMS keys referenced in `controller.config` are accessible.
3. Re-create the Kubernetes Secret with the same credentials.
4. Run `helm install` (or `helm upgrade`) to redeploy the chart. The `db-init-job` will detect an existing schema and skip initialisation.

**Note:** After a point-in-time restore, sessions and auth tokens created after the backup timestamp will be invalid.

---

### How do I perform a zero-downtime upgrade (no schema migration)?

When upgrading the Boundary image version without a database schema change:

1. Update `image.tag` in your values file.
2. Run `helm upgrade` — the default RollingUpdate strategy replaces pods one at a time.
3. Monitor rollout progress: `kubectl rollout status deployment/boundary-controller -n boundary`.

The PodDisruptionBudget and rolling update strategy together guarantee at least one replica is available throughout. Do not set `controller.database.migrate.enabled=true` unless the Boundary release notes explicitly state a migration is required for this version.

---

## Operations

### How do I check the controller health endpoint?

The ops Service (`boundary-controller-ops`) is `ClusterIP` only. Use `kubectl port-forward` to reach it locally:

```bash
kubectl port-forward -n boundary svc/boundary-controller-ops 9203:9203
curl -k https://localhost:9203/health
```

Use `http://` instead of `https://` when `tls.disabled=true`.

---

### Controller pods are stuck in `Pending`. What should I check?

1. **Resource pressure** — Confirm the cluster has sufficient CPU/memory (`kubectl describe node`).
2. **Node selector / tolerations** — If `nodeSelector` or `tolerations` are set, verify matching nodes exist.
3. **PodDisruptionBudget** — The PDB ensures `minAvailable=1` replica. During cluster node drain, a pod may be blocked if only one replica is running.
4. **ImagePullBackOff** — Check `imagePullSecrets` and registry access.

---

### The `boundary-controller-init-db` Job failed. What should I do?

Check the job logs:

```bash
kubectl logs -n boundary job/boundary-controller-init-db
```

Common causes:

- **Database unreachable** — Verify `database-url` in the Secret points to a reachable PostgreSQL instance and the credentials are correct.
- **SSL mismatch** — Use `sslmode=require` or `sslmode=disable` consistently between your database server and the connection string.
- **Schema already initialised** — If the database was previously initialised, the init job is a no-op and should succeed. If it errors, check the Boundary logs for the specific error.

---

### The bootstrap admin Job completed but I cannot log in.

1. Confirm the job succeeded: `kubectl get job/boundary-controller-bootstrap-admin -n boundary`
2. Check the admin credentials in the Secret match what was used during install.
3. Verify the auth method name — the chart creates it with the display name set in `controller.bootstrapAdmin.authMethodName` (default `bootstrap-password`).
4. Confirm you are authenticating against the correct Boundary address and using the `password` auth method type.

If `controller.bootstrapAdmin.runOnUpgrade=false` (the default), the bootstrap job only runs on the initial install. It will not re-run on subsequent upgrades. To reset credentials, log in with an existing admin account and update them through the Boundary API.

---

### Controller pods are in `CrashLoopBackOff`. How do I debug?

Check the logs first:

```bash
kubectl logs -n boundary deployment/boundary-controller --previous
```

Common causes and how to distinguish them:

| Symptom in logs | Likely cause | Fix |
|---|---|---|
| `error reading license` / `missing license` | `BOUNDARY_LICENSE` env var not set or Secret key wrong | Verify `controller.secretRefs.keys.license` and the Secret contents |
| `unable to connect to database` / `connection refused` | PostgreSQL unreachable or wrong credentials | Check `database-url` in the Secret and network connectivity |
| `failed to initialize KMS` / `AccessDenied` | KMS permissions missing or wrong key ID | Verify IAM/Workload Identity bindings and key aliases in `controller.config` |
| `setcap: operation not permitted` | `SKIP_SETCAP=1` not set | Confirm `containerSecurityContext` has not been overridden to re-enable capabilities |
| `address already in use` | Two processes binding the same port | Should not occur with this chart; check for leftover processes from a failed init |
| `Error initializing schema` | Database init job did not complete before the Deployment started | Wait for `boundary-controller-init-db` Job to complete, then restart the Deployment |

For detailed event-based diagnostics:

```bash
kubectl describe pod -n boundary -l app.kubernetes.io/name=boundary-controller
```

---

### How do I enable verbose event logging for debugging?

Boundary uses a structured [CloudEvents](https://cloudevents.io)-based system rather than traditional log levels. To get the most diagnostic output, enable all event types and the `observations` sink in `controller.config`:

```hcl
events {
  audit_enabled        = true
  observations_enabled = true
  sysevents_enabled    = true

  sink "stderr" {
    name        = "all-events"
    event_types = ["*"]
    format      = "cloudevents-json"
  }
}
```

Observation events include request tracing and internal state transitions. Audit events record every API request and response. Both are written to stderr, which is captured by `kubectl logs`. Filter by event type using `jq`:

```bash
kubectl logs -n boundary deployment/boundary-controller \
  | jq 'select(.type | startswith("observation"))'
```

---

### How do I check which Helm revision is deployed?

```bash
helm history boundary-controller -n boundary
```

---

## Security

### Why does the chart set `SKIP_SETCAP=1`?

The Boundary container entrypoint normally calls `setcap` to grant the binary `IPC_LOCK` capability for memory locking. The container security context in this chart drops all capabilities and disallows privilege escalation, so `setcap` would fail. `SKIP_SETCAP=1` bypasses that call. Memory locking is handled at the OS level and is unnecessary in Kubernetes when `disable_mlock = true` is set in the config.

---

### Can I run the controller with a custom ServiceAccount?

Yes. Set `serviceAccount.create=true` and optionally provide a name:

```yaml
serviceAccount:
  create: true
  name: "boundary-controller"
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/boundary-controller-role
```

This is required for IRSA (AWS), Workload Identity (GCP), and Azure Workload Identity scenarios.

---

### How do I rotate KMS keys?

Boundary supports KMS key rotation through the `boundary database rotate-root-key` command (Enterprise). Coordinate key rotation with your KMS provider. The chart itself does not manage key rotation — update your KMS provider configuration independently, then update any references in `controller.config` if key aliases or paths change.

---

## Advanced Scenarios

### Can I run multiple controller releases in the same namespace?

Yes. Use a different Helm release name for each installation. Because `boundary.name` is derived from the chart name (`boundary-controller`), you must set `nameOverride` or `fullnameOverride` to prevent resource name collisions:

```bash
helm install boundary-controller-a . \
  --namespace boundary \
  --set nameOverride=boundary-controller-a \
  -f values-a.yaml

helm install boundary-controller-b . \
  --namespace boundary \
  --set nameOverride=boundary-controller-b \
  -f values-b.yaml
```

Each release must use a separate PostgreSQL database — two controllers cannot share a database unless they are replicas of the same cluster. Each release also creates its own Services, ConfigMap, ServiceAccount, and hook jobs, so the name override is mandatory to avoid conflicts.

---

### How do I integrate with the Vault Secrets Operator?

The [Vault Secrets Operator (VSO)](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) can create and sync the Kubernetes Secret that the chart reads from. Set `controller.secretRefs.secretName` to the name VSO will use, then create a `VaultStaticSecret` resource:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: boundary-controller-secrets
  namespace: boundary
spec:
  type: kv-v2
  mount: secret
  path: boundary/controller
  destination:
    name: boundary-controller-secrets   # must match controller.secretRefs.secretName
    create: true
  refreshAfter: 30s
```

The Vault KV secret at `secret/boundary/controller` must contain keys that match `controller.secretRefs.keys.*` (default names: `database-url`, `license`, `admin-username`, `admin-password`). VSO creates the Kubernetes Secret before the chart reads it, so `controller.secretRefs.validateExisting` can safely be set to `true`.

---

### Does this chart support HCP Boundary?

No. This chart deploys self-managed Boundary controllers. HCP Boundary manages the control plane (controllers) as a fully-managed service — you do not deploy controllers yourself.

If you are using HCP Boundary, use the [boundary-worker-helm](https://github.com/hashicorp/boundary-worker-helm) chart to deploy self-managed workers that connect to your HCP Boundary cluster as the data plane. There is no controller chart for HCP deployments.

---

### Does the controller handle session recording storage?

No. Session recording storage is configured on workers, not controllers. Workers write recording data to an object store (such as Amazon S3 or MinIO) specified in the worker configuration. The controller manages session policy and metadata but does not store or stream recording data.

See the boundary-worker-helm chart documentation for worker-side recording storage configuration.

---

## Monitoring

### Where is the Prometheus metrics endpoint?

Metrics are exposed on the ops listener at `/metrics` (port 9203). Because the ops Service is `ClusterIP`, use a ServiceMonitor or scrape it via `kubectl port-forward`. See the [Monitoring section](../README.md#monitoring) in the README for a ServiceMonitor example.

---

### How do I configure structured audit logging?

Add an `events` block to `controller.config`. Example for JSON audit events to stderr plus a file sink:

```hcl
events {
  audit_enabled        = true
  observations_enabled = true
  sysevents_enabled    = true

  sink "stderr" {
    name        = "all-events"
    event_types = ["*"]
    format      = "cloudevents-json"
  }

  sink "file" {
    name        = "audit-sink"
    event_types = ["audit"]
    format      = "cloudevents-json"
    file {
      path      = "/var/log/boundary"
      file_name = "audit.log"
    }
  }
}
```

The file sink path must be writable inside the container. Mount an `emptyDir` or persistent volume at that path and add a corresponding `volumeMount` via `extraVolumes` / `extraVolumeMounts` if your deployment requires persistent audit logs.
