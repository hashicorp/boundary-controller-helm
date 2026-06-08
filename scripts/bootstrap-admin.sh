#!/bin/sh
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

set -eu

export BOUNDARY_RECOVERY_CONFIG=/etc/boundary/controller.hcl

if [ -z "${BOUNDARY_ADMIN_USERNAME}" ] || [ -z "${BOUNDARY_ADMIN_PASSWORD}" ]; then
  echo "bootstrap admin username/password are required"
  exit 1
fi

if [ -z "${BOUNDARY_ADDR:-}" ]; then
  echo "BOUNDARY_ADDR is required"
  exit 1
fi

if [ -z "${WAIT_TIMEOUT:-}" ]; then
  echo "WAIT_TIMEOUT is required"
  exit 1
fi

echo "bootstrap admin username: ${BOUNDARY_ADMIN_USERNAME}"
echo "BOUNDARY_ADDR: ${BOUNDARY_ADDR}"
echo "BOUNDARY_RECOVERY_CONFIG: ${BOUNDARY_RECOVERY_CONFIG}"

START_TS=$(date +%s)
while true; do
  if boundary scopes list -scope-id global -addr "$BOUNDARY_ADDR" -recovery-config "$BOUNDARY_RECOVERY_CONFIG" -format json >/dev/null 2>&1; then
    break
  fi
  NOW_TS=$(date +%s)
  if [ $((NOW_TS - START_TS)) -ge "$WAIT_TIMEOUT" ]; then
    echo "controller API did not become reachable within ${WAIT_TIMEOUT}s"
    exit 1
  fi
  sleep 5
done

