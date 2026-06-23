# Boundary Controller Helm Chart

This chart deploys HashiCorp Boundary's controller — the control-plane component responsible for authentication, authorization, session management, and worker registration — on Kubernetes.

Boundary controller state lives in PostgreSQL, so the deployment is stateless and horizontally scalable.

## What The Chart Deploys

A default install creates:

- A Deployment with two controller replicas
- Three Services: API (port 9200), Cluster (port 9201), and Ops (port 9203)
- A ConfigMap holding the rendered controller configuration
- A PodDisruptionBudget to maintain availability during voluntary disruptions
- Helm hook Jobs:
  - **Database init** — runs on fresh install (`database.init.enabled=true`)
  - **Database migrate** — runs on upgrade when `database.migrate.enabled=true`
  - **Database repair** — runs on upgrade when `database.repair.version` is set
  - **Bootstrap admin** — runs on install (and optionally on upgrade)

## Prerequisites

### Version Requirements

| Component | Minimum Version |
| --- | --- |
| Kubernetes | 1.34.0 |
| Helm | 3.0.0 |
| PostgreSQL | 15.0.0 |

### Required Before Installing

Have these ready before running `helm install`:

- **PostgreSQL database** — an existing instance with a Boundary database provisioned
- **KMS configuration** — [KMS](https://developer.hashicorp.com/boundary/docs/configuration/kms) stanzas in `controller.config`
- **Boundary license** — required for enterprise builds
- **TLS certificate** — required for the API listener on port 9200
- **Bootstrap admin credentials** — required when `bootstrapAdminAuthMethod.enabled=true`

## Step 1 — Create Kubernetes Secrets

The chart reads sensitive values from a Kubernetes Secret. Create it before installing:

```bash
kubectl create secret generic boundary-controller-secrets \
  --namespace boundary \
  --from-literal=database-url="postgres://boundary:password@postgres:5432/boundary?sslmode=require" \
  --from-literal=migration-url="postgres://boundary-migrator:password@postgres:5432/boundary?sslmode=require" \
  --from-literal=license="<boundary-enterprise-license>" \
  --from-literal=admin-username="admin" \
  --from-literal=admin-password="<secure-password>"
```

Create the TLS Secret (required — the API listener on port 9200 mandates TLS):

```bash
kubectl create secret tls boundary-controller-tls \
  --namespace boundary \
  --cert=tls.crt \
  --key=tls.key
```

## Step 2 — Install the Chart

Add the HashiCorp Helm repository (one-time setup):

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Install the chart with your values file. At minimum, `controller.config` must include a database URL and KMS stanzas. See [values.yaml](values.yaml) for all available options.

```bash
helm install boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
  --namespace boundary \
  --create-namespace \
  --values my-values.yaml \
  --wait
```

## Step 3 — Verify the Deployment

```bash
kubectl get pods -n boundary
kubectl get svc -n boundary
kubectl get jobs -n boundary
```

If using a LoadBalancer for the API Service, retrieve the external address:

```bash
kubectl get svc boundary-controller-api -n boundary
```

> **Note:** Workers connect to the controller using `public_cluster_addr` in `controller.config`. If your workers run outside the cluster network (e.g. on-prem, other VPCs, or remote sites), make sure this address is externally reachable from those workers. If you expose the cluster listener via a LoadBalancer, update `public_cluster_addr` to the provisioned LoadBalancer address before running `helm upgrade`.

## Upgrading

For a standard upgrade with no schema changes:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
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
  --version 0.1.0 \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --rollback-on-failure \
  --wait
```

**Step 2 — Back up the database** before making any schema changes. Migrations are not reversed by a Helm rollback — if something goes wrong, you will need to restore from this backup.

```bash
pg_dump -h <host> -U <user> -d boundary -F c -f boundary-backup-$(date +%Y%m%d%H%M%S).dump
```

**Step 3 — Run the migration job.** Pass `--set database.migrate.enabled=true` as a one-time flag — do not add it to your values file.

Without repair:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
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
  --version 0.1.0 \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --set database.migrate.enabled=true \
  --set database.repair.version=<version_id> \
  --rollback-on-failure \
  --wait
```

> **`--rollback-on-failure`** rolls back the Helm release state only. Database schema changes applied by a partially completed migration are **not** reversed.

**Step 4 — Restore controllers** and clear the one-time migration flags:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=2 \
  --set database.migrate.enabled=false \
  --set database.repair.version="" \
  --rollback-on-failure \
  --wait
```

## Uninstall

```bash
helm uninstall boundary-controller -n boundary
```

This removes all chart-managed resources (Deployment, Services, ConfigMap, PDB). Hook Jobs are not immediately deleted — they clean up automatically 10 minutes after completion. The PostgreSQL database is not affected.

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