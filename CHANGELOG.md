# Changelog

All notable changes to the Boundary Controller Helm Chart will be documented in this file.

## [0.1.0-beta] - 2026-06-18

Initial beta release of the official HashiCorp Boundary Controller Helm Chart.

### Added
- Boundary Controller Deployment targeting Boundary Enterprise `0.21-ent`
- Kubernetes Services for API, Cluster, and Ops listeners
- Database initialization, migration, and repair Helm hook jobs
- Bootstrap admin job for initial Boundary setup on install
- TLS support for API and Ops listeners
- Optional AEAD and AWS KMS configuration support
- Security-hardened pod and container security contexts
- PodDisruptionBudget for high availability