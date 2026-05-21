#!/bin/bash
# Copyright IBM Corp. 2026

# Controller API Test

set -euo pipefail

pass() { echo "   ✅ $1"; }
fail() { echo "❌ FAILED: $1"; exit 1; }
info() { echo "   $1"; }
warn() { echo "⚠️  WARN: $1"; }

PF_OPS_PID=""
PF_API_PID=""
_cleanup() {
    [ -n "${PF_OPS_PID}" ] && kill "${PF_OPS_PID}" 2>/dev/null || true
    [ -n "${PF_API_PID}" ] && kill "${PF_API_PID}" 2>/dev/null || true
}
trap _cleanup EXIT

CONTEXT="kind-acceptance"
NAMESPACE="boundary"
DEPLOY="boundary-controller"
TIMEOUT="${TIMEOUT:-300}"

echo "Controller API Test Suite"
echo ""

# Test 1: Controller running in KIND cluster
echo "Validating Controller Running in KIND Cluster..."
info "Checking KIND cluster accessibility..."
kubectl cluster-info --context "${CONTEXT}" >/dev/null 2>&1 \
    || fail "KIND cluster '${CONTEXT}' is not accessible. Run: make acceptance-setup"
pass "KIND cluster accessible"
echo ""

info "Checking controller deployment..."
kubectl get deployment "${DEPLOY}" -n "${NAMESPACE}" --context "${CONTEXT}" >/dev/null 2>&1 \
    || fail "Deployment '${DEPLOY}' not found in namespace '${NAMESPACE}'. Run: make acceptance-helm"
pass "Controller deployment '${DEPLOY}' exists"
echo ""

info "Waiting for deployment to be available (timeout: ${TIMEOUT}s)..."
kubectl wait --for=condition=available \
    --timeout="${TIMEOUT}s" \
    deployment/"${DEPLOY}" \
    -n "${NAMESPACE}" \
    --context "${CONTEXT}" >/dev/null 2>&1 \
    || fail "Controller deployment did not become available within ${TIMEOUT}s"
pass "Controller deployment is available"
echo ""

