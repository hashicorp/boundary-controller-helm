# Changelog

All notable changes to the Boundary Controller Helm Chart will be documented in this file.

## [0.2.0-beta] - 2026-09-15

### Added

- OpenShift support via `openshift.enabled`: SCC-compatible security contexts, all services forced to `ClusterIP`, and `Route` objects for API, cluster, and ops listeners.
- Per-listener TLS flags `tls.api.disabled` / `tls.ops.disabled` replacing the single `tls.disabled`. Render-time validation enforces alignment with `tls_disable` in each listener block.
- Image auto-selection for OpenShift: uses Red Hat registry (`registry.connect.redhat.com/hashicorp/boundary-enterprise`) with `-ubi` tag when `openshift.enabled=true` and no explicit `image.repository` is set.

### Changed


- Updated the chart version to 0.2.0-beta and the default Boundary Enterprise version to 1.0.2-ent.
 - **Breaking:** `tls.disabled` removed — replace `--set tls.disabled=<bool>` with `--set tls.api.disabled=<bool> --set tls.ops.disabled=<bool>`.
- Default `controller.config` now uses `tpl`-rendered references (`env://BOUNDARY_PG_URL`, `env://BOUNDARY_LICENSE`, etc.) instead of hardcoded placeholders.
- `database.init.enabled` and `bootstrapAdmin.enabled` default to `true`.


---

## [0.1.1] - 2026-07-30

### Changed

- Default controller image updated to `hashicorp/boundary-enterprise:1.0.1-ent`.

---

## [0.1.1] - 2026-07-30

### Changed

- Default controller image updated to `hashicorp/boundary-enterprise:1.0.1-ent`.

---

## [0.1.0] - 2026-06-30

### Fixed

- Probe scheme auto-derivation now correctly reads `tls_disable` from the ops listener block in `controller.config` instead of the chart-level `tls.disabled` flag. The prior logic had the polarity inverted: absent `tls_disable` was treated as TLS off; it is now correctly treated as TLS on (matching Boundary's HCL default where `tls_disable` defaults to `false`).
- When the ops listener block has no `tls_disable` parameter, the probe scheme now resolves to `HTTPS` instead of `HTTP`.
- When no ops listener block is present in `controller.config`, the probe scheme defaults to `HTTP`.

### Added

- Render-time validation that `controller.config` uses the correct `env://` variable names for secret-backed fields when `secretRefs.secretName` is set (`env://BOUNDARY_PG_URL`, `env://BOUNDARY_PG_MIGRATION_URL`, `env://BOUNDARY_LICENSE`). Using a wrong variable name now fails at render time with an actionable error rather than silently producing a missing value at runtime.

### Changed

- Default controller image updated to `hashicorp/boundary-enterprise:1.0.0-ent`.

---

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
