# Boundary Controller Helm Chart

Boundary controllers are the control-plane component of Boundary — they manage authentication, authorization, sessions, and worker registration. Because controller state lives in PostgreSQL, the controller Deployment is stateless and can run multiple replicas behind a load balancer.

This chart packages the Kubernetes resources required to run one or more Boundary controller replicas backed by a PostgreSQL database. It is intended for operator-managed Boundary deployments where you control the control plane infrastructure.

## What The Chart Deploys

By default, this chart deploys:

- One Deployment with two Boundary controller replicas
- Three Services:
  - API Service (`boundary-controller-api`) on port 9200
  - Cluster Service (`boundary-controller-cluster`) on port 9201
  - Ops Service (`boundary-controller-ops`) on port 9203
- One ConfigMap for `controller.config` and embedded scripts
- One PodDisruptionBudget

## Prerequisites

### Version Requirements

| Component | Version | 
| --- | --- | 
| Kubernetes | 1.34 and above |
| Helm | v3 and above |
| PostgreSQL | 15 and above |

### Required Resources

- Existing Kubernetes Secret with DB URL, Boundary license, and bootstrap admin keys (when `bootstrapAdmin.enabled=true`)
- Reachable PostgreSQL database
- KMS configuration in `controller.config`
- TLS secret (`tls.crt` / `tls.key`) when `tls.disabled=false`

## Helm Install Commands

Add the HashiCorp Helm repository (one-time):

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Please see the many options supported in the values.yaml file. These are also fully documented directly on the [boundary website](https://developer.hashicorp.com/boundary/docs) along with more detailed installation instructions.

For operational guidance such as upgrades, backups, and uninstall procedures, see [docs/OPERATIONS.md](docs/OPERATIONS.md).

Install with custom values:

```bash
helm install boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
  --namespace boundary \
  --values my-values.yaml \
  --wait
```

## Helm Upgrade Commands

Standard upgrade:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
  --namespace boundary \
  --values my-values.yaml \
  --rollback-on-failure \
  --wait  
```

## Helm Upgrade with Database Migration

Step 1: scale controllers to zero.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
  --namespace boundary \
  --values my-values.yaml \
  --set controller.replicas=0 \
  --rollback-on-failure \
  --wait  
```

Step 2: take a manual PostgreSQL DB backup.

Step 3: run migration job.

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

Optional: run migration with repair version.

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

Step 4: reset one-time CLI overrides (replica & migrate flag) back to the values file defaults.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --version 0.1.0 \
  --namespace boundary \
  --values my-values.yaml \
  --set database.migrate.enabled=false \
  --set-string database.repair.version="" \
  --rollback-on-failure \
  --wait
```

----

**Please note**: We take Boundary's security and our users' trust very
seriously. If you believe you have found a security issue in Boundary,
_please responsibly disclose_ by contacting us at
[security@hashicorp.com](mailto:security@hashicorp.com).

----