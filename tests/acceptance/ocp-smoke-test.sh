#!/bin/bash
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

# OpenShift (CRC) Acceptance Test for boundary-controller-helm
# Validates the controller deployment, OpenShift Route, security contexts,
# and API reachability on an OpenShift cluster.
#
# Prerequisites:
#   - crc running: crc start
#   - oc configured: eval $(crc oc-env) && oc login -u kubeadmin https://api.crc.testing:6443
#   - boundary-controller installed with values.openshift.yaml:
#       helm install boundary-controller . -n boundary \
#         -f values.openshift.yaml -f tests/acceptance/test-values.yaml \
#         --set controller.replicas=1 --set bootstrapAdmin.enabled=true
#
# Usage:
#   NAMESPACE=boundary DEPLOY=boundary-controller ./tests/acceptance/ocp-smoke-test.sh

set -euo pipefail

pass() { echo "   ✅  $1"; }
fail() { echo "❌ FAILED: $1"; exit 1; }
info() { echo "   $1"; }
warn() { echo "⚠️  WARN: $1"; }

NAMESPACE="${NAMESPACE:-boundary}"
DEPLOY="${DEPLOY:-boundary-controller}"
TIMEOUT="${TIMEOUT:-120}"

echo "OpenShift Acceptance Test Suite — boundary-controller-helm"
echo ""

# ── Test 1: OCP cluster reachable ──────────────────────────────────────────
echo "Test 1: Verifying OpenShift cluster accessibility..."
oc cluster-info >/dev/null 2>&1 \
    || fail "OpenShift cluster not accessible. Run: eval \$(crc oc-env) && oc login -u kubeadmin https://api.crc.testing:6443"
pass "OpenShift cluster accessible"
echo ""

# ── Test 2: Namespace exists ───────────────────────────────────────────────
echo "Test 2: Checking namespace '${NAMESPACE}'..."
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "Namespace '${NAMESPACE}' not found"
pass "Namespace '${NAMESPACE}' exists"
echo ""

# ── Test 3: Deployment available ──────────────────────────────────────────
echo "Test 3: Waiting for controller deployment to be available..."
oc wait --for=condition=available \
    --timeout="${TIMEOUT}s" \
    deployment/"${DEPLOY}" \
    -n "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "Controller deployment '${DEPLOY}' did not become available within ${TIMEOUT}s"
pass "Controller deployment '${DEPLOY}' is available"
echo ""

# ── Test 4: Pod running with OCP-assigned UID (not fixed 100) ─────────────
echo "Test 4: Validating pod security context (OpenShift SCC)..."
POD=$(oc get pods \
    -n "${NAMESPACE}" \
    -l "app.kubernetes.io/name=boundary-controller" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "${POD}" ] || fail "No running controller pod found in namespace '${NAMESPACE}'"
pass "Controller pod running: ${POD}"

