# Changelog

All notable changes to the Boundary Controller Helm Chart will be documented in this file.

## [0.1.0-beta] - 2026-06-24

Initial public beta release of the Boundary Controller Helm chart.

### Added

- Multi-replica controller `Deployment` with configurable rolling update strategy
- Services for API (9200, LoadBalancer), Cluster (9201, ClusterIP), and Ops (9203, ClusterIP); all types configurable
- Database init, migrate, and repair jobs as Helm hooks (`database.init.enabled`, `database.migrate.enabled`, `database.repair.version`)
- Bootstrap admin job (`bootstrapAdminAuthMethod`) — creates password auth method, user, account, and global admin role on install
- HCL config delivered via ConfigMap; evaluated through Helm `tpl`; checksum annotation triggers rolling restarts on change
- TLS support via Kubernetes Secret mount (`tls.disabled`, `tls.secretName`, `tls.mountPath`); probe scheme auto-derived from `tls.disabled`
- Secret-based env var injection for database URL (`env://BOUNDARY_PG_URL`), license (`env://BOUNDARY_LICENSE`), and AEAD KMS keys
- Render-time validation: Secret key presence, TLS path alignment
- Security-hardened pod and container security contexts (non-root UID/GID, read-only root filesystem, all capabilities dropped)
- PodDisruptionBudget, `extraEnv`, scheduling controls (`nodeSelector`, `tolerations`, `affinity`), and `imagePullSecrets`
- Unit tests (helm-unittest), KIND acceptance tests with API smoke test and version matrix, EKS and AKS integration tests
- Makefile targets for lint, unit, acceptance, and cloud integration workflows; Trivy and Kubescape scanning

### Configuration Defaults

| Parameter | Default |
|---|---|
| Image | `hashicorp/boundary-enterprise:0.21.3-ent` |
| Replicas | `2` |
| CPU request / limit | `250m` / `500m` |
| Memory request / limit | `512Mi` / `1Gi` |
| TLS | Disabled (`tls.disabled: true`) |
| Termination grace period | `15s` |