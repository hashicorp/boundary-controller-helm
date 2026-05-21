# Changelog

All notable changes to the Boundary Controller Helm Chart will be documented in this file.

## [Unreleased]

## [x.x.x] - YYYY-MM-DD

### Added
- Initial Helm chart for HashiCorp Boundary Controller
- Multi-replica controller deployment with configurable rolling update strategy (`maxUnavailable`, `maxSurge`)
- Three dedicated Kubernetes Services for API (port 9200), Cluster (port 9201), and Ops (port 9203) listeners
- Separate LoadBalancer services for API and Cluster listeners; ClusterIP service for Ops listener
- Per-service annotation support for cloud-provider-specific load balancer configuration (AWS NLB, GCP L4, Azure)
- Database initialization job (`boundary database init`) run as a Helm post-install hook
- Database migration job (`boundary database migrate`) run as a Helm pre-upgrade hook, controlled by `controller.database.migrate.enabled`
- Database repair job (`boundary database repair`) for targeted migration version repair, controlled by `controller.database.repair.version`
- Bootstrap admin job creating a password auth method, user, account, and global admin role as a Helm post-install hook
  - Configurable `runOnUpgrade` flag to re-run on `helm upgrade`
  - Configurable wait timeout polling controller API readiness before proceeding
  - Configurable auth method name, user/account/role resource display names
- ConfigMap delivering the Boundary HCL configuration, with pod checksum annotations to trigger rolling restarts on config changes
- TLS support for API and Ops listeners via Kubernetes Secret volume mount (`tls.disabled`, `tls.secretName`, `tls.mountPath`)
- Optional AEAD KMS key injection via Kubernetes Secret environment variables (`BOUNDARY_KMS_ROOT`, `BOUNDARY_KMS_WORKER_AUTH`, `BOUNDARY_KMS_RECOVERY`)
- Optional separate PostgreSQL migration URL (`BOUNDARY_PG_MIGRATION_URL`) injected from Kubernetes Secret
- AWS KMS configuration example in default `controller.config` (root, recovery, worker-auth keys)
- Configurable API rate limiting in default `controller.config` (total, per-IP, per-auth-token limits)
- Configurable event auditing in default `controller.config` (audit, observations, sysevents, telemetry, CloudEvents JSON sink)
- Graceful shutdown support via configurable `terminationGracePeriodSeconds` (default 15 s, exceeds `graceful_shutdown_wait_duration`)
- Liveness and readiness probes against the Ops `/health` endpoint with configurable scheme, delays, periods, and thresholds
- Security-hardened pod security context: non-root user/group (UID 100 / GID 1000), `fsGroup`
- Security-hardened container security context: `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop all capabilities, `seccompProfile: RuntimeDefault`
- Read-only root filesystem with dedicated `emptyDir` volumes for `/tmp` and `/boundary`
- ServiceAccount with optional IRSA annotation support for AWS KMS access
- PodDisruptionBudget for high availability with configurable `minAvailable` / `maxUnavailable`
- `nameOverride` / `fullnameOverride` and optional `namespace` override for resource naming
- `imagePullSecrets` support
- `nodeSelector`, `tolerations`, and `affinity` scheduling controls
- `podAnnotations` pass-through
- Helm validation template (`validate.yaml`) enforcing:
  - Kubernetes Secret existence and required key presence when `controller.secretRefs.validateExisting: true`
  - Detection of unsupported `env://BOUNDARY_KMS_*` usage inside AEAD KMS blocks
  - TLS cert/key path alignment between `tls.mountPath` and `controller.config` listener stanzas
- KIND cluster acceptance tests including controller API smoke test
- Makefile with `lint`, `unit-test`, and `acceptance` workflow targets
- Trivy security scanning

### Configuration Defaults
- Default image: `hashicorp/boundary-enterprise:0.21-ent`
- Default replicas: `2`
- Default API and Cluster service type: `LoadBalancer`; Ops service type: `ClusterIP`
- Default resources: 250 m CPU / 512 Mi memory (requests); 500 m CPU / 1 Gi memory (limits) for the controller container
- Default job resources: 100 m CPU / 128 Mi memory (requests); 500 m CPU / 512 Mi memory (limits)
- Secret validation disabled by default (`validateExisting: false`) for offline `helm template` compatibility

### Documentation
- Comprehensive README with installation and configuration guide
- Database setup and migration procedures
- Operations guide for upgrades and troubleshooting
- Testing documentation (docs/TESTING.md, docs/FAQ.md)

### Known Limitations
- Requires external PostgreSQL database
- Manual database connection configuration required
- Enterprise license required (`hashicorp/boundary-enterprise` image)