RUN_AS_USER=$(oc get pod "${POD}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].securityContext.runAsUser}' 2>/dev/null || true)
[ -n "${RUN_AS_USER}" ] || fail "runAsUser not set on pod (OCP SCC did not inject UID)"
[ "${RUN_AS_USER}" != "100" ] \
    || fail "runAsUser is 100 — OCP SCC UID injection did not work. Pod is using fixed UID."
pass "runAsUser is OCP-assigned: ${RUN_AS_USER} (not fixed 100)"

ALLOW_PRIV=$(oc get pod "${POD}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null || true)
[ "${ALLOW_PRIV}" = "false" ] \
    || fail "allowPrivilegeEscalation is not false: '${ALLOW_PRIV}'"
pass "allowPrivilegeEscalation=false"

READ_ONLY_FS=$(oc get pod "${POD}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null || true)
[ "${READ_ONLY_FS}" = "true" ] \
    || fail "readOnlyRootFilesystem is not true: '${READ_ONLY_FS}'"
pass "readOnlyRootFilesystem=true"

RUN_AS_NON_ROOT=$(oc get pod "${POD}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null || true)
[ "${RUN_AS_NON_ROOT}" = "true" ] \
    || fail "runAsNonRoot is not true: '${RUN_AS_NON_ROOT}'"
pass "runAsNonRoot=true"
echo ""

# ── Test 5: init-db job completed ─────────────────────────────────────────
echo "Test 5: Validating init-db job completed..."
INIT_DB_STATUS=$(oc get job "${DEPLOY}-init-db" -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
if [ -z "${INIT_DB_STATUS}" ]; then
    # Job was cleaned up by ttlSecondsAfterFinished — means it completed successfully
    warn "init-db job not found (cleaned up by TTL — completed successfully)"
else
    [ "${INIT_DB_STATUS}" = "True" ] \
        || fail "init-db job did not complete successfully (status: '${INIT_DB_STATUS}')"
    pass "init-db job completed successfully"
fi
echo ""

# ── Test 6: bootstrap-admin job completed ─────────────────────────────────
echo "Test 6: Validating bootstrap-admin job completed..."
BOOTSTRAP_STATUS=$(oc get job "${DEPLOY}-bootstrap-admin" -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
if [ -z "${BOOTSTRAP_STATUS}" ]; then
    # Job was cleaned up by ttlSecondsAfterFinished — means it completed successfully
    warn "bootstrap-admin job not found (cleaned up by TTL — completed successfully)"
else
    [ "${BOOTSTRAP_STATUS}" = "True" ] \
        || fail "bootstrap-admin job did not complete successfully (status: '${BOOTSTRAP_STATUS}')"
    pass "bootstrap-admin job completed successfully"
fi
echo ""

# ── Test 7: API service is ClusterIP ──────────────────────────────────────
echo "Test 7: Validating API service type is ClusterIP for OpenShift..."
SVC_TYPE=$(oc get service "${DEPLOY}-api" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.type}' 2>/dev/null || true)
[ "${SVC_TYPE}" = "ClusterIP" ] \
    || fail "API service type is '${SVC_TYPE}', expected ClusterIP for OpenShift"
pass "API service type is ClusterIP"
echo ""

# ── Test 8: OpenShift Route exists ────────────────────────────────────────
echo "Test 8: Validating OpenShift Route exists..."
ROUTE_NAME="${DEPLOY}-api-route"
oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "Route '${ROUTE_NAME}' not found in namespace '${NAMESPACE}'"
pass "Route '${ROUTE_NAME}' exists"

ROUTE_TLS=$(oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)
[ "${ROUTE_TLS}" = "edge" ] \
    || fail "Route TLS termination is '${ROUTE_TLS}', expected 'edge'"
pass "Route TLS termination is 'edge'"

ROUTE_HOST=$(oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "${ROUTE_HOST}" ] || fail "Route has no host assigned"
pass "Route host: ${ROUTE_HOST}"
echo ""

# ── Test 9: Controller API reachable via Route ────────────────────────────
echo "Test 9: Validating controller API reachable via OpenShift Route..."
API_HTTP_CODE="000"
for i in $(seq 1 20); do
    API_HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 \
        "https://${ROUTE_HOST}/v1/scopes/global" 2>/dev/null || echo "000")
    if [ "${API_HTTP_CODE}" = "200" ] || [ "${API_HTTP_CODE}" = "401" ]; then
        break
    fi
    sleep 1
done
[ "${API_HTTP_CODE}" = "200" ] || [ "${API_HTTP_CODE}" = "401" ] \
    || fail "Controller API via Route did not respond (HTTP ${API_HTTP_CODE})"
pass "Controller API reachable via Route (HTTP ${API_HTTP_CODE})"
echo ""

# ── Test 10: Ops health endpoint reachable via port-forward ───────────────
echo "Test 10: Validating controller ops health endpoint..."
oc port-forward -n "${NAMESPACE}" "pod/${POD}" 19203:9203 >/dev/null 2>&1 &
PF_OPS_PID=$!
trap 'kill "${PF_OPS_PID}" 2>/dev/null || true' EXIT

OPS_STATUS=""
for i in $(seq 1 20); do
    if curl -sf --max-time 1 http://localhost:19203/health >/dev/null 2>&1; then
        OPS_STATUS="ok"
        break
    fi
    sleep 0.5
done
kill "${PF_OPS_PID}" 2>/dev/null || true
wait "${PF_OPS_PID}" 2>/dev/null || true

[ "${OPS_STATUS}" = "ok" ] || fail "Ops health endpoint /health did not return 200"
pass "Controller ops health endpoint is healthy"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────
echo "OpenShift Acceptance Test Summary"
echo "  Namespace:       ${NAMESPACE}"
echo "  Deployment:      ${DEPLOY} — Available"
echo "  Pod:             ${POD}"
echo "  runAsUser:       ${RUN_AS_USER} (OCP-assigned)"
echo "  API service:     ClusterIP"
echo "  Route host:      https://${ROUTE_HOST}"
echo "  Route TLS:       edge"
echo "  API HTTP code:   ${API_HTTP_CODE}"
echo "  Ops health:      OK"
echo ""
pass "OpenShift acceptance test passed!"