POD=$(kubectl get pods \
    -n "${NAMESPACE}" \
    --context "${CONTEXT}" \
    -l "app.kubernetes.io/name=boundary-controller,app.kubernetes.io/component=controller" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

[ -n "${POD}" ] || fail "No running controller pod found"
pass "Controller pod running: ${POD}"
echo ""

# Test 2: Validate Controller Ops Health Endpoint
echo "Validating Controller Ops Health Endpoint..."
kubectl port-forward \
    -n "${NAMESPACE}" \
    --context "${CONTEXT}" \
    "pod/${POD}" 9203:9203 >/dev/null 2>&1 &
PF_OPS_PID=$!

# Poll for port availability instead of fixed sleep
OPS_STATUS=""
for i in {1..30}; do
    if curl -sf --max-time 1 http://localhost:9203/health >/dev/null 2>&1; then
        OPS_STATUS="ok"
        break
    fi
    sleep 0.5
done
kill "${PF_OPS_PID}" 2>/dev/null || true
wait "${PF_OPS_PID}" 2>/dev/null || true
PF_OPS_PID=""

[ "${OPS_STATUS}" = "ok" ] || fail "Ops health endpoint /health on port 9203 did not return 200"
pass "Controller ops health endpoint is healthy"
echo ""

# Test 3: Validate Controller API Endpoint Reachability
echo "Validating Controller API Endpoint..."
kubectl port-forward \
    -n "${NAMESPACE}" \
    --context "${CONTEXT}" \
    "pod/${POD}" 9200:9200 >/dev/null 2>&1 &
PF_API_PID=$!

API_HTTP_CODE="000"
for i in {1..30}; do
    API_HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 \
        http://localhost:9200/v1/scopes/global 2>/dev/null || echo "000")
    if [ "${API_HTTP_CODE}" = "200" ] || [ "${API_HTTP_CODE}" = "401" ]; then
        break
    fi
    sleep 0.5
done

if [ "${API_HTTP_CODE}" = "200" ] || [ "${API_HTTP_CODE}" = "401" ]; then
    pass "Controller API is reachable (HTTP ${API_HTTP_CODE})"
else
    fail "Controller API did not respond as expected (HTTP ${API_HTTP_CODE})"
fi
echo ""

# Test 4: Validate Bootstrap Admin Authentication
echo "Validating Bootstrap Admin Authentication..."
command -v boundary >/dev/null 2>&1 \
    || fail "'boundary' CLI is not installed. Install from https://developer.hashicorp.com/boundary/downloads"
pass "'boundary' CLI found"
for var in BOOTSTRAP_ADMIN_USERNAME BOOTSTRAP_ADMIN_PASSWORD; do
    [ -n "${!var:-}" ] || fail "'${var}' is not set. Add it to your .env file."
done
pass "Bootstrap admin credentials are set"
info "Bootstrap admin username: ${BOOTSTRAP_ADMIN_USERNAME}"
echo ""

# Discover the password auth method ID via the API (no auth required for this call)
info "Discovering password auth method ID..."
AUTH_METHODS_JSON=$(curl -sf --max-time 10 \
    "http://localhost:9200/v1/auth-methods?scope_id=global" 2>/dev/null) \
    || fail "Failed to list auth methods from controller API"

AUTH_METHOD_ID=$(printf '%s\n' "${AUTH_METHODS_JSON}" | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in (data.get('items') or []):
    if item.get('type') == 'password':
        print(item['id'])
        break
" 2>/dev/null || true)

[ -n "${AUTH_METHOD_ID}" ] || fail "No password auth method found. Bootstrap admin job may not have completed."
pass "Password auth method found: ${AUTH_METHOD_ID}"
echo ""

info "Authenticating with bootstrap admin credentials..."
AUTH_OUT=$(boundary authenticate password \
    -addr "http://localhost:9200" \
    -auth-method-id "${AUTH_METHOD_ID}" \
    -login-name "${BOOTSTRAP_ADMIN_USERNAME}" \
    -password env://BOOTSTRAP_ADMIN_PASSWORD \
    -keyring-type=none 2>&1) || fail "Bootstrap admin authentication failed:${AUTH_OUT:+$'\n'}${AUTH_OUT}"

BOUNDARY_TOKEN=$(printf '%s\n' "${AUTH_OUT}" \
    | awk '/The token is:/ { getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }')
[ -n "${BOUNDARY_TOKEN}" ] || fail "Failed to extract auth token from authentication output"
export BOUNDARY_TOKEN
pass "Authenticated as bootstrap admin"
echo ""

# Test 5: API Validation
echo "Validating API Operations..."

info "Listing auth methods in global scope..."
AM_OUT=$(boundary auth-methods list \
    -scope-id global \
    -addr "http://localhost:9200" \
    -token env://BOUNDARY_TOKEN \
    -format json 2>&1)

AM_COUNT=$(printf '%s\n' "${AM_OUT}" | grep -c '"id"[[:space:]]*:[[:space:]]*"am' || echo "0")

[ "${AM_COUNT}" -gt 0 ] || fail "No auth methods found. Bootstrap job may not have completed."
pass "Auth methods confirmed: ${AM_COUNT} method(s) found"
echo ""

# Now kill the API port-forward since we're done with all API tests
if [ -n "${PF_API_PID}" ] && ps -p "${PF_API_PID}" > /dev/null 2>&1; then
    kill "${PF_API_PID}" 2>/dev/null || true
    wait "${PF_API_PID}" 2>/dev/null || true
    PF_API_PID=""
fi

echo "Controller API Test Summary"
echo "  Deployment:     ${DEPLOY} — Available"
echo "  Ops health:     http://localhost:9203/health — OK"
echo "  API reachable:  http://localhost:9200 — OK (HTTP ${API_HTTP_CODE})"
echo "  Auth method:    ${AUTH_METHOD_ID}"
echo "  Bootstrap auth: ${BOOTSTRAP_ADMIN_USERNAME} — OK"
echo "  Auth methods:   ${AM_COUNT} found"
echo ""
pass "Controller API test passed!"
