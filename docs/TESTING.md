# Testing Guide

This document describes the test suite for the Boundary Controller Helm chart.

## Overview

The chart includes comprehensive test coverage for validation before deployment:

- **Unit Tests**: Helm template rendering and validation checks via [`helm-unittest`](https://github.com/helm-unittest/helm-unittest)
- **Chart Tests**: Helm `test` hook resources that run inside a live Kubernetes cluster
- **Acceptance Tests**: Local KIND cluster tests that validate controller functionality

## Table of Contents

- [Prerequisites](#prerequisites)
	- [Unit Test Prerequisites](#unit-test-prerequisites)
	- [Acceptance Test Prerequisites](#acceptance-test-prerequisites)
- [Recommended Test Flow](#recommended-test-flow)
- [Unit Tests](#unit-tests)
	- [Quick Unit Test Command](#quick-unit-test-command)
	- [Unit Coverage Matrix](#unit-coverage-matrix)
- [Chart Tests](#chart-tests)
	- [Quick Chart Test Command](#quick-chart-test-command)
- [Acceptance Tests](#acceptance-tests)
	- [Quick Test Commands](#quick-test-commands)
	- [Setup](#setup)
	- [Cluster Smoke Test](#cluster-smoke-test)
	- [Controller API Test](#controller-api-test)
	- [KIND Version Matrix Test](#kind-version-matrix-test)
- [Cloud Integration Tests (EKS/AKS/GKE)](#cloud-integration-tests-eksaksgke)
	- [Prerequisites](#prerequisites-1)
	- [Environment Keys](#environment-keys)
	- [Run EKS Integration](#run-eks-integration)
		- [Run With Local Repo Chart](#run-with-local-repo-chart)
		- [Run With Released Chart](#run-with-released-chart)
	- [Run AKS Integration](#run-aks-integration)
	- [Run GKE Integration](#run-gke-integration)
	- [Expected Runtime](#expected-runtime)
- [Test Configuration](#test-configuration)
	- [Test Values](#test-values)
	- [In-Cluster PostgreSQL](#in-cluster-postgresql)
- [Troubleshooting](#troubleshooting)
	- [Test Failures](#test-failures)
	- [Cleanup](#cleanup)
- [CI/CD Integration](#cicd-integration)
- [Adding New Tests](#adding-new-tests)
- [Test Maintenance](#test-maintenance)
	- [Updating Matrix Versions](#updating-matrix-versions)
	- [Updating Test Values](#updating-test-values)

## Prerequisites

### Unit Test Prerequisites

Unit tests (`make unit-test`) require:

- `helm` CLI installed (v3+)
- Helm `unittest` plugin installed

Install/check plugin:

```bash
helm plugin list | grep unittest || helm plugin install https://github.com/helm-unittest/helm-unittest.git
```

### Acceptance Test Prerequisites

Acceptance tests require:

- Docker running locally
- `kubectl` CLI installed
- `helm` CLI installed
- `boundary` CLI installed
- KIND for local cluster testing
- `.env` file with Boundary credentials

### Chart Test Prerequisites

Chart tests (`make chart-test`) require:

- `helm` CLI installed
- A release already installed in a live cluster
- Access to the target namespace/context used by the installed release

## Recommended Test Flow

Use the test suite in this order when validating chart changes:

1. `make unit-test`
2. `make acceptance-setup`
3. `make acceptance-helm`
4. `make chart-test`
5. `make acceptance-test`

What each step does:

- `make unit-test`: validates Helm template rendering and chart logic without installing anything into a cluster.
- `make acceptance-setup`: installs acceptance dependencies and creates the KIND cluster.
- `make acceptance-helm`: deploys PostgreSQL, creates required secrets, runs `helm upgrade --install`, and waits for the chart installation to become ready on KIND.
- `make chart-test`: runs Helm `test` hook resources against the installed release and streams test pod logs.
- `make acceptance-test`: runs post-install runtime checks against the deployed release.

If you want the complete cluster-backed flow in one command, run:

```bash
make acceptance-full
```

`make acceptance-full` combines cluster setup, Helm installation, and post-install acceptance checks.

## Unit Tests

### Quick Unit Test Command

Run from the chart root:

```bash
make unit-test
```

### Unit Coverage Matrix

This matrix maps major values groups to the current unit test suites.

| Values group | Primary templates affected | Unit test coverage |
| --- | --- | --- |
| `nameOverride`, `fullnameOverride`, `namespace` | deployment, services, jobs, configmap, pdb | [tests/unit/helpers_test.yaml](../tests/unit/helpers_test.yaml), [tests/unit/service_test.yaml](../tests/unit/service_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml), [tests/unit/configmap_test.yaml](../tests/unit/configmap_test.yaml), [tests/unit/pdb_test.yaml](../tests/unit/pdb_test.yaml) |
| `image.repository`, `image.tag`, `image.pullPolicy` | deployment, all jobs | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml) |
| `imagePullSecrets` | deployment, jobs | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml) |
| `extraEnv` | deployment, all jobs | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml) |
| `serviceAccount.name`, `serviceAccount.automountServiceAccountToken` | deployment, all jobs | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml), [tests/unit/helpers_test.yaml](../tests/unit/helpers_test.yaml) |
| `tls.disabled`, `tls.mountPath`, `tls.secretName` | deployment, services, jobs, validate | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml), [tests/unit/validate_test.yaml](../tests/unit/validate_test.yaml), [tests/unit/configmap_test.yaml](../tests/unit/configmap_test.yaml) |
| `secretRefs.secretName`, `secretRefs.keys.*` | deployment, jobs, bootstrap | [tests/unit/helpers_test.yaml](../tests/unit/helpers_test.yaml), [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml) |
| `secretRefs.validateExisting` | validate helper (`lookup`) | [tests/unit/validate_test.yaml](../tests/unit/validate_test.yaml) (missing-secret negative path) |
| `controller.replicas`, `controller.rollingUpdate.*` | deployment | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml) |
| `controller.livenessProbe.*`, `controller.readinessProbe.*` | deployment | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml) |
| `controller.resources` | deployment | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml) |
| `controller.service.*` (type/ports/targetPort/annotations) | services, deployment container ports | [tests/unit/service_test.yaml](../tests/unit/service_test.yaml), [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml) |
| `database.init.enabled`, `database.migrate.enabled`, `database.repair.version` | db jobs | [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml) |
| `database.resources` | db jobs | [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml) |
| `bootstrapAdmin.*` (enabled, runOnUpgrade, timeout/name fields, resources) | bootstrap job | [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml) |
| `podSecurityContext`, `containerSecurityContext` | deployment and jobs | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml), [tests/unit/db-init-job_test.yaml](../tests/unit/db-init-job_test.yaml), [tests/unit/db-migrate-job_test.yaml](../tests/unit/db-migrate-job_test.yaml), [tests/unit/db-repair-job_test.yaml](../tests/unit/db-repair-job_test.yaml), [tests/unit/bootstrap-admin-job_test.yaml](../tests/unit/bootstrap-admin-job_test.yaml) |
| `podAnnotations`, `nodeSelector`, `tolerations`, `affinity` | deployment | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml) |
| `podDisruptionBudget.*` | pdb | [tests/unit/pdb_test.yaml](../tests/unit/pdb_test.yaml) |
| `terminationGracePeriodSeconds` | deployment | [tests/unit/deployment_test.yaml](../tests/unit/deployment_test.yaml) |
| `controller.config` validation behavior | validate helper | [tests/unit/validate_test.yaml](../tests/unit/validate_test.yaml), [tests/unit/configmap_test.yaml](../tests/unit/configmap_test.yaml) |

## Chart Tests

The chart now includes Helm test hook resources under `templates/tests/` and can be run with `helm test` after install/upgrade.

### Quick Chart Test Command

Run against the default release/namespace:

```bash
make chart-test
```

Override release, namespace, or kube-context when needed:

```bash
make chart-test \
	HELM_TEST_RELEASE=boundary-controller \
	HELM_TEST_NAMESPACE=boundary \
	HELM_TEST_KUBE_CONTEXT=kind-acceptance
```

Current Helm test coverage:

- Ops service health endpoint reachable from inside the cluster (`/health` returns HTTP `200`)

## Acceptance Tests

### Quick Test Commands

Run these from the chart root:

```bash
# Cluster smoke test
bash tests/acceptance/cluster-smoke-test.sh

# Controller API test
bash tests/acceptance/controller-api-test.sh

# KIND version matrix test
bash tests/acceptance/kind-version-matrix-test.sh
```

### Setup

Create a `.env` file in the chart root directory:

```bash
# Required for all tests
BOUNDARY_LICENSE="<your-boundary-enterprise-license>"

# Required for bootstrap admin tests
BOOTSTRAP_ADMIN_USERNAME="admin"
BOOTSTRAP_ADMIN_PASSWORD="<secure-password>"
```

### Cluster Smoke Test

Basic validation that a KIND cluster can be created and accessed.

```bash
cd boundary-controller-helm
bash tests/acceptance/cluster-smoke-test.sh
```

**What it tests:**
- KIND cluster accessibility
- Namespace creation
- Basic kubectl operations

**Duration:** ~30 seconds

### Controller API Test

Comprehensive validation of controller deployment and API functionality.

```bash
cd boundary-controller-helm
bash tests/acceptance/controller-api-test.sh
```

**What it tests:**
1. Controller deployment in KIND cluster
2. Controller ops health endpoint (`/health` on port 9203)
3. Controller API endpoint reachability (port 9200)
4. Bootstrap admin authentication
5. Auth methods listing via API

**Duration:** ~5-10 minutes

**Requirements:**
- `.env` file with `BOUNDARY_LICENSE`, `BOOTSTRAP_ADMIN_USERNAME`, `BOOTSTRAP_ADMIN_PASSWORD`
- PostgreSQL deployed in-cluster (handled automatically)
- Controller secrets created (handled automatically)

### KIND Version Matrix Test

Tests controller-api-test.sh across configured Kubernetes versions backed by `kindest/node` images.

```bash
cd boundary-controller-helm
bash tests/acceptance/kind-version-matrix-test.sh
```

**What it tests:**
- Controller functionality across different Kubernetes versions
- Uses the exact versions provided in `K8S_MATRIX_VERSIONS`
- Supports a one-off local override via `K8S_VERSIONS`

**Version source:**

- Local and CI default: `K8S_MATRIX_VERSIONS="v1.36.1,v1.35.5,v1.34.8"`
- Local one-off override: `K8S_VERSIONS="v1.35.1"`
- Available tags reference: https://hub.docker.com/r/kindest/node

**Examples:**

```bash
# Run all configured versions
export K8S_MATRIX_VERSIONS="v1.36.1,v1.35.5,v1.34.8"
make kind-matrix-test

# Run a single version locally
K8S_VERSIONS="v1.35.1" make kind-matrix-test

# Print the resolved version list without creating clusters
PRINT_RESOLVED_K8S_VERSIONS=true \
K8S_MATRIX_VERSIONS="v1.36.1,v1.35.5,v1.34.8" \
bash tests/acceptance/kind-version-matrix-test.sh
```

**Process:**
1. Reads configured Kubernetes versions from `K8S_MATRIX_VERSIONS` or `K8S_VERSIONS`
2. Creates fresh KIND cluster for each version
3. Pre-loads the controller image into KIND
4. Pre-loads PostgreSQL 16 into KIND
5. Deploys in-cluster PostgreSQL and waits until ready
6. Creates controller secrets
7. Installs Helm chart with test values
8. Runs controller-api-test.sh
9. Tears down cluster
10. Repeats for the next configured version

## Cloud Integration Tests (EKS/AKS/GKE)

Cloud integration tests provision real managed Kubernetes clusters, deploy the chart, and run runtime validation checks.

### Prerequisites

- Terraform CLI
- kubectl CLI
- Helm CLI
- For EKS: aws CLI with valid credentials
- For AKS: az CLI with valid login (`az login`)
- For GKE: gcloud CLI authenticated (`gcloud auth login`) with ADC configured (`gcloud auth application-default login`)
- A populated integration environment file at `tests/integration/.env` (EKS/AKS/GKE)

### Environment Keys

At minimum, configure the shared values below in `tests/integration/.env`:

- `TF_VAR_boundary_license`
- `TF_VAR_boundary_admin_password`
- `TF_VAR_boundary_db_url`

EKS-specific keys:

- `TF_VAR_aws_region`
- `TF_VAR_eks_cluster_name`

AKS-specific keys:

- `TF_VAR_aks_cluster_name`
- `TF_VAR_resource_group_name`
- Optional: `TF_VAR_azure_subscription_id`
- Optional: `TF_VAR_azure_location`
- Optional sizing: `TF_VAR_node_vm_size`, `TF_VAR_node_count`

GKE-specific keys (set in `tests/integration/.env`):

- `TF_VAR_gcp_project_id` — GCP project ID (required)
- Optional: `TF_VAR_gcp_region` (default: `us-central1`)
- Optional: `TF_VAR_gke_zone` (default: `us-central1-a`)
- Optional: `TF_VAR_gke_cluster_name` (default: `boundary-controller-cluster`)
- Optional: `TF_VAR_gke_kubernetes_version` — pin a specific GKE master version; leave empty for release-channel default
- Optional sizing: `TF_VAR_node_machine_type` (default: `e2-standard-2`), `TF_VAR_node_count` (default: `2`)
- Optional image: `TF_VAR_image_tag` (default: `0.21-ent`)

You can copy starter keys from `tests/integration/.env.example`.

### Run EKS Integration

```bash
# Provision + deploy
make eks-apply

# Validate runtime health
make eks-test

# Or run end-to-end
make eks-full

# Cleanup (default: uninstall Helm release only)
make eks-destroy

# Cleanup (destroy EKS infrastructure as well)
make eks-destroy DESTROY_EKS_RESOURCES=true
```

#### Run With Local Repo Chart

Use these values in `tests/integration/.env` (default behavior):

```bash
TF_VAR_chart_path=../../../../
TF_VAR_chart_repository=
TF_VAR_chart_version=
```

Then run:

```bash
make eks-apply
make eks-test
```

#### Run With Released Chart

Use these values in `tests/integration/.env` to install from a Helm repository:

```bash
TF_VAR_chart_path=boundary-controller
TF_VAR_chart_repository=https://<your-helm-repository>
TF_VAR_chart_version=<released-version>
```

Then run:

```bash
make eks-apply
make eks-test
```

Notes:

- Keep `TF_VAR_chart_version` set when using `TF_VAR_chart_repository`.
- `eks-integration-test.sh` does not change for either mode; it validates the deployed release in-cluster.

### Run AKS Integration

```bash
# Provision + deploy
make aks-apply

# Validate runtime health
make aks-test

# Or run end-to-end
make aks-full

# Cleanup (default: uninstall Helm release only)
make aks-destroy

# Cleanup (destroy AKS infrastructure as well)
make aks-destroy DESTROY_AKS_RESOURCES=true
```

### Run GKE Integration

```bash
# Provision GKE cluster + deploy chart
make gke-apply

# Validate runtime health
make gke-test

# Or run end-to-end (setup + apply + test)
make gke-full

# Cleanup (default: uninstall Helm release only)
make gke-destroy

# Cleanup (destroy GKE infrastructure as well)
make gke-destroy DESTROY_GKE_RESOURCES=true
```

`gke-apply` runs in two phases: first it provisions the VPC and GKE cluster, updates the local kubeconfig via `gcloud container clusters get-credentials`, then applies the remaining Terraform resources (IAM, in-cluster PostgreSQL, Helm chart). A DB-init recovery step runs automatically after the Helm install to re-trigger pre-install hooks if the controller reports an uninitialized database.

The test script (`tests/integration/gke-integration-test.sh`) accepts optional flags when run directly:

```bash
bash tests/integration/gke-integration-test.sh \
  --project-id  <GCP_PROJECT_ID> \
  --zone        us-central1-a \
  --cluster-name boundary-controller-cluster \
  --namespace   boundary \
  --release     boundary-controller \
  --timeout     300
```

Add `--skip-api` to bypass the ops-health and API endpoint checks.

**What it validates:**
1. Required CLI tools available (`kubectl`, `helm`, `gcloud`, `curl`, `python3`)
2. GKE cluster connectivity and kubeconfig update
3. Kubernetes namespace exists
4. Helm release status is `deployed`
5. Kubernetes resources present (Deployment, ConfigMap, Secret, ServiceAccount, PDB, Services)
6. Deployment rollout complete with all replicas ready
7. Controller ops health endpoint (`/health` on port 9203) returns HTTP `200`
8. Controller API endpoint reachable (port 9200)

### Expected Runtime

- `make eks-apply`: typically 20-40 minutes (varies by region and account limits)
- `make aks-apply`: typically 15-35 minutes (varies by region and subscription quotas)
- `make gke-apply`: typically 10-20 minutes (varies by project and zone)
- `make eks-test` / `make aks-test` / `make gke-test`: typically 2-8 minutes

For cost control, destroy infrastructure after validation:
- EKS: `make eks-destroy DESTROY_EKS_RESOURCES=true`
- AKS: `make aks-destroy DESTROY_AKS_RESOURCES=true`
- GKE: `make gke-destroy DESTROY_GKE_RESOURCES=true`

## Test Configuration

### Test Values

The acceptance tests use `tests/acceptance/test-values.yaml` which configures:

- TLS disabled for testing
- 2 controller replicas
- Inline AEAD KMS test keys (no cloud credentials required)
- Complete controller config with database, license, and events blocks
- Extended bootstrap timeout (300s)

### In-Cluster PostgreSQL

Tests deploy PostgreSQL using `tests/acceptance/postgres.yaml`:

- Single replica PostgreSQL 16
- Database: `boundary`
- User: `boundary`
- Password: `boundary-test-pw`
- Internal service: `postgres.boundary.svc.cluster.local:5432`

**Note:** This is for testing only. Production deployments should use managed PostgreSQL services.

## Troubleshooting

### Test Failures

**Controller pods not ready:**
```bash
kubectl get pods -n boundary
kubectl logs -n boundary -l app.kubernetes.io/name=boundary-controller
```

**Database connection issues:**
```bash
kubectl logs -n boundary -l app=postgres
kubectl get svc -n boundary postgres
```

**Bootstrap admin job failed:**
```bash
kubectl get jobs -n boundary
kubectl logs -n boundary job/boundary-controller-bootstrap-admin
```

### Cleanup

If tests fail and leave resources behind:

```bash
# Delete KIND cluster
kind delete cluster --name acceptance

# Clean up cached KIND binaries (optional)
rm -f /tmp/kind-v*
```


## CI/CD Integration

The tests are integrated into GitHub Actions workflows:

- **PR validation**: Runs on non-draft pull requests targeting `main`
- **Manual dispatch**: Supports optional `k8s_versions` input to override the configured matrix
- **Acceptance fan-out**: Resolves the configured Kubernetes versions once, then runs one acceptance job per version in parallel

The acceptance workflow reads Kubernetes versions from the repository variable `K8S_MATRIX_VERSIONS` when the manual `k8s_versions` input is empty.

Example repository variable:

```text
K8S_MATRIX_VERSIONS=v1.36.1,v1.35.5,v1.34.8
```

See `.github/workflows/ci.yaml` for configuration.

## Adding New Tests

When adding new acceptance tests:

1. Place test scripts in `tests/acceptance/`
2. Make scripts executable: `chmod +x tests/acceptance/your-test.sh`
3. Follow existing patterns for cleanup traps
4. Document test purpose and requirements
5. Update this guide with test description

## Test Maintenance

### Updating Matrix Versions

Update the repository variable `K8S_MATRIX_VERSIONS` with the ordered `kindest/node` tags you want to test.

Example:

```text
K8S_MATRIX_VERSIONS=v1.36.1,v1.35.5,v1.34.8
```

For one-off local runs, override with `K8S_VERSIONS` instead of editing files.

Reference available tags: https://hub.docker.com/r/kindest/node

### Updating Test Values

To modify test configuration, edit `tests/acceptance/test-values.yaml`.

**Important:** Keep test values minimal and focused on testing requirements. Don't add production-specific configuration.