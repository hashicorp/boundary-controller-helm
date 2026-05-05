# Boundary Controller Helm Chart

Production-oriented Helm chart for HashiCorp Boundary controllers on Kubernetes. Boundary controllers are the control-plane component of Boundary — they manage authentication, authorization, sessions, and worker registration. Because controller state lives in PostgreSQL, the controller Deployment is stateless and can run multiple replicas behind a load balancer.

This chart packages the Kubernetes resources required to run one or more Boundary controller replicas backed by a PostgreSQL database. It is intended for operator-managed Boundary deployments where you control the control plane infrastructure.

The chart is deliberately narrow in scope:

- Multi-replica controller Deployment with rolling update support
- Kubernetes-native resource model using Deployment, Services, ConfigMap, ServiceAccount, and PodDisruptionBudget
- Customer-supplied Boundary controller configuration file
- Helm hook jobs for database initialization, database migration, and admin bootstrapping
- Existing Kubernetes Secret model for sensitive values — no secret generation

The chart does not manage worker resources, Boundary scopes, HCP Boundary connectivity, DNS, ingress controllers, or TLS certificate issuance and renewal. You must supply a pre-existing Kubernetes TLS Secret containing a valid certificate and private key.

## Contents

- [What The Chart Deploys](#what-the-chart-deploys)
- [Prerequisites](#prerequisites)
- [Version Compatibility](#version-compatibility)
- [Security Model](#security-model)
- [Installation](#installation)
- [Configuration Model](#configuration-model)
- [Required Controller Configuration](#required-controller-configuration)
- [TLS](#tls)
- [Common Deployment Patterns](#common-deployment-patterns)
- [High Availability](#high-availability)
- [Configuration Reference](#configuration-reference)
- [Operations](#operations)
- [Upgrade Strategy](#upgrade-strategy)
- [Monitoring and Observability](#monitoring-and-observability)
- [Backup and Disaster Recovery](#backup-and-disaster-recovery)
- [Troubleshooting](#troubleshooting)
- [Security Model](#security-model)
- [Repository Layout](#repository-layout)
- [Known Limitations](#known-limitations)
- [Frequently Asked Questions](#frequently-asked-questions)
- [Contributing](#contributing)

## What The Chart Deploys

By default, a release renders the following resources:

- One Deployment with two controller replicas and a RollingUpdate strategy
- One API Service (`LoadBalancer`) for client traffic on port 9200
- One cluster Service (`ClusterIP`) for worker registration traffic on port 9201 and the ops listener on port 9203
- One ConfigMap containing the rendered Boundary controller configuration file
- One PodDisruptionBudget ensuring at least one replica stays available during voluntary disruptions
- Helm hook Jobs for database initialization (`pre-install`), optional database migration (`pre-upgrade`), and optional admin bootstrap (`post-install`)

An optional ServiceAccount is created when `serviceAccount.create=true`.

## Prerequisites

Before installing the chart, make sure the following are in place:

- A Kubernetes cluster running Kubernetes 1.24 or later
- Helm 3.1 or later
- A PostgreSQL database reachable from the cluster, with a database user that has permission to create tables
- A Kubernetes Secret in the release namespace containing the database URL and enterprise license (and optionally admin credentials). This Secret can be created manually, or synced from Vault using the [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) or the [External Secrets Operator](https://external-secrets.io) with a Vault backend
- A Boundary controller configuration file in HCL format
- A KMS configuration chosen in advance:
  - Vault Transit engine via the `transit` KMS provider stanza (suitable when Vault is already part of your infrastructure)
  - Cloud KMS provider stanza: `awskms` (AWS), `gcpckms` (GCP), or `azurekeyvault` (Azure)
  - AEAD keys via environment variables (dev and testing only — not supported by this chart's validation)
- A Kubernetes TLS Secret containing `tls.crt` and `tls.key` when TLS is enabled (the default)

Additional requirements for multi-replica setups:

- `public_cluster_addr` set in `controller.config` so workers can reach each controller replica

## Version Compatibility

This chart has been tested with the following versions:

| Chart Version | Boundary Version | Kubernetes Versions | Helm Version |
|---------------|------------------|---------------------|--------------|
| 1.0.x         | 0.19.x           | 1.24 - 1.31         | 3.1+         |
| 1.0.x         | 0.18.x           | 1.24 - 1.30         | 3.1+         |

**Notes:**
- Boundary Enterprise license is required for all versions
- PostgreSQL 12+ is recommended for optimal performance
- Cloud KMS providers (AWS KMS, GCP Cloud KMS, Azure Key Vault) require appropriate IAM/RBAC permissions
- Vault Transit engine requires Vault 1.11+ for optimal compatibility

Always test upgrades in a non-production environment before applying to production.

## Installation

Use this flow when you want to deploy a Boundary controller with this chart.

### 1. Create the Kubernetes Secret

Create the Secret that the chart reads sensitive values from. At minimum it must contain the database URL and enterprise license. Add admin credentials when `controller.bootstrapAdmin.enabled=true` (the default).

```bash
kubectl create secret generic boundary-controller-secrets \
  --namespace boundary \
  --from-literal=database-url="postgres://boundary:password@postgres:5432/boundary?sslmode=require" \
  --from-literal=license="<boundary-enterprise-license>" \
  --from-literal=admin-username="admin" \
  --from-literal=admin-password="<secure-password>"
```

### 2. Create the TLS Secret

The default configuration enables TLS on all listeners. Supply a TLS certificate and key:

```bash
kubectl create secret tls boundary-controller-tls \
  --namespace boundary \
  --cert=tls.crt \
  --key=tls.key
```

### 3. Add the controller configuration to your values file

Put the Boundary controller HCL directly in `controller.config` inside your values file. The embedded default uses `awskms` for KMS. Update the KMS key IDs and region to match your environment before installing.

Review at minimum:

- KMS stanza: update `region` and `kms_key_id` values for root, recovery, and worker-auth purposes
- `public_cluster_addr`: set to the DNS name or address workers will use to reach the cluster Service
- `controller.name` and `controller.description`: update to match your environment

### 4. Review chart values

Check `values.yaml` before installing, especially:

- `image.repository`, `image.tag`, and `image.pullPolicy`
- `controller.secretRefs.secretName`
- `controller.bootstrapAdmin.enabled`
- `tls.secretName` and `tls.mountPath`
- `controller.service.type` and `controller.service.annotations`
- `serviceAccount.create` and `serviceAccount.name`
- `controller.resources`

If you want overrides, create a separate values file such as `my-values.yaml`.

Example:

```yaml
controller:
  config: |
    disable_mlock = true

    listener "tcp" {
      address     = "0.0.0.0:9200"
      purpose     = "api"
      tls_disable = false
      tls_cert_file = "/etc/boundary/tls/tls.crt"
      tls_key_file  = "/etc/boundary/tls/tls.key"
    }

    listener "tcp" {
      address     = "0.0.0.0:9201"
      purpose     = "cluster"
      tls_disable = false
      tls_cert_file = "/etc/boundary/tls/tls.crt"
      tls_key_file  = "/etc/boundary/tls/tls.key"
    }

    listener "tcp" {
      address     = "0.0.0.0:9203"
      purpose     = "ops"
      tls_disable = false
      tls_cert_file = "/etc/boundary/tls/tls.crt"
      tls_key_file  = "/etc/boundary/tls/tls.key"
    }

    controller {
      name        = "boundary-controller"
      description = "Boundary Controller running in Kubernetes"
      public_cluster_addr = "boundary-cluster:9201"
      license     = "env://BOUNDARY_LICENSE"
      database {
        url = "env://BOUNDARY_PG_URL"
      }
      graceful_shutdown_wait_duration = "10s"
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

  secretRefs:
    secretName: "boundary-controller-secrets"

  service:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb-ip"
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

serviceAccount:
  create: true
  name: "boundary-controller"
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/boundary-controller-role
```

### 5. Create the namespace

```bash
kubectl create namespace boundary
```

### 6. Install the chart

Install using the default values:

```bash
helm install boundary-controller . \
  --namespace boundary \
  --create-namespace
```

Install with an additional values file:

```bash
helm install boundary-controller . \
  --namespace boundary \
  --create-namespace \
  -f my-values.yaml
```

### 7. Verify the deployment

```bash
kubectl get pods -n boundary
kubectl get svc -n boundary
kubectl get jobs -n boundary
kubectl logs -n boundary deployment/boundary
```

Confirm that:

- The database initialization Job completes successfully
- The bootstrap admin Job completes successfully (if enabled)
- The controller pods become ready
- The API Service has an external address

### 8. If using a LoadBalancer, retrieve the external address

```bash
kubectl get svc boundary -n boundary
```

Use the external address to access the Boundary UI at `https://<EXTERNAL_IP>:9200`.

## Configuration Model

The chart splits configuration into two distinct layers.

### 1. Boundary runtime configuration

The actual controller behavior is defined by `controller.config`, which is supplied as raw HCL content. The chart stores it in a ConfigMap and mounts it into all controller containers and hook job containers.

Important characteristics:

- The chart renders `controller.config` through Helm's `tpl` function, so Helm template expressions inside the HCL are evaluated.
- The chart validates that `tls_cert_file` and `tls_key_file` paths are aligned with `tls.mountPath` when `tls.enabled=true`.
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
  tls_cert_file = "/etc/boundary/tls/tls.crt"
  tls_key_file  = "/etc/boundary/tls/tls.key"
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

**Note**: The `env://VAULT_TOKEN` indirection shown below is supported for Vault Transit authentication. This is different from AEAD KMS, where `env://` key indirection is explicitly blocked by the chart's validation.

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

TLS is enabled by default. The chart expects a Kubernetes TLS Secret named by `tls.secretName` containing `tls.crt` and `tls.key`. That Secret is mounted at `tls.mountPath` in all controller and job containers.

The chart validates that `controller.config` references `tls.mountPath` for both `tls_cert_file` and `tls_key_file`. If the paths do not match, rendering fails with an actionable error.

To disable TLS:

1. Set `tls.enabled=false`
2. Update `controller.config` to set `tls_disable = true` on each listener
3. Update liveness and readiness probe schemes to `HTTP`:

```yaml
tls:
  enabled: false

controller:
  livenessProbe:
    scheme: HTTP
  readinessProbe:
    scheme: HTTP
```

## Common Deployment Patterns

### AWS with IRSA and NLB

Use IRSA to grant the controller pod access to AWS KMS without long-lived credentials. Expose the API listener through a Network Load Balancer.

```yaml
serviceAccount:
  create: true
  name: "boundary-controller"
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/boundary-controller-role

controller:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb-ip"
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  
  config: |
    # ... listeners ...
    
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

**Required IAM Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:DescribeKey"
      ],
      "Resource": [
        "arn:aws:kms:us-east-1:ACCOUNT_ID:key/*"
      ]
    }
  ]
}
```

### GCP with Workload Identity and Cloud KMS

Use Workload Identity to grant the controller pod access to GCP Cloud KMS. Expose the API through a GCP Load Balancer.

```yaml
serviceAccount:
  create: true
  name: "boundary-controller"
  annotations:
    iam.gke.io/gcp-service-account: boundary-controller@PROJECT_ID.iam.gserviceaccount.com

controller:
  service:
    type: LoadBalancer
    annotations:
      cloud.google.com/load-balancer-type: "External"
  
  config: |
    # ... listeners ...
    
    kms "gcpckms" {
      purpose     = "root"
      project     = "my-project"
      region      = "us-central1"
      key_ring    = "boundary"
      crypto_key  = "root"
    }
    
    kms "gcpckms" {
      purpose     = "recovery"
      project     = "my-project"
      region      = "us-central1"
      key_ring    = "boundary"
      crypto_key  = "recovery"
    }
    
    kms "gcpckms" {
      purpose     = "worker-auth"
      project     = "my-project"
      region      = "us-central1"
      key_ring    = "boundary"
      crypto_key  = "worker-auth"
    }
```

**Setup Steps:**
```bash
# Create GCP service account
gcloud iam service-accounts create boundary-controller \
  --project=PROJECT_ID

# Bind Kubernetes SA to GCP SA
gcloud iam service-accounts add-iam-policy-binding \
  boundary-controller@PROJECT_ID.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:PROJECT_ID.svc.id.goog[boundary/boundary-controller]"

# Grant KMS permissions
gcloud kms keys add-iam-policy-binding root \
  --keyring=boundary \
  --location=us-central1 \
  --member="serviceAccount:boundary-controller@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
```

### Azure with Managed Identity and Key Vault

Use Azure Managed Identity to grant the controller pod access to Azure Key Vault.

```yaml
serviceAccount:
  create: true
  name: "boundary-controller"
  annotations:
    azure.workload.identity/client-id: "CLIENT_ID"

podAnnotations:
  azure.workload.identity/use: "true"

controller:
  service:
    type: LoadBalancer
  
  config: |
    # ... listeners ...
    
    kms "azurekeyvault" {
      purpose      = "root"
      tenant_id    = "TENANT_ID"
      vault_name   = "boundary-kv"
      key_name     = "root"
    }
    
    kms "azurekeyvault" {
      purpose      = "recovery"
      tenant_id    = "TENANT_ID"
      vault_name   = "boundary-kv"
      key_name     = "recovery"
    }
    
    kms "azurekeyvault" {
      purpose      = "worker-auth"
      tenant_id    = "TENANT_ID"
      vault_name   = "boundary-kv"
      key_name     = "worker-auth"
    }
```

**Setup Steps:**
```bash
# Create managed identity
az identity create \
  --name boundary-controller \
  --resource-group boundary-rg

# Get identity client ID
CLIENT_ID=$(az identity show --name boundary-controller --resource-group boundary-rg --query clientId -o tsv)

# Grant Key Vault permissions
az keyvault set-policy \
  --name boundary-kv \
  --object-id $(az identity show --name boundary-controller --resource-group boundary-rg --query principalId -o tsv) \
  --key-permissions encrypt decrypt get

# Establish federated identity credential
az identity federated-credential create \
  --name boundary-controller-federated \
  --identity-name boundary-controller \
  --resource-group boundary-rg \
  --issuer "https://oidc.prod-aks.azure.com/TENANT_ID/" \
  --subject "system:serviceaccount:boundary:boundary-controller"
```

### Disable bootstrap admin

If you manage admin accounts externally, disable the bootstrap job:

```yaml
controller:
  bootstrapAdmin:
    enabled: false
```

### Vault-managed secrets

If Vault is your source of truth for secrets, use the [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) or the [External Secrets Operator](https://external-secrets.io) with a Vault backend to sync the required values into a Kubernetes Secret before install. Once the Secret exists in the release namespace with the correct key names, the chart reads it the same way as a manually created Secret. Set `controller.secretRefs.secretName` to match the name the operator creates. Cloud-native alternatives such as AWS Secrets Manager (via the AWS Secrets and Configuration Provider) or GCP Secret Manager can also be used to populate the Secret in the same way.

### Offline rendering without cluster access

Secret validation requires a live cluster connection. Disable it for `helm template` runs:

```yaml
controller:
  secretRefs:
    validateExisting: false
```

## High Availability

### Multi-Replica Architecture

Boundary controllers are stateless — all persistent state lives in PostgreSQL. This enables horizontal scaling through multiple replicas behind a load balancer. The chart defaults to 2 replicas with a `RollingUpdate` strategy.

### How HA Works

- **Session State**: All session state is stored in PostgreSQL, so any controller replica can handle any request
- **Load Distribution**: The API Service (LoadBalancer) distributes client traffic across healthy replicas
- **Worker Registration**: Workers connect to the cluster Service and maintain connections to all available controller replicas
- **Graceful Shutdown**: Controllers wait for active sessions to complete before terminating (configured via `graceful_shutdown_wait_duration`)

### Failure Scenarios

**Single Replica Failure:**
- Kubernetes automatically restarts failed pods
- Active sessions on the failed replica are terminated
- Clients reconnect to healthy replicas automatically
- Workers maintain connections to remaining replicas
- No data loss (state is in PostgreSQL)

**Multiple Replica Failures:**
- If all replicas fail simultaneously, the service becomes unavailable
- PostgreSQL must remain available for recovery
- Once replicas restart, they resume normal operation
- Historical session data remains intact in the database

**Database Failure:**
- Controllers cannot process requests without database connectivity
- Existing sessions may continue briefly but cannot be renewed
- New sessions cannot be established
- Recovery requires restoring database connectivity

### Limitations

For HA-specific limitations, see the [Known Limitations](#known-limitations) section. Key HA considerations:

- **Active Session Handling**: Sessions on a terminating replica are interrupted; clients must reconnect
- **No Session Migration**: The chart does not implement session draining or migration between replicas
- **Database Dependency**: Controllers are fully dependent on PostgreSQL availability

### Scaling Recommendations

- **Minimum**: 2 replicas for basic HA
- **Production**: 3+ replicas for better fault tolerance
- **High Load**: Scale based on CPU/memory metrics and session count
- **PodDisruptionBudget**: Keeps at least 1 replica available during voluntary disruptions (enabled by default)

## Configuration Reference

The table below documents all chart values shipped in `values.yaml`.

| Key | Default | Description |
| --- | --- | --- |
| `image.repository` | `hashicorp/boundary-enterprise` | Boundary controller container image repository. |
| `image.tag` | `0.19-ent` | Image tag used by the controller container and hook jobs. |
| `image.pullPolicy` | `IfNotPresent` | Kubernetes image pull policy. |
| `imagePullSecrets` | `[]` | Optional registry credentials for private image pulls. |
| `nameOverride` | `""` | Override the chart name used in resource naming. |
| `fullnameOverride` | `""` | Override the full release name used in resource naming. |
| `tls.enabled` | `true` | Mount TLS certs into controller pods and hook jobs, and enforce TLS path validation. |
| `tls.secretName` | `boundary-controller-tls` | Name of the Kubernetes TLS Secret containing `tls.crt` and `tls.key`. |
| `tls.mountPath` | `/etc/boundary/tls` | Mount path for TLS certs inside containers. Must match paths in `controller.config`. |
| `controller.replicas` | `2` | Number of controller replicas. |
| `controller.rollingUpdate.maxUnavailable` | `1` | Maximum unavailable pods during a rolling update. |
| `controller.rollingUpdate.maxSurge` | `1` | Maximum surge pods during a rolling update. |
| `controller.config` | Embedded HCL | Raw HCL controller configuration stored in a ConfigMap and mounted into all containers. Rendered with `tpl`. |
| `controller.secretRefs.secretName` | `boundary-controller-secrets` | Name of the Kubernetes Secret containing sensitive values. Must exist before install. |
| `controller.secretRefs.validateExisting` | `true` | When true, Helm validates that the Secret exists and contains all required keys at render time. Set to `false` for offline `helm template` runs. |
| `controller.secretRefs.keys.databaseUrl` | `database-url` | Key in the Secret for the PostgreSQL connection string. |
| `controller.secretRefs.keys.license` | `license` | Key in the Secret for the Boundary Enterprise license. |
| `controller.secretRefs.keys.adminUsername` | `admin-username` | Key in the Secret for the bootstrap admin login name. Required when `bootstrapAdmin.enabled=true`. |
| `controller.secretRefs.keys.adminPassword` | `admin-password` | Key in the Secret for the bootstrap admin password. Required when `bootstrapAdmin.enabled=true`. |
| `controller.secretRefs.keys.kmsRoot` | `kms-root` | Key in the Secret for the AEAD root KMS key. Required only when using AEAD `env://` key mode. |
| `controller.secretRefs.keys.kmsWorkerAuth` | `kms-worker-auth` | Key in the Secret for the AEAD worker-auth KMS key. Required only when using AEAD `env://` key mode. |
| `controller.secretRefs.keys.kmsRecovery` | `kms-recovery` | Key in the Secret for the AEAD recovery KMS key. Required only when using AEAD `env://` key mode. |
| `controller.bootstrapAdmin.enabled` | `true` | Run the post-install bootstrap admin hook job. |
| `controller.bootstrapAdmin.runOnUpgrade` | `false` | Also run the bootstrap admin job as a post-upgrade hook. |
| `controller.bootstrapAdmin.waitTimeoutSeconds` | `120` | Seconds the bootstrap job waits for the controller API to become available. |
| `controller.bootstrapAdmin.authMethodName` | `bootstrap-password` | Display name for the password auth method created by the bootstrap job. |
| `controller.bootstrapAdmin.userResourceName` | `bootstrap-admin` | Display name for the Boundary user resource created by the bootstrap job. |
| `controller.bootstrapAdmin.accountResourceName` | `bootstrap-admin` | Display name for the Boundary account resource created by the bootstrap job. |
| `controller.bootstrapAdmin.roleName` | `bootstrap-global-admin` | Display name for the global admin role created by the bootstrap job. |
| `controller.database.migrate.enabled` | `false` | Run `boundary database migrate` as a `pre-upgrade` hook job. Pass via `--set` on the upgrade command rather than setting in your values file. |
| `controller.livenessProbe.scheme` | `HTTPS` | HTTP scheme for liveness probe requests to the ops listener. |
| `controller.livenessProbe.initialDelaySeconds` | `60` | Seconds before the first liveness probe. |
| `controller.livenessProbe.periodSeconds` | `10` | Liveness probe interval in seconds. |
| `controller.livenessProbe.failureThreshold` | `3` | Consecutive failures before the pod is restarted. |
| `controller.livenessProbe.timeoutSeconds` | `5` | Timeout in seconds for each liveness probe. |
| `controller.readinessProbe.scheme` | `HTTPS` | HTTP scheme for readiness probe requests to the ops listener. |
| `controller.readinessProbe.initialDelaySeconds` | `15` | Seconds before the first readiness probe. |
| `controller.readinessProbe.periodSeconds` | `10` | Readiness probe interval in seconds. |
| `controller.readinessProbe.failureThreshold` | `3` | Consecutive failures before the pod is removed from Service endpoints. |
| `controller.readinessProbe.timeoutSeconds` | `5` | Timeout in seconds for each readiness probe. |
| `controller.resources.requests.cpu` | `250m` | CPU request for the controller container. |
| `controller.resources.requests.memory` | `512Mi` | Memory request for the controller container. |
| `controller.resources.limits.cpu` | `500m` | CPU limit for the controller container. |
| `controller.resources.limits.memory` | `1Gi` | Memory limit for the controller container. |
| `controller.service.type` | `LoadBalancer` | Service type for the API listener. |
| `controller.service.port` | `9200` | Service port for the API listener. |
| `controller.service.targetPort` | `9200` | Container port targeted by the API Service. |
| `controller.service.clusterType` | `ClusterIP` | Service type for the cluster and ops listeners. |
| `controller.service.clusterPort` | `9201` | Service port for the cluster listener. |
| `controller.service.clusterTargetPort` | `9201` | Container port targeted by the cluster Service. |
| `controller.service.opsPort` | `9203` | Service port for the ops listener. |
| `controller.service.opsTargetPort` | `9203` | Container port targeted by the ops Service port. |
| `controller.service.annotations` | `{}` | Annotations applied to the API Service. Use for cloud load balancer configuration. |
| `podSecurityContext` | secure non-root defaults | Pod-level security context applied to controller pods and hook job pods. |
| `containerSecurityContext` | secure non-root defaults | Container-level security context with dropped Linux capabilities. |
| `podAnnotations` | `{}` | Extra annotations added to controller pods. |
| `nodeSelector` | `{}` | Node selector constraints for the controller Deployment. |
| `tolerations` | `[]` | Tolerations for controller pod scheduling. |
| `affinity` | `{}` | Affinity rules for controller pod scheduling. |
| `serviceAccount.create` | `false` | Create a ServiceAccount for the controller. |
| `serviceAccount.name` | `default` | Name of the ServiceAccount to use or create. |
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
kubectl logs -n boundary deployment/boundary
```

### Check hook job status

```bash
kubectl get jobs -n boundary
kubectl logs -n boundary job/boundary-init-db
kubectl logs -n boundary job/boundary-bootstrap-admin
```

### Upgrade with a new image tag

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  --reuse-values \
  --set image.tag=0.19.1-ent
```

### Upgrade with a new values file

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml
```

### Re-run bootstrap admin

By default the bootstrap admin job runs only on install. To re-run it on a specific upgrade — for example when rotating admin credentials — pass `--set` on the upgrade command. Do not add this to your values file; it is a one-time flag:

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.bootstrapAdmin.runOnUpgrade=true
```

### Upgrade with database migration

`boundary database migrate` uses PostgreSQL advisory locks to get exclusive access during schema changes. It cannot acquire that lock while active controllers are still connected to the database and heartbeating. Scale the Deployment to zero replicas first, then run the migration upgrade.

**Step 1 — scale controllers to zero:**

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.replicas=0
```

**Step 2 — run the migration and bring controllers back up:**

Pass `--set controller.database.migrate.enabled=true` on the upgrade command. Do not set this in your values file — it is a one-time flag. Helm runs the `pre-upgrade` migration job first, then rolls out the Deployment using the replica count from your values file, bringing the controllers back up automatically.

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.database.migrate.enabled=true
```

### Roll back a release

```bash
helm history boundary-controller -n boundary
helm rollback boundary-controller <revision> -n boundary
```

### Uninstall

```bash
helm uninstall boundary-controller -n boundary
```

Hook jobs have `ttlSecondsAfterFinished: 3600` set, so Kubernetes will automatically delete them 1 hour after they complete. They are not removed by `helm uninstall` — if you need to clean them up before the TTL expires, delete them manually:

```bash
kubectl delete jobs -n boundary -l app.kubernetes.io/instance=boundary-controller
```

## Upgrade Strategy

### Pre-Upgrade Checklist

Before upgrading the chart or Boundary version:

1. **Backup the database**: Create a PostgreSQL backup before any upgrade
2. **Review release notes**: Check Boundary release notes for breaking changes
3. **Test in non-production**: Always test upgrades in a staging environment first
4. **Check compatibility**: Verify chart and Boundary version compatibility
5. **Review configuration changes**: Check if new chart version requires config updates
6. **Verify KMS access**: Ensure KMS keys are accessible and permissions are current
7. **Check resource capacity**: Ensure cluster has capacity for rolling update surge

### Upgrade Process

**Standard Upgrade (no database migration):**

```bash
# Review what will change
helm diff upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml

# Perform the upgrade
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml
```

**Upgrade with Database Migration:**

When upgrading Boundary versions that require schema changes:

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.database.migrate.enabled=true
```

The migration job runs as a `pre-upgrade` hook before the Deployment rolls over.

### Handling Breaking Changes

When release notes indicate breaking changes:

1. **Configuration changes**: Update `controller.config` in your values file
2. **Secret key changes**: Update Secret keys if the chart changes expected key names
3. **API changes**: Update client applications if Boundary API changes
4. **KMS changes**: Verify KMS configuration remains compatible

### Rollback Procedures

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

### Post-Upgrade Verification

After upgrading:

```bash
# Check pod status
kubectl get pods -n boundary

# Verify all replicas are ready
kubectl rollout status deployment/boundary -n boundary

# Check controller logs for errors
kubectl logs -n boundary deployment/boundary --tail=100

# Verify API connectivity
curl -k https://<EXTERNAL_IP>:9200/v1/health

# Check hook job completion
kubectl get jobs -n boundary
```

## Monitoring and Observability

### Metrics Endpoints

The ops listener (port 9203) exposes health and metrics endpoints:

- **Health Check**: `GET /health` - Returns controller health status
- **Metrics**: `GET /metrics` - Prometheus-compatible metrics (if enabled in Boundary)

### Prometheus Integration

Example ServiceMonitor for Prometheus Operator:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: boundary-controller
  namespace: boundary
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: boundary
      app.kubernetes.io/component: cluster
  endpoints:
  - port: ops
    path: /metrics
    scheme: https
    tlsConfig:
      insecureSkipVerify: true
    interval: 30s
```

### Key Metrics to Monitor

- **Controller Health**: Monitor `/health` endpoint availability
- **Active Sessions**: Track concurrent session count
- **Database Connections**: Monitor PostgreSQL connection pool usage
- **API Response Times**: Track API endpoint latency
- **Error Rates**: Monitor 4xx/5xx response rates
- **Pod Resource Usage**: CPU and memory utilization per replica

### Logging Best Practices

**Structured Logging:**
Configure Boundary to output structured logs (JSON format) for easier parsing:

```hcl
controller {
  name = "boundary-controller"
  log_level = "info"
  log_format = "json"
}
```

**Log Aggregation:**
Use a log aggregation solution to collect logs from all replicas:

- **Kubernetes native**: Use `kubectl logs` with label selectors
- **ELK Stack**: Filebeat → Elasticsearch → Kibana
- **Loki**: Promtail → Loki → Grafana
- **Cloud solutions**: CloudWatch Logs, Stackdriver, Azure Monitor

**Example log query:**
```bash
kubectl logs -n boundary -l app.kubernetes.io/name=boundary --tail=100 -f
```

### Alerting Recommendations

Set up alerts for:

1. **Pod Availability**: Alert if available replicas < desired replicas
2. **High Error Rate**: Alert on sustained 5xx responses
3. **Database Connectivity**: Alert on database connection failures
4. **KMS Access Issues**: Alert on KMS authentication failures
5. **Resource Exhaustion**: Alert on high CPU/memory usage
6. **Certificate Expiration**: Alert 30 days before TLS cert expiry

### Grafana Dashboard

Create dashboards tracking:
- Request rate and latency by endpoint
- Active session count over time
- Pod resource utilization
- Database query performance
- Error rate trends

## Backup and Disaster Recovery

### What to Back Up

**Critical Components:**

1. **PostgreSQL Database**: Contains all Boundary state (users, targets, sessions, etc.)
2. **KMS Keys**: Root, recovery, and worker-auth keys (managed by your KMS provider)
3. **Kubernetes Secrets**: Database credentials, license, admin credentials
4. **Controller Configuration**: The `controller.config` HCL (stored in your values file)
5. **TLS Certificates**: If not using automated certificate management

**Not Required:**
- Controller pods (stateless, recreated from chart)
- ConfigMaps (generated from values file)

### PostgreSQL Backup Strategies

**Automated Backups:**

```bash
# Using pg_dump for logical backup
kubectl exec -n boundary deployment/postgres -- \
  pg_dump -U boundary boundary > boundary-backup-$(date +%Y%m%d).sql

# Using pg_basebackup for physical backup
kubectl exec -n boundary deployment/postgres -- \
  pg_basebackup -D /backup -F tar -z -P
```

**Continuous Archiving:**
- Enable PostgreSQL WAL archiving for point-in-time recovery
- Use cloud-native backup solutions (AWS RDS automated backups, GCP Cloud SQL backups, Azure Database for PostgreSQL backups)
## Frequently Asked Questions

### Why doesn't the chart integrate with cert-manager?

The chart intentionally remains unopinionated about certificate management. Organizations have diverse certificate workflows (cert-manager, external CAs, cloud-native solutions, manual processes). By requiring a pre-existing TLS Secret, the chart supports all approaches without forcing a specific tool dependency.

**To use cert-manager**, create a Certificate resource that populates the expected Secret:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: boundary-controller-tls
  namespace: boundary
spec:
  secretName: boundary-controller-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - boundary.example.com
```

### Can I use this chart with HCP Boundary?

No. This chart is designed for self-managed Boundary deployments where you control the controller infrastructure. HCP Boundary is a fully managed service where HashiCorp operates the control plane. If you're using HCP Boundary, you only need to deploy workers, not controllers.

### How do I rotate KMS keys?

KMS key rotation depends on your KMS provider:

**AWS KMS**: Enable automatic key rotation in AWS KMS console. AWS handles rotation transparently.

**GCP Cloud KMS**: Enable automatic rotation when creating the key. GCP manages rotation automatically.

**Azure Key Vault**: Enable automatic rotation in Key Vault. Azure handles rotation.

**Vault Transit**: Rotate keys using Vault CLI:
```bash
vault write -f transit/keys/boundary-root/rotate
```

Boundary automatically uses the latest key version. No controller restart required.

### How do I scale the number of replicas?

Update the replica count and upgrade:

```bash
helm upgrade boundary-controller . \
  --namespace boundary \
  --reuse-values \
  --set controller.replicas=3
```

Or update your values file:
```yaml
controller:
  replicas: 3
```

Consider your load, fault tolerance requirements, and cluster capacity when choosing replica count.

### What happens to active sessions during an upgrade?

During a rolling update:
1. New pods start with updated configuration
2. Once ready, old pods receive SIGTERM
3. Controllers wait `graceful_shutdown_wait_duration` for sessions to complete
4. After timeout, remaining sessions are terminated
5. Clients automatically reconnect to healthy replicas

**Best practice**: Schedule upgrades during maintenance windows when possible.

### How do I migrate from another deployment method?

To migrate from a different Boundary deployment to this chart:

1. **Backup your PostgreSQL database**
2. **Document your current configuration** (KMS keys, listener config, etc.)
3. **Create Kubernetes Secrets** with database URL and license
4. **Translate your config** to the chart's `controller.config` format
5. **Deploy the chart** pointing to your existing database
6. **Verify functionality** before decommissioning old deployment
7. **Update DNS/load balancer** to point to new Service

The database schema remains compatible, so controllers can share the same database during migration.

### Can I run controllers and workers in the same cluster?

Yes, but it's not required. Common patterns:

- **Separate clusters**: Controllers in management cluster, workers in workload clusters
- **Same cluster**: Both in same cluster, different namespaces
- **Hybrid**: Controllers in Kubernetes, workers on VMs/bare metal

The chart only manages controllers. Deploy workers separately using your preferred method.

### How do I handle database schema migrations?

Database migrations are handled by the `boundary database migrate` command. The chart provides a hook job for this:

```bash
# Run migration during upgrade
helm upgrade boundary-controller . \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.database.migrate.enabled=true
```

**Important**: Always backup the database before running migrations. Migrations are not automatically reversed on rollback.

### What's the difference between the API and cluster Services?

- **API Service** (`LoadBalancer`, port 9200): Client traffic (CLI, UI, API calls). Exposed externally.
- **Cluster Service** (`ClusterIP`, port 9201): Worker registration and inter-controller communication. Internal only.
- **Ops listener** (port 9203 on cluster Service): Health checks and metrics. Internal only.

### How do I troubleshoot "database already initialized" errors?

This occurs when the database init job runs against an already-initialized database. Solutions:

1. **If intentional** (reusing existing database): This is expected. The error is harmless.
2. **If unintentional** (fresh install): The database may have been initialized by a previous installation. Either:
   - Use the existing database (ensure it's compatible)
   - Drop and recreate the database for a fresh start

The init job is idempotent and safe to run multiple times.

### Can I use a different PostgreSQL version?

Boundary supports PostgreSQL 12+. Tested versions:
- PostgreSQL 12, 13, 14, 15, 16

Always check the [Boundary documentation](https://developer.hashicorp.com/boundary/docs) for the latest compatibility information.

### How do I enable debug logging?

Temporarily enable debug logging:

```yaml
controller:
  config: |
    controller {
      log_level = "debug"
      log_format = "json"
      # ... rest of config
    }
```

Then upgrade the release. Remember to revert to `info` level after debugging to avoid excessive log volume.


**Backup Frequency:**
- **Production**: Daily full backups + continuous WAL archiving
- **Staging**: Daily or weekly backups
- **Retention**: Keep at least 30 days of backups

### KMS Key Backup

**Cloud KMS Providers:**
- AWS KMS: Keys are automatically backed up by AWS
- GCP Cloud KMS: Keys are automatically backed up by Google
- Azure Key Vault: Keys are automatically backed up by Azure

**Vault Transit:**
- Back up Vault's storage backend
- Export and securely store Vault unseal keys
- Document Vault recovery procedures

### Secret Backup

Back up the Kubernetes Secret containing sensitive values:

```bash
kubectl get secret boundary-controller-secrets -n boundary -o yaml > boundary-secrets-backup.yaml
```

**Security Note**: Store secret backups in a secure location (encrypted storage, secrets manager, password vault).

### Disaster Recovery Procedures

**Complete Cluster Loss:**

1. Provision new Kubernetes cluster
2. Restore PostgreSQL database from backup
3. Recreate Kubernetes Secrets from secure backup
4. Verify KMS key access from new cluster
5. Install chart with same configuration
6. Verify controller connectivity and functionality

**Database Corruption:**

1. Stop all controller replicas: `kubectl scale deployment/boundary --replicas=0 -n boundary`
2. Restore PostgreSQL from most recent backup
3. Restart controllers: `kubectl scale deployment/boundary --replicas=2 -n boundary`
4. Verify data integrity and session functionality

**Recovery Time Objectives:**

- **RTO (Recovery Time Objective)**: Target < 1 hour for production
- **RPO (Recovery Point Objective)**: Target < 15 minutes with WAL archiving

### Testing Recovery Procedures

**Regular Testing:**
- Test database restore procedures quarterly
- Verify backup integrity monthly
- Document and update recovery runbooks
- Conduct disaster recovery drills annually

**Test Checklist:**
```bash
# 1. Restore database to test environment
psql -U boundary -d boundary_test < boundary-backup.sql

# 2. Deploy chart to test namespace
helm install boundary-test . -n boundary-test -f my-values.yaml

# 3. Verify functionality
curl -k https://<TEST_IP>:9200/v1/health

# 4. Test authentication and session creation
boundary authenticate password -auth-method-id=ampw_1234567890
```

## Troubleshooting

### Common Issues

#### Database Connection Failures

**Symptoms:**
- Controller pods crash or restart repeatedly
- Logs show "failed to connect to database" errors

**Solutions:**
```bash
# Check database connectivity from pod
kubectl exec -n boundary deployment/boundary -- \
  nc -zv postgres-host 5432

# Verify Secret contains correct database URL
kubectl get secret boundary-controller-secrets -n boundary -o jsonpath='{.data.database-url}' | base64 -d

# Check PostgreSQL logs
kubectl logs -n boundary deployment/postgres

# Verify network policies allow controller → database traffic
kubectl get networkpolicies -n boundary
```

#### KMS Authentication Failures

**Symptoms:**
- Controller logs show KMS authentication errors
- Pods fail to start with "failed to initialize KMS" errors

**Solutions:**

**AWS KMS:**
```bash
# Verify IRSA annotation on ServiceAccount
kubectl get sa boundary-controller -n boundary -o yaml

# Check IAM role has KMS permissions
aws iam get-role-policy --role-name boundary-controller-role --policy-name kms-access

# Test KMS access from pod
kubectl exec -n boundary deployment/boundary -- \
  aws kms describe-key --key-id alias/boundary-root
```

**Vault Transit:**
```bash
# Verify Vault token is valid
kubectl exec -n boundary deployment/boundary -- \
  vault token lookup

# Check Transit engine is enabled
vault secrets list

# Verify key exists
vault read transit/keys/boundary-root
```

#### TLS Certificate Issues

**Symptoms:**
- Liveness/readiness probes fail
- Clients cannot connect to API
- Logs show "TLS handshake failed" errors
- Chart rendering fails with "TLS path validation error"

**Solutions:**
```bash
# Verify TLS Secret exists and contains correct keys
kubectl get secret boundary-controller-tls -n boundary
kubectl get secret boundary-controller-tls -n boundary -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Check certificate expiration
kubectl get secret boundary-controller-tls -n boundary -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -enddate -noout

# Verify certificate matches private key
kubectl get secret boundary-controller-tls -n boundary -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -modulus -noout | openssl md5
kubectl get secret boundary-controller-tls -n boundary -o jsonpath='{.data.tls\.key}' | base64 -d | openssl rsa -modulus -noout | openssl md5
```

**TLS Path Validation Errors:**

If `helm install` or `helm template` fails with a TLS path validation error, the chart detected a mismatch between `tls.mountPath` and the paths in your `controller.config`:

```
Error: TLS path validation failed: tls_cert_file must reference /etc/boundary/tls/tls.crt
```

**Solution**: Ensure `tls_cert_file` and `tls_key_file` in all listener blocks match `tls.mountPath`:

```hcl
listener "tcp" {
  address       = "0.0.0.0:9200"
  purpose       = "api"
  tls_cert_file = "/etc/boundary/tls/tls.crt"  # Must match tls.mountPath
  tls_key_file  = "/etc/boundary/tls/tls.key"  # Must match tls.mountPath
}
```

Or if you've customized `tls.mountPath`:

```yaml
tls:
  mountPath: /custom/tls/path

controller:
  config: |
    listener "tcp" {
      tls_cert_file = "/custom/tls/path/tls.crt"
      tls_key_file  = "/custom/tls/path/tls.key"
    }
```

#### Pod Startup Failures

**Symptoms:**
- Pods stuck in `CrashLoopBackOff` or `Error` state
- Pods stuck in `Init:0/1` or `Init:Error` state
- Init containers fail

**Solutions:**
```bash
# Check pod events
kubectl describe pod -n boundary <pod-name>

# View pod logs (main container)
kubectl logs -n boundary <pod-name>

# View init container logs if stuck in Init
kubectl logs -n boundary <pod-name> -c <init-container-name>

# Check resource constraints
kubectl top pods -n boundary

# Verify image pull
kubectl get events -n boundary | grep -i pull

# Common Init issues:
# - Secret not found: Verify boundary-controller-secrets exists
# - TLS Secret not found: Verify boundary-controller-tls exists
# - ConfigMap not found: Check if chart rendered correctly
```

#### Hook Job Failures

**Symptoms:**
- Database init job fails during install
- Migration job fails during upgrade
- Bootstrap admin job fails

**Solutions:**
```bash
# Check job status
kubectl get jobs -n boundary

# View job logs
kubectl logs -n boundary job/boundary-init-db
kubectl logs -n boundary job/boundary-migrate-db
kubectl logs -n boundary job/boundary-bootstrap-admin

# Manually run database init (if job failed)
kubectl exec -n boundary deployment/boundary -- \
  boundary database init -config /boundary/config.hcl

# Delete failed job and retry
kubectl delete job boundary-init-db -n boundary
helm upgrade boundary-controller . -n boundary -f my-values.yaml
```

#### High Memory Usage

**Symptoms:**
- Pods being OOMKilled
- High memory usage in metrics

**Solutions:**
```bash
# Check current resource usage
kubectl top pods -n boundary

# Increase memory limits
helm upgrade boundary-controller . -n boundary \
  --set controller.resources.limits.memory=2Gi

# Check for memory leaks in logs
kubectl logs -n boundary deployment/boundary | grep -i "memory\|oom"
```

#### Session Connection Issues

**Symptoms:**
- Clients can authenticate but cannot establish sessions
- Workers cannot register with controllers

**Solutions:**
```bash
# Verify cluster Service is accessible
kubectl get svc boundary-cluster -n boundary

# Check public_cluster_addr in config
kubectl get configmap boundary-config -n boundary -o yaml

# Test cluster listener connectivity
kubectl exec -n boundary deployment/boundary -- \
  nc -zv boundary-cluster 9201

# Check worker logs for connection errors
# (on worker nodes)
```

### Debug Mode

Enable debug logging temporarily:

```bash
# Update log level in controller config
helm upgrade boundary-controller . -n boundary \
  --set controller.config="$(cat <<EOF
controller {
  log_level = "debug"
  # ... rest of config
}
EOF
)"

# View debug logs
kubectl logs -n boundary deployment/boundary -f
```

### Getting Help

If issues persist:

1. Collect diagnostic information:
```bash
kubectl get all -n boundary
kubectl describe deployment boundary -n boundary
kubectl logs -n boundary deployment/boundary --tail=200
kubectl get events -n boundary --sort-by='.lastTimestamp'
```

2. Check Boundary documentation: https://developer.hashicorp.com/boundary/docs
3. Review chart issues: (link to your repository issues)
4. Contact HashiCorp support (for Enterprise customers)

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
- The cluster and ops Services default to `ClusterIP` and are not exposed externally.
- Secret validation at render time (`controller.secretRefs.validateExisting=true`) catches missing credentials before any resources are created.

## Repository Layout

```text
.
├── Chart.yaml
├── README.md
├── values.yaml
└── templates/
    ├── _helpers.tpl
    ├── NOTES.txt
    ├── bootstrap-admin-job.yaml
    ├── configmap.yaml
    ├── db-init-job.yaml
    ├── db-migrate-job.yaml
    ├── deployment.yaml
    ├── pdb.yaml
    ├── service.yaml
    └── serviceaccount.yaml
```

Key files:

- `values.yaml`: default chart values
- `templates/deployment.yaml`: multi-replica controller Deployment
- `templates/service.yaml`: API (LoadBalancer) and cluster/ops (ClusterIP) Services
- `templates/configmap.yaml`: mounted controller HCL configuration
- `templates/db-init-job.yaml`: pre-install database initialization hook
- `templates/db-migrate-job.yaml`: pre-upgrade database migration hook
- `templates/bootstrap-admin-job.yaml`: post-install admin bootstrap hook
- `templates/pdb.yaml`: PodDisruptionBudget
- `templates/serviceaccount.yaml`: optional ServiceAccount
- `templates/_helpers.tpl`: shared template helpers and validation functions

## Known Limitations

The current chart intentionally does not attempt to solve the following problems:

- Horizontal pod autoscaling
- Automatic drain or handoff of active sessions during upgrades
- TLS certificate issuance or renewal — the chart expects a pre-existing Kubernetes TLS Secret (`tls.crt` / `tls.key`); it does not integrate with cert-manager, ACM, or any other certificate authority
- Ingress or DNS automation
- Worker deployment or worker topology management
- Secret generation, Vault Agent Injector integration, or external secret operator wiring (Vault Secrets Operator, External Secrets Operator) — the chart expects the Kubernetes Secret to already exist; how it gets there is outside the chart's scope
- Multi-cluster or multi-region controller topologies

## Contributing

When submitting changes, include:

- A clear description of the behavior or documentation change
- Validation notes with the commands you ran
- Any chart value changes that affect install or upgrade workflows