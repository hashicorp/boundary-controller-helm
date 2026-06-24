# Changelog

All notable changes to the Boundary Controller Helm Chart will be documented in this file.

## [Unreleased]

## [0.1.0-beta] - 2026-06-24

Initial public beta release of the Boundary Controller Helm chart.

### Added

- Multi-replica controller `Deployment` with configurable rolling update strategy for Boundary control plane workloads on Kubernetes.
- Configurable Services for API (`9200`), cluster (`9201`), and ops (`9203`) traffic.
- Helm hook Jobs for database initialization, migration, and repair.
- Bootstrap admin workflow through `bootstrapAdmin`, including creation of the password auth method, admin user, account, and global admin role during install.
- Operator-supplied `controller.config` delivered through a ConfigMap and rendered with Helm `tpl`.
- TLS support via Kubernetes TLS Secret mount; liveness and readiness probe scheme auto-derived from `tls.disabled`.
- Render-time validation enforcing Secret key presence and TLS path alignment between `tls.mountPath` and listener config.
- Secret-based injection for sensitive values such as database connection details and license data.
- Production-oriented Kubernetes settings including hardened security contexts, PodDisruptionBudget, resource controls, scheduling options, `imagePullSecrets`, and `extraEnv`.
- Unit tests (helm-unittest), KIND acceptance tests with API smoke test and version matrix, EKS, AKS, and GKE integration tests.

### Configuration Defaults

| Parameter | Default |
|---|---|
| Image | `hashicorp/boundary-enterprise:0.21.3-ent` |
| Replicas | `2` |
| API / Cluster / Ops service type | `LoadBalancer` / `ClusterIP` / `ClusterIP` |
| CPU request / limit | `250m` / `500m` |
| Memory request / limit | `512Mi` / `1Gi` |
| TLS | Enabled (`tls.disabled: false`) |
| Termination grace period | `15s` |
| Secret validation (`validateExisting`) | Disabled — safe for offline `helm template` use |
