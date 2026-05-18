# Testing Guide

This document describes the test suite for the Boundary Controller Helm chart.

## Overview

The chart includes comprehensive test coverage for validation before deployment:

- **Acceptance Tests**: Local KIND cluster tests that validate controller functionality
- **Unit Tests**: Helm template rendering validation (future)

## Prerequisites

Acceptance tests require:

- Docker running locally
- `kubectl` CLI installed
- `helm` CLI installed
- `boundary` CLI installed
- KIND for local cluster testing
- `.env` file with Boundary credentials

## Acceptance Tests

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

Tests controller-api-test.sh across multiple KIND versions for compatibility validation.

```bash
cd boundary-controller-helm
bash tests/acceptance/kind-version-matrix-test.sh
```

**What it tests:**
- Controller functionality across different Kubernetes versions
- Automatically resolves latest stable KIND releases
- Falls back to hardcoded versions when offline
- Tests against two most recent KIND versions

**Duration:** ~15-20 minutes (runs full test suite twice)

**Process:**
1. Downloads pinned KIND binaries (cached in `/tmp`)
2. Creates fresh KIND cluster for each version
3. Deploys in-cluster PostgreSQL
4. Creates controller secrets
5. Installs Helm chart with test values
6. Runs controller-api-test.sh
7. Tears down cluster
8. Repeats for next version

## Test Configuration

### Test Values

The acceptance tests use `tests/acceptance/test-values.yaml` which configures:

- TLS disabled for testing
- 2 controller replicas
- AEAD KMS (no cloud credentials required)
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

- **PR validation**: Runs on pull requests
- **Push validation**: Runs on pushes to main branches
- **Release validation**: Runs before creating releases

See `.github/workflows/ci.yaml` for configuration.

## Adding New Tests

When adding new acceptance tests:

1. Place test scripts in `tests/acceptance/`
2. Make scripts executable: `chmod +x tests/acceptance/your-test.sh`
3. Follow existing patterns for cleanup traps
4. Document test purpose and requirements
5. Update this guide with test description

## Test Maintenance

### Updating KIND Versions

The matrix test automatically resolves latest KIND versions. To update fallback versions:

Edit `tests/acceptance/kind-version-matrix-test.sh`:

```bash
_FALLBACK_KIND_VERSIONS=("v0.30.0" "v0.29.0")
```

### Updating Test Values

To modify test configuration, edit `tests/acceptance/test-values.yaml`.

**Important:** Keep test values minimal and focused on testing requirements. Don't add production-specific configuration.