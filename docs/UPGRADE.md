# Boundary Controller Helm Chart - Upgrade Guide

This document provides guidance for upgrading the Boundary Controller Helm chart between versions.

## General Upgrade Process

1. **Review the CHANGELOG** - Check for breaking changes in the version you're upgrading to
2. **Backup your database** - Always take a PostgreSQL backup before upgrading
3. **Test in non-production** - Validate the upgrade in a test environment first
4. **Follow the upgrade steps** - See specific version upgrade instructions below

## Breaking Changes by Version

### Version x.x.x (Initial Release)

This is the initial release. No upgrade path from previous versions.

**Important Configuration Changes:**
- KMS configuration is now commented out by default and requires explicit configuration
- Users must uncomment and customize KMS settings for their environment

## Standard Upgrade Procedure

### Step 1: Update Your Values File

Review your `values.yaml` file and compare it with the new chart's default values:

```bash
helm show values hashicorp/boundary-controller > new-values.yaml
diff my-values.yaml new-values.yaml
```

### Step 2: Upgrade Without Database Migration

For minor updates that don't require database schema changes:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml
```

### Step 3: Upgrade With Database Migration

For major version upgrades that require database schema changes:

**Step 3a:** Scale controllers to zero:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml \
  --set controller.replicas=0
```

**Step 3b:** Take a database backup:

```bash
# Example for PostgreSQL
pg_dump -h <db-host> -U <db-user> boundary > boundary-backup-$(date +%Y%m%d).sql
```

**Step 3c:** Run migration and restore replicas:

```bash
helm upgrade boundary-controller hashicorp/boundary-controller \
  --namespace boundary \
  -f my-values.yaml \
  --set database.migrate.enabled=true
```

### Step 4: Verify the Upgrade

Check that all pods are running:

```bash
kubectl get pods -n boundary -l app.kubernetes.io/name=boundary-controller
```

Check controller logs:

```bash
kubectl logs -n boundary -l app.kubernetes.io/name=boundary-controller --tail=50
```

Test API connectivity:

```bash
boundary scopes list -addr <your-boundary-api-url>
```

## Rollback Procedure

If the upgrade fails, you can rollback to the previous version:

```bash
helm rollback boundary-controller -n boundary
```

If database migration was performed, you may need to restore from backup:

```bash
# Example for PostgreSQL
psql -h <db-host> -U <db-user> boundary < boundary-backup-<date>.sql
```

## Common Upgrade Issues

### Issue: Controllers fail to start after upgrade

**Symptoms:** Pods are in CrashLoopBackOff state

**Solutions:**
1. Check controller logs: `kubectl logs -n boundary <pod-name>`
2. Verify database connectivity
3. Ensure KMS configuration is correct
4. Check that all required secrets exist

### Issue: Database migration fails

**Symptoms:** Migration job fails or times out

**Solutions:**
1. Check migration job logs: `kubectl logs -n boundary <migration-job-pod>`
2. Verify database permissions
3. Ensure database is accessible from the cluster
4. Check for database locks or long-running transactions

### Issue: Bootstrap admin job fails after upgrade

**Symptoms:** Bootstrap job fails with authentication errors

**Solutions:**
1. Check if admin user already exists
2. Verify admin credentials in the secret
3. Ensure API service is reachable
4. Check bootstrap job logs for specific errors

## Version-Specific Upgrade Notes

### Upgrading to x.x.x (Future)

*This section will be populated when next version is released*

## Getting Help

If you encounter issues during upgrade:

1. Check the [FAQ](FAQ.md) for common issues
2. Review the [CHANGELOG](../CHANGELOG.md) for known issues
3. Check controller and job logs for error messages
4. Consult the [Boundary documentation](https://developer.hashicorp.com/boundary/docs)

## Best Practices

1. **Always backup before upgrading** - Database backups are critical
2. **Test in non-production first** - Validate upgrades in a test environment
3. **Review breaking changes** - Read the CHANGELOG before upgrading
4. **Monitor after upgrade** - Watch logs and metrics after upgrading
5. **Have a rollback plan** - Know how to rollback if needed
6. **Upgrade during maintenance windows** - Plan for potential downtime
7. **Keep Helm chart and Boundary versions aligned** - Use compatible versions