# Boundary Controller Helm Chart

Production-oriented Helm chart for HashiCorp Boundary controllers on Kubernetes. Boundary controllers are the control-plane component of Boundary — they manage authentication, authorization, sessions, and worker registration. Because controller state lives in PostgreSQL, the controller Deployment is stateless and can run multiple replicas behind a load balancer.

This chart packages the Kubernetes resources required to run one or more Boundary controller replicas backed by a PostgreSQL database. It is intended for operator-managed Boundary deployments where you control the control plane infrastructure.

The chart scope focuses on:

- Multi-replica controller Deployment with rolling update support
- Kubernetes-native resource model using Deployment, Services, ConfigMap, ServiceAccount, and PodDisruptionBudget
- Customer-supplied Boundary controller configuration file
- Helm hook jobs for database initialization, database migration, and admin bootstrapping
- Existing Kubernetes Secret model for sensitive values — no secret generation

The chart does not manage worker resources, Boundary scopes, HCP Boundary connectivity, DNS, ingress controllers, or TLS certificate issuance and renewal. You must supply a pre-existing Kubernetes TLS Secret containing a valid certificate and private key.

## Contents

- [What The Chart Deploys](#what-the-chart-deploys)
- [Prerequisites](#prerequisites)
  - [Version Requirements](#version-requirements)
  - [Required Resources](#required-resources)
- [Security Model](#security-model)
- [Installation](#installation)
- [Configuration Model](#configuration-model)
- [Required Controller Configuration](#required-controller-configuration)
- [TLS](#tls)
- [Common Deployment Patterns](#common-deployment-patterns)
- [Configuration Reference](#configuration-reference)
- [Operations](#operations)
  - [Upgrading](#upgrading)
  - [Rollback](#rollback)
  - [Uninstall](#uninstall)
- [Monitoring](#monitoring)
- [Known Limitations](#known-limitations)
- [Contributing](#contributing)

## What The Chart Deploys

By default, a release renders the following resources:

- One Deployment with two controller replicas and a RollingUpdate strategy
- Three Services for controller traffic:
  - **API Service** (`boundary-controller`): LoadBalancer on port 9200 for client API traffic
  - **Cluster Service** (`boundary-controller-cluster`): ClusterIP on port 9201 for worker registration
  - **Ops Service** (`boundary-controller-ops`): ClusterIP on port 9203 for health checks and metrics
- One ConfigMap containing the rendered Boundary controller configuration file
- One PodDisruptionBudget ensuring at least one replica stays available during voluntary disruptions
- Helm hook Jobs for database initialization (`pre-install`), optional database migration (`pre-upgrade`), optional database repair (`pre-upgrade`), and optional admin bootstrap (`post-install`)

The chart uses an existing ServiceAccount and does not create ServiceAccount resources.

## Prerequisites

### Version Requirements

| Component | Version | 
| ----- | ----- | 
| Kubernetes | 1.34 and above |
| Helm | v3 and above |
| PostgreSQL | 15 and above |

### Required Resources

Ensure the following exist before installing:

 - **Kubernetes Secret** in the same namespace the chart resources are rendered into (the release namespace by default, unless overridden with `.Values.namespace`) containing the database URL credentials and Boundary Enterprise license (add admin credentials when `bootstrapAdmin.enabled=true`). Create it manually or sync it using the [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) or the [External Secrets Operator](https://external-secrets.io).
- **PostgreSQL database** reachable from the cluster, with a user that has permission to create tables.
- **KMS provider** — choose one: Vault Transit (`transit` stanza, requires Vault 1.11+), AWS KMS (`awskms`), GCP Cloud KMS (`gcpckms`), or Azure Key Vault (`azurekeyvault`). Cloud KMS providers require IAM/RBAC permissions granting the controller access to the key.
- **Kubernetes TLS Secret** containing `tls.crt` and `tls.key` when `tls.disabled=false`.

For multi-replica deployments, `public_cluster_addr` must be set in `controller.config` so workers can reach each replica.

> Always test upgrades in a non-production environment before applying to production.

## Security Model

The chart runs controller containers with restricted Kubernetes security settings:

- Runs as non-root (`runAsUser: 100`, `runAsGroup: 1000`)
- Drops all Linux capabilities
- Disables privilege escalation
- Sets `SKIP_SETCAP=1` to avoid capability modification at startup
- Enforces `RuntimeDefault` seccomp profile
- Sets `fsGroup: 1000` so mounted volumes are accessible by the container user

Operational implications:

- `disable_mlock = true` should remain set in the controller configuration when using this deployment model.
- Sensitive values are not stored in the ConfigMap. They are sourced from an existing Kubernetes Secret via `valueFrom.secretKeyRef` in all containers. That Secret can be populated manually or synced from Vault using the Vault Secrets Operator or External Secrets Operator.
- The ops Service defaults to `ClusterIP` and is not exposed externally.
- The cluster Service defaults to `LoadBalancer`; set `controller.service.cluster.type=ClusterIP` for internal-only worker registration.
- Secret validation at render time (`secretRefs.validateExisting=true`) catches missing credentials before any resources are created.

## Installation

Use this flow when you want to deploy a Boundary controller with this chart.

### 1. Create the Kubernetes Secret

Create the Secret that the chart reads sensitive values from. At minimum it must contain the database credentials, migration database credentials (if using `env://BOUNDARY_PG_MIGRATION_URL` in `controller.config`), and enterprise license. Add admin credentials when `bootstrapAdmin.enabled=true` (the default).

```bash
kubectl create secret generic boundary-controller-secrets \
  --namespace boundary \
  --from-literal=database-url="postgres://boundary:password@postgres:5432/boundary?sslmode=require" \
  --from-literal=migration-url="postgres://boundary-migrator:password@postgres:5432/boundary?sslmode=require" \
  --from-literal=license="<boundary-enterprise-license>" \
  --from-literal=admin-username="admin" \
  --from-literal=admin-password="<secure-password>"
```

### 2. Create the TLS Secret

Create this Secret only if you plan to enable TLS (`tls.disabled=false`). Supply a TLS certificate and key:

```bash
kubectl create secret tls boundary-controller-tls \
  --namespace boundary \
  --cert=tls.crt \
  --key=tls.key
```

### 3. Add the controller configuration to your values file

Set `controller.config` in your values file with your Boundary HCL. The embedded default uses `awskms` — you must update KMS key IDs, region, and `public_cluster_addr` before installing. See [Required Controller Configuration](#required-controller-configuration) for the minimum structure, required fields, and a complete example.

### 4. Review chart values

Check `values.yaml` before installing, especially:

- `image.repository`, `image.tag`, and `image.pullPolicy`
- `secretRefs.secretName`
- `database.init.enabled`, `database.migrate.enabled`, and `database.repair.version`
- `bootstrapAdmin.enabled`
- `tls.secretName` and `tls.mountPath`
- `controller.service.api`, `controller.service.cluster`, and `controller.service.ops`
- `serviceAccount.name`
- `controller.resources`

For all available values see the [Configuration Reference](#configuration-reference). For cloud-specific examples (AWS, GCP, Azure) see [Common Deployment Patterns](#common-deployment-patterns).

### 5. Create the namespace

```bash
kubectl create namespace boundary
```

### 6. Install the chart

Add the HashiCorp Helm repository (one-time):

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Install using the default values:

```bash
helm install boundary-controller hashicorp/boundary-controller . \
  --namespace boundary
```

Install with an additional values file:

```bash
helm install boundary-controller hashicorp/boundary-controller . \
  --namespace boundary \
  -f my-values.yaml
```

### 7. Verify the deployment

```bash
kubectl get pods -n boundary
kubectl get svc -n boundary
kubectl get jobs -n boundary
kubectl logs deployment/boundary-controller -n boundary
```

Confirm that:

- The database initialization Job completes successfully when database.init.enabled=true
- The bootstrap admin Job completes successfully (if enabled)
- The controller pods become ready
- The API Service has an external address

### 8. If using a LoadBalancer, retrieve the external address

```bash
kubectl get svc boundary-controller-api -n boundary
```

Use the external address to access the Boundary UI at `https://<EXTERNAL_IP>:9200`.

## Configuration Model

The chart splits configuration into two distinct layers.

### 1. Boundary runtime configuration

The actual controller behavior is defined by `controller.config`, which is supplied as raw HCL content. The chart stores it in a ConfigMap and mounts it into all controller containers and hook job containers.

Important characteristics:

- The chart renders `controller.config` through Helm's `tpl` function, so Helm template expressions inside the HCL are evaluated.
- The chart validates that `tls_cert_file` and `tls_key_file` paths are aligned with `tls.mountPath` when `tls.disabled=false`.
- The chart validates that AEAD `env://` key indirection is not used inside `kms` blocks (Boundary does not support this).
- The operator is responsible for keeping listener ports, KMS stanzas, and cluster addresses aligned with the Kubernetes resources.

### 2. Kubernetes infrastructure configuration

Kubernetes-specific settings live under chart values such as:

- `image.*`
- `controller.service.*`
- `controller.resources.*`
- `tls.*`
- `podSecurityContext`
- `containerSecurityContext`
- `serviceAccount.*`
- `podDisruptionBudget.*`
- `nodeSelector`
- `tolerations`
- `affinity`

These values control how the controller runs in Kubernetes but do not replace or generate the Boundary runtime configuration.

## Required Controller Configuration

This chart ships with an embedded default `controller.config` that uses `awskms` for KMS. You must update the KMS key IDs and region before the chart is usable in your environment.

At minimum, a usable controller config must include:

- Listener blocks for `api`, `cluster`, and `ops` traffic
- A `controller` block with `name`, `license`, and `database.url`
- `public_cluster_addr` so workers can reach the cluster listener
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

kms "awskms" {
  purpose    = "root"
  region     = "us-east-1"
  kms_key_id = "alias/boundary-root"
}

kms "awskms" {
  purpose    = "recovery"
  region     = "us-east-1"
  kms_key_id = "alias/boundary-recovery"
}

kms "awskms" {
  purpose    = "worker-auth"
  region     = "us-east-1"
  kms_key_id = "alias/boundary-worker-auth"
}
```

Because the chart evaluates `controller.config` with Helm `tpl`, Helm template expressions inside the HCL are supported. For example, `{{ include "boundary.controller.clusterServiceName" . }}` resolves to the cluster Service name at render time.

### Vault Transit KMS

If Vault is part of your infrastructure, you can use the Vault Transit engine instead of a cloud KMS. Replace the `awskms` stanzas with `transit` stanzas.

```hcl
kms "transit" {
  purpose            = "root"
  address            = "https://vault.example.com"
  token              = "env://VAULT_TOKEN"
  mount_path         = "transit/"
  key_name           = "boundary-root"
  disable_renewal    = false
}

kms "transit" {
  purpose            = "recovery"
  address            = "https://vault.example.com"
  token              = "env://VAULT_TOKEN"
  mount_path         = "transit/"
  key_name           = "boundary-recovery"
}

kms "transit" {
  purpose            = "worker-auth"
  address            = "https://vault.example.com"
  token              = "env://VAULT_TOKEN"
  mount_path         = "transit/"
  key_name           = "boundary-worker-auth"
}
```

The Vault token or other credentials required by the Transit engine must be supplied to the controller pod. One approach is to inject them via the [Vault Agent Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector) as environment variables or files, alongside the Boundary container. See the Boundary KMS documentation for all supported Transit configuration fields.

## TLS

TLS is disabled by default (`tls.disabled=true`). When enabled, the chart expects a Kubernetes TLS Secret named by `tls.secretName` containing `tls.crt` and `tls.key`. That Secret is mounted at `tls.mountPath` in all controller and job containers.

The chart validates that `controller.config` references `tls.mountPath` for both `tls_cert_file` and `tls_key_file`. If the paths do not match, rendering fails with an actionable error.

To enable TLS:

1. Set `tls.disabled=false`
2. Configure `controller.config` listeners with `tls_disable = false` and cert/key file paths under `tls.mountPath`
3. Update liveness and readiness probe schemes to `HTTPS`:

```yaml
tls:
  disabled: false

controller:
  livenessProbe:
    scheme: HTTPS
  readinessProbe:
    scheme: HTTPS
```

## Common Deployment Patterns

### AWS with IRSA and NLB

Use [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) to grant the controller pod access to [AWS KMS](https://docs.aws.amazon.com/kms/latest/developerguide/overview.html) without long-lived credentials. Expose the API listener through an [AWS Network Load Balancer](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html).

**Resources:**
- [Boundary AWS KMS Configuration](https://developer.hashicorp.com/boundary/docs/configuration/kms/awskms)
- [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [AWS KMS IAM Permissions](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)
- [AWS Network Load Balancer on EKS](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)

### GCP with Workload Identity and Cloud KMS

Use [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) to grant the controller pod access to GCP Cloud KMS. Expose the API through a GCP Load Balancer.

**Resources:**
- [Boundary GCP KMS Configuration](https://developer.hashicorp.com/boundary/docs/configuration/kms/gcpckms)
- [GKE Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Cloud KMS IAM Permissions](https://cloud.google.com/iam/docs/roles-permissions/cloudkms)
- [GKE LoadBalancer Services](https://cloud.google.com/kubernetes-engine/docs/concepts/service-load-balancer)

### Azure with Managed Identity and Key Vault

Use [Azure Managed Identity](https://learn.microsoft.com/azure/aks/workload-identity-overview) to grant the controller pod access to [Azure Key Vault](https://learn.microsoft.com/azure/key-vault/general/overview). Expose the API through an Azure Load Balancer.

**Resources:**
- [Boundary Azure Key Vault Configuration](https://developer.hashicorp.com/boundary/docs/configuration/kms/azurekeyvault)
- [Azure Workload Identity](https://learn.microsoft.com/azure/aks/workload-identity-overview)
- [Azure Key Vault RBAC and Access Policies](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
- [Azure Load Balancer in AKS](https://learn.microsoft.com/azure/aks/load-balancer-standard)

### Database Ops Flags

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

### Vault-managed secrets

If Vault is your source of truth for secrets, use the [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) or the [External Secrets Operator](https://external-secrets.io) with a Vault backend to sync the required values into a Kubernetes Secret before install. Once the Secret exists in the release namespace with the correct key names, the chart reads it the same way as a manually created Secret. Set `secretRefs.secretName` to match the name the operator creates. Cloud-native alternatives such as AWS Secrets Manager (via the AWS Secrets and Configuration Provider) or GCP Secret Manager can also be used to populate the Secret in the same way.

### Offline rendering without cluster access

Secret validation requires a live cluster connection. Disable it for `helm template` runs:

```yaml
secretRefs:
  validateExisting: false
```

## Configuration Reference

The table below documents all chart values shipped in `values.yaml`.

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `hashicorp/boundary-enterprise` | Boundary controller container image repository. |
| `image.tag` | `0.21-ent` | Image tag used by the controller container and hook jobs. Defaults to `appVersion` in Chart.yaml when empty. |
| `image.pullPolicy` | `IfNotPresent` | Kubernetes image pull policy. |
| `imagePullSecrets` | `[]` | Optional registry credentials for private image pulls. |
| `nameOverride` | `""` | Override the chart name used in resource naming. |
| `namespace` | `""` | Namespace applied to all namespaced chart resources. Leave empty to use the Helm release namespace. |
| `tls.disabled` | `true` | Disable TLS cert mounts and related validation when set to `true`. |
| `tls.secretName` | `boundary-controller-tls` | Name of the Kubernetes TLS Secret containing `tls.crt` and `tls.key`. |
| `tls.mountPath` | `/etc/boundary/tls` | Mount path for TLS certs inside containers. Must match paths in `controller.config`. |
| `controller.replicas` | `2` | Number of controller replicas. |
| `controller.rollingUpdate.maxUnavailable` | `1` | Maximum unavailable pods during a rolling update. |
| `controller.rollingUpdate.maxSurge` | `1` | Maximum surge pods during a rolling update. |
| `controller.config` | Embedded HCL | Raw HCL controller configuration stored in a ConfigMap and mounted into all containers. Rendered with `tpl`. |
| `secretRefs.secretName` | `boundary-controller-secrets` | Name of the Kubernetes Secret containing sensitive values. Must exist before install. |
| `secretRefs.validateExisting` | `false` | When true, Helm validates that the Secret exists and contains all required keys at render time. Set to `false` for offline `helm template` runs. |
| `secretRefs.keys.databaseUrl` | `database-url` | Key in the Secret for the PostgreSQL connection string. |
| `secretRefs.keys.migrationUrl` | `migration-url` | Key in the Secret for the migration PostgreSQL connection string, used when `controller.config` sets `database.migration_url = "env://BOUNDARY_PG_MIGRATION_URL"`. |
| `secretRefs.keys.license` | `license` | Key in the Secret for the Boundary Enterprise license. |
| `secretRefs.keys.adminUsername` | `admin-username` | Key in the Secret for the bootstrap admin login name. Required when `bootstrapAdmin.enabled=true`. |
| `secretRefs.keys.adminPassword` | `admin-password` | Key in the Secret for the bootstrap admin password. Required when `bootstrapAdmin.enabled=true`. |
| `secretRefs.keys.kmsRoot` | `kms-root` | Key in the Secret for the AEAD root KMS key. Required only when using AEAD `env://` key mode. |
| `secretRefs.keys.kmsWorkerAuth` | `kms-worker-auth` | Key in the Secret for the AEAD worker-auth KMS key. Required only when using AEAD `env://` key mode. |
| `secretRefs.keys.kmsRecovery` | `kms-recovery` | Key in the Secret for the AEAD recovery KMS key. Required only when using AEAD `env://` key mode. |
| `database.init.enabled` | `true` | Run `boundary database init` as a `pre-install` hook job. Set to `false` when database lifecycle is managed outside this chart. |
| `database.migrate.enabled` | `false` | Run `boundary database migrate` as a `pre-upgrade` hook job. Pass via `--set` on the upgrade command rather than setting in your values file. |
| `database.repair.version` | `""` | Migration version id passed to `-repair`. When non-empty and `database.migrate.enabled=true`, a repair job runs first, then migrate. |
| `bootstrapAdmin.enabled` | `true` | Run the post-install bootstrap admin hook job. |
| `bootstrapAdmin.runOnUpgrade` | `false` | Also run the bootstrap admin job as a post-upgrade hook. |
| `bootstrapAdmin.waitTimeoutSeconds` | `120` | Seconds the bootstrap job waits for the controller API to become available. |
| `bootstrapAdmin.authMethodName` | `bootstrap-password` | Display name for the password auth method created by the bootstrap job. |
| `bootstrapAdmin.userResourceName` | `bootstrap-admin` | Display name for the Boundary user resource created by the bootstrap job. |
| `bootstrapAdmin.accountResourceName` | `bootstrap-admin` | Display name for the Boundary account resource created by the bootstrap job. |
| `bootstrapAdmin.roleName` | `bootstrap-global-admin` | Display name for the global admin role created by the bootstrap job. |
| `controller.livenessProbe.scheme` | `HTTP` | HTTP scheme for liveness probe requests to the ops listener. |
| `controller.livenessProbe.initialDelaySeconds` | `60` | Seconds before the first liveness probe. |
| `controller.livenessProbe.periodSeconds` | `10` | Liveness probe interval in seconds. |
| `controller.livenessProbe.failureThreshold` | `3` | Consecutive failures before the pod is restarted. |
| `controller.livenessProbe.timeoutSeconds` | `5` | Timeout in seconds for each liveness probe. |
| `controller.readinessProbe.scheme` | `HTTP` | HTTP scheme for readiness probe requests to the ops listener. |
| `controller.readinessProbe.initialDelaySeconds` | `15` | Seconds before the first readiness probe. |
| `controller.readinessProbe.periodSeconds` | `10` | Readiness probe interval in seconds. |
| `controller.readinessProbe.failureThreshold` | `3` | Consecutive failures before the pod is removed from Service endpoints. |
| `controller.readinessProbe.timeoutSeconds` | `5` | Timeout in seconds for each readiness probe. |
| `controller.resources.requests.cpu` | `250m` | CPU request for the controller container. |
| `controller.resources.requests.memory` | `512Mi` | Memory request for the controller container. |
| `controller.resources.limits.cpu` | `500m` | CPU limit for the controller container. |
| `controller.resources.limits.memory` | `1Gi` | Memory limit for the controller container. |
| `controller.service.api.type` | `LoadBalancer` | Service type for the API listener. |
| `controller.service.api.port` | `9200` | Service port for the API listener. |
| `controller.service.api.targetPort` | `9200` | Container port targeted by the API Service. |
| `controller.service.api.annotations` | `{}` | Annotations applied to the API Service. Use for cloud load balancer configuration. |
| `controller.service.cluster.type` | `LoadBalancer` | Service type for the cluster listener. |
| `controller.service.cluster.port` | `9201` | Service port for the cluster listener. |
| `controller.service.cluster.targetPort` | `9201` | Container port targeted by the cluster Service. |
| `controller.service.cluster.annotations` | `{}` | Annotations applied to the cluster Service (9201), typically used for NLB internal or external mode. |
| `controller.service.ops.type` | `ClusterIP` | Service type for the ops listener. |
| `controller.service.ops.port` | `9203` | Service port for the ops listener. |
| `controller.service.ops.targetPort` | `9203` | Container port targeted by the ops Service. |
| `controller.service.ops.annotations` | `{}` | Annotations applied to the ops Service. |
| `podSecurityContext` | secure non-root defaults | Pod-level security context applied to controller pods and hook job pods. |
| `containerSecurityContext` | secure non-root defaults | Container-level security context with dropped Linux capabilities. |
| `podAnnotations` | `{}` | Extra annotations added to controller pods. |
| `nodeSelector` | `{}` | Node selector constraints for the controller Deployment. |
| `tolerations` | `[]` | Tolerations for controller pod scheduling. |
| `affinity` | `{}` | Affinity rules for controller pod scheduling. |
| `serviceAccount.name` | `default` | Name of an existing ServiceAccount used by controller and hook jobs. |
| `serviceAccount.automountServiceAccountToken` | `false` | Control whether pods using this ServiceAccount receive an API token. |
| `podDisruptionBudget.enabled` | `true` | Create a PodDisruptionBudget for the controller Deployment. |
| `podDisruptionBudget.minAvailable` | `1` | Minimum number of controller pods that must remain available during voluntary disruptions. |
| `terminationGracePeriodSeconds` | `15` | Seconds Kubernetes waits before sending SIGKILL after SIGTERM. Should exceed `graceful_shutdown_wait_duration` in the controller config. |

## Operations

### Check release resources

```bash
kubectl get deployment,pods,svc,pdb -n boundary
```

### Inspect controller logs

```bash
kubectl logs -n boundary deployment/boundary-controller
```

### Check hook job status

```bash
kubectl get jobs -n boundary
kubectl logs -n boundary job/boundary-controller-init-db
kubectl logs -n boundary job/boundary-controller-bootstrap-admin
```

### Upgrading

#### Pre-Upgrade Checklist

Before upgrading the chart or Boundary version:

1. **Backup the database**: Create a PostgreSQL backup before any upgrade
2. **Review release notes**: Check Boundary release notes for breaking changes
3. **Test in non-production**: Always test upgrades in a staging environment first
4. **Check compatibility**: Verify chart and Boundary version compatibility
5. **Review configuration changes**: Check if new chart version requires config updates
6. **Verify KMS access**: Ensure KMS keys are accessible and permissions are current
7. **Check resource capacity**: Ensure cluster has capacity for rolling update surge


#### Upgrade with a new values file

```bash
# Perform the upgrade
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml
```

#### Upgrade with database migration

`boundary database migrate` uses PostgreSQL advisory locks to get exclusive access during schema changes. It cannot acquire that lock while active controllers are still connected to the database and heartbeating. Scale the Deployment to zero replicas first, then run the migration upgrade.

> **Back up the database before running a migration.** Migrations are not automatically reversed on Helm rollback. If a migration fails or produces unexpected results, restoring from backup is the recovery path.

**Step 1 — scale controllers to zero:**

```bash
helm upgrade boundary-controller hashicorp/boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.replicas=0
```

**Step 2 — run the migration and bring controllers back up:**

Pass `--set database.migrate.enabled=true` on the upgrade command. Do not set this in your values file — it is a one-time flag. Helm runs the `pre-upgrade` migration job first, then rolls out the Deployment using the replica count from your values file, bringing the controllers back up automatically.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set database.migrate.enabled=true
```

If the migration user differs from the runtime database user, set `migration_url` in `controller.config` under the `database` block. The chart does not pass `-migration-url`; Boundary will use the configured value automatically.

```bash
controller {
  database {
    url           = "env://BOUNDARY_PG_URL"
    migration_url = "env://BOUNDARY_PG_MIGRATION_URL"
  }
}
```

When using `env://BOUNDARY_PG_MIGRATION_URL`, ensure the Secret contains the key configured by `secretRefs.keys.migrationUrl` (default `migration-url`).

#### Upgrade with migration repair

Use repair only after reviewing Boundary migration failure output and identifying the failed version id. This chart runs repair as a separate `pre-upgrade` hook job.

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml \
  --set database.migrate.enabled=true \
  --set database.repair.version=<version_id>
```

**Notes:**

- Repair runs only when both conditions are true: `database.migrate.enabled=true` and `database.repair.version` is non-empty.
- If `database.repair.version` is set but `database.migrate.enabled=false`, no repair job runs.
- Keep `database.repair.version` as a one-time value, similar to migrate flags.
- When both run, Helm runs repair first (hook weight `-10`) and migrate second (hook weight `-5`).

#### Post-Upgrade Verification

After upgrading:

```bash
# Check pod status
kubectl get pods -n boundary

# Verify all replicas are ready
kubectl rollout status deployment/boundary-controller -n boundary

# Check controller logs for errors
kubectl logs -n boundary deployment/boundary-controller --tail=100

# Check hook job completion
kubectl get jobs -n boundary
```

### Rollback

If an upgrade fails or causes issues:

```bash
# View release history
helm history boundary-controller -n boundary

# Rollback to previous revision
helm rollback boundary-controller -n boundary

# Rollback to specific revision
helm rollback boundary-controller <revision> -n boundary
```

**Database Rollback Considerations:**
- Database migrations are **not automatically reversed** on Helm rollback
- If a migration was applied, you may need to restore from backup
- Test rollback procedures in non-production environments

### Uninstall

```bash
helm uninstall boundary-controller -n boundary
```

Hook jobs have `ttlSecondsAfterFinished: 3600` set, so Kubernetes will automatically delete them 1 hour after they complete.

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
    format      = "cloudevents-json"
  }

  sink "file" {
    name        = "audit-sink"
    description = "Audit events to file"
    event_types = ["audit"]
    format      = "cloudevents-json"
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
- Secret generation, Vault Agent Injector integration, or external secret operator wiring (Vault Secrets Operator, External Secrets Operator) — the chart expects the Kubernetes Secret to already exist; how it gets there is outside the chart's scope
- Multi-cluster or multi-region controller topologies

## Contributing

When submitting changes, include:

- A clear description of the behavior or documentation change
- Validation notes with the commands you ran
- Any chart value changes that affect install or upgrade workflows