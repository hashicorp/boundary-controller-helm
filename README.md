# Boundary Controller Helm Chart

This chart deploys HashiCorp Boundary's controller — the control-plane component responsible for authentication, authorization, session management, and worker registration — on Kubernetes.

For detailed installation and configuration guidance, see the [Boundary Helm chart documentation](https://developer.hashicorp.com/boundary/docs/deploy/helm-chart).

## What The Chart Deploys

A default install creates:

- A Deployment with two controller replicas
- Three Services: API (port 9200, LoadBalancer), Cluster (port 9201, ClusterIP), and Ops (port 9203, ClusterIP); service types are configurable
- A ConfigMap holding the rendered controller configuration
- A PodDisruptionBudget to maintain availability during voluntary disruptions
- Helm hook Jobs:
  - **Database init** — runs on install when `database.init.enabled=true`
  - **Database migrate** — runs on upgrade when `database.migrate.enabled=true`
  - **Database repair** — runs on upgrade when `database.repair.version` is set
  - **Bootstrap admin** — runs on install when `bootstrapAdmin.enabled=true` (and optionally on upgrade when `bootstrapAdmin.runOnUpgrade=true`)

## Prerequisites

### Version Requirements

| Component | Version |
| --- | --- |
| Kubernetes | 1.34 and above |
| Helm | v3 and above |
| PostgreSQL | 15 and above |

### Required Before Installing

Have these ready before running `helm install`:

- **PostgreSQL database** — an existing instance with a Boundary database provisioned
- **KMS configuration** — [KMS](https://developer.hashicorp.com/boundary/docs/configuration/kms) stanzas in `controller.config`
- **Boundary license** — required for enterprise builds
- **TLS certificate** — required for the API listener
- **Bootstrap admin credentials** — required when `bootstrapAdmin.enabled=true`

## Step 1 — Provision Secrets

The chart reads sensitive values from a Kubernetes Secret referenced by `secretRefs.secretName` (default: `boundary-controller-secrets`). The Secret can be created with [kubectl](https://kubernetes.io/docs/concepts/configuration/secret/), [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso), or the [External Secrets Operator](https://external-secrets.io/latest/).

The Secret must contain the following keys (key names are configurable via `secretRefs.keys.*`):

| Key | Description | Required |
| --- | --- | --- |
| `database-url` | PostgreSQL connection URL for the controller (`env://BOUNDARY_PG_URL`) | Always |
| `migration-url` | PostgreSQL connection URL for migrations (`env://BOUNDARY_PG_MIGRATION_URL`) | When referenced in `controller.config` |
| `license` | Boundary Enterprise license string | Always |
| `admin-username` | Bootstrap admin username | When `bootstrapAdmin.enabled=true` |
| `admin-password` | Bootstrap admin password | When `bootstrapAdmin.enabled=true` |

> **Note:** When `secretRefs.secretName` is set, `controller.config` must reference secret-backed fields using these exact `env://` names — or declare them in `extraEnv`:
> - `env://BOUNDARY_PG_URL` → `database { url }`
> - `env://BOUNDARY_PG_MIGRATION_URL` → `database { migration_url }`
> - `env://BOUNDARY_LICENSE` → `controller { license }`
>
> Any mismatch fails at render time with a clear error.

A Kubernetes [TLS Secret](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets) containing `tls.crt` and `tls.key` is required when either `tls.api.disabled` or `tls.ops.disabled` is `false` (both default to `false`). Set `tls.secretName` to match the Secret name.

## Step 2 — Install the Chart

Add the HashiCorp Helm repository (one-time setup):

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Install the chart with your values file. At minimum, `controller.config` must include a database URL and KMS stanzas. See [values.yaml](values.yaml) for all available options.

```bash
helm install boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --create-namespace \
  --values my-values.yaml \
  --wait
```

> **Note:** Set `public_cluster_addr` in `controller.config` to an address reachable by all workers, especially those outside the cluster network.

## Upgrading

For a standard upgrade with no schema changes:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --rollback-on-failure \
  --wait
```

## Upgrading with Database Migration

Database migration is required when upgrading to a new Boundary version that includes schema changes. Follow all four steps in order.

**Step 1 — Scale controllers to zero** so the migration can acquire the PostgreSQL advisory lock:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --rollback-on-failure \
  --wait
```

**Step 2 — Back up the database** before making any schema changes. Migrations are not reversed by a Helm rollback — if something goes wrong, you will need to restore from this backup.

**Step 3 — Run the migration job.** Pass `--set database.migrate.enabled=true` as a one-time flag — do not add it to your values file.

Without repair:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --set database.migrate.enabled=true \
  --rollback-on-failure \
  --wait
```

With repair (use only when directed by Boundary migration failure output):

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --set database.migrate.enabled=true \
  --set database.repair.version=<version_id> \
  --rollback-on-failure \
  --wait
```

> **`--rollback-on-failure`** rolls back the Helm release state only. Database schema changes applied by a partially completed migration are **not** reversed.

**Step 4 — Restore controllers** and clear the one-time migration flags.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  --values my-values.yaml \
  --set database.migrate.enabled=false \
  --set database.repair.version="" \
  --rollback-on-failure \
  --wait
```

`--reset-values --values my-values.yaml` can also be used to wipe out all custom values, `--set` flags, and files used in your previous deployments.

## Uninstall

```bash
helm uninstall boundary-controller -n boundary
```

Removes all chart-managed resources. Hook Jobs expire after 10 minutes regardless of install or uninstall. The PostgreSQL database is not affected.

----

**Please note**: We take Boundary's security and our users' trust very
seriously. If you believe you have found a security issue in Boundary,
_please responsibly disclose_ by contacting us at
[security@hashicorp.com](mailto:security@hashicorp.com).

----


## Contributing

When submitting changes, include:

- A clear description of the behavior or documentation change
- Validation notes with the commands you ran
- Any chart value changes that affect install or upgrade workflows