echo "Creating or fetching password auth method..."
AUTH_METHOD_OUTPUT=$(boundary auth-methods create password \
  -scope-id global \
  -name "$BOUNDARY_AUTH_METHOD_NAME" \
  -description "Bootstrap password auth method" \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" \
  -format json 2>&1 || true)

if echo "$AUTH_METHOD_OUTPUT" | grep -q "must be unique"; then
  echo "Auth method already exists, fetching..."
  AUTH_METHOD_ID=$(boundary auth-methods list -scope-id global -addr "$BOUNDARY_ADDR" -recovery-config "$BOUNDARY_RECOVERY_CONFIG" -format json | grep -B2 '"name":"'"$BOUNDARY_AUTH_METHOD_NAME"'"' | grep -o '"id":"ampw_[^"]*"' | head -1 | cut -d'"' -f4)
else
  AUTH_METHOD_ID=$(echo "$AUTH_METHOD_OUTPUT" | grep -o '"id":"ampw_[^"]*"' | head -1 | cut -d'"' -f4)
fi

if [ -z "$AUTH_METHOD_ID" ]; then
  echo "ERROR: Failed to resolve auth method ID"
  echo "$AUTH_METHOD_OUTPUT"
  exit 1
fi
echo "Auth method ID: $AUTH_METHOD_ID"

echo "Setting global primary auth method..."
boundary scopes update \
  -id global \
  -primary-auth-method-id "$AUTH_METHOD_ID" \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" >/dev/null 2>&1 || echo "Primary auth method may already be set"

echo "Creating or fetching user..."
USER_OUTPUT=$(boundary users create \
  -scope-id global \
  -name "$BOUNDARY_USER_RESOURCE_NAME" \
  -description "Bootstrap admin user" \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" \
  -format json 2>&1 || true)

if echo "$USER_OUTPUT" | grep -q "must be unique"; then
  echo "User already exists, fetching..."
  USER_ID=$(boundary users list -scope-id global -addr "$BOUNDARY_ADDR" -recovery-config "$BOUNDARY_RECOVERY_CONFIG" -format json | grep -B2 '"name":"'"$BOUNDARY_USER_RESOURCE_NAME"'"' | grep -o '"id":"u_[^"]*"' | head -1 | cut -d'"' -f4)
else
  USER_ID=$(echo "$USER_OUTPUT" | grep -o '"id":"u_[^"]*"' | head -1 | cut -d'"' -f4)
fi

if [ -z "$USER_ID" ]; then
  echo "ERROR: Failed to resolve user ID"
  echo "$USER_OUTPUT"
  exit 1
fi
echo "User ID: $USER_ID"

echo "Creating or fetching password account..."
ACCOUNT_OUTPUT=$(boundary accounts create password \
  -auth-method-id "$AUTH_METHOD_ID" \
  -name "$BOUNDARY_ACCOUNT_RESOURCE_NAME" \
  -description "Bootstrap admin account" \
  -login-name "$BOUNDARY_ADMIN_USERNAME" \
  -password env://BOUNDARY_ADMIN_PASSWORD \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" \
  -format json 2>&1 || true)

if echo "$ACCOUNT_OUTPUT" | grep -q "must be unique\|already exists"; then
  echo "Account already exists, fetching..."
  ACCOUNT_ID=$(boundary accounts list -auth-method-id "$AUTH_METHOD_ID" -addr "$BOUNDARY_ADDR" -recovery-config "$BOUNDARY_RECOVERY_CONFIG" -format json | grep -B2 '"login_name":"'"$BOUNDARY_ADMIN_USERNAME"'"' | grep -o '"id":"acctpw_[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$ACCOUNT_ID" ]; then
    boundary accounts update password \
      -id "$ACCOUNT_ID" \
      -name "$BOUNDARY_ACCOUNT_RESOURCE_NAME" \
      -description "Bootstrap admin account" \
      -login-name "$BOUNDARY_ADMIN_USERNAME" \
      -addr "$BOUNDARY_ADDR" \
      -recovery-config "$BOUNDARY_RECOVERY_CONFIG" >/dev/null
    boundary accounts set-password \
      -id "$ACCOUNT_ID" \
      -password env://BOUNDARY_ADMIN_PASSWORD \
      -addr "$BOUNDARY_ADDR" \
      -recovery-config "$BOUNDARY_RECOVERY_CONFIG" >/dev/null
  fi
else
  ACCOUNT_ID=$(echo "$ACCOUNT_OUTPUT" | grep -o '"id":"acctpw_[^"]*"' | head -1 | cut -d'"' -f4)
fi

if [ -z "$ACCOUNT_ID" ]; then
  echo "ERROR: Failed to resolve account ID"
  echo "$ACCOUNT_OUTPUT"
  exit 1
fi
echo "Account ID: $ACCOUNT_ID"

echo "Linking account to user..."
boundary users add-accounts \
  -id "$USER_ID" \
  -account "$ACCOUNT_ID" \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" 2>&1 || echo "Account may already be linked"

echo "Creating or fetching admin role..."
ROLE_OUTPUT=$(boundary roles create \
  -scope-id global \
  -name "$BOUNDARY_ROLE_NAME" \
  -description "Global admin role managed by Helm bootstrap job" \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" \
  -format json 2>&1 || true)

if echo "$ROLE_OUTPUT" | grep -q "must be unique"; then
  echo "Role already exists, fetching..."
  ROLE_ID=$(boundary roles list -scope-id global -addr "$BOUNDARY_ADDR" -recovery-config "$BOUNDARY_RECOVERY_CONFIG" -format json | grep -B2 '"name":"'"$BOUNDARY_ROLE_NAME"'"' | grep -o '"id":"r_[^"]*"' | head -1 | cut -d'"' -f4)
else
  ROLE_ID=$(echo "$ROLE_OUTPUT" | grep -o '"id":"r_[^"]*"' | head -1 | cut -d'"' -f4)
fi

if [ -z "$ROLE_ID" ]; then
  echo "ERROR: Failed to resolve role ID"
  echo "$ROLE_OUTPUT"
  exit 1
fi
echo "Role ID: $ROLE_ID"

echo "Adding grants to role..."
boundary roles add-grants \
  -id "$ROLE_ID" \
  -grant "ids=*;type=*;actions=*" \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" 2>&1 || echo "WARNING: add-grants returned non-zero; verify role grants are configured correctly"

echo "Adding principal to role..."
boundary roles add-principals \
  -id "$ROLE_ID" \
  -principal "$USER_ID" \
  -addr "$BOUNDARY_ADDR" \
  -recovery-config "$BOUNDARY_RECOVERY_CONFIG" 2>&1 || echo "WARNING: add-principals returned non-zero; verify user is linked to role"

echo "Bootstrap admin completed successfully"