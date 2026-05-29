# Boundary Controller Helm Chart

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

Install with custom values:

```bash
helm install boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml
```

## Helm Upgrade Commands

Standard upgrade:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml
```

## Helm Upgrade with Database Migration

Step 1: scale controllers to zero.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.replicas=0
```

Step 2: take a manual PostgreSQL DB backup.

Step 3: run migration and bring controllers back.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml \
  --set database.migrate.enabled=true
```

Optional: run migration with repair version.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml \
  --set database.migrate.enabled=true \
  --set database.repair.version=<version_id>
```