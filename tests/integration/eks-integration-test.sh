#!/bin/bash
# Copyright IBM Corp. 2026
#
# eks-integartion-test.sh
# ---------------------------------------------------------------------------
# Validates that the boundary-controller Helm chart is correctly installed
# and active on an EKS cluster provisioned by the Terraform in this directory.
#
# Usage:
#   ./eks-integartion-test.sh [OPTIONS]
#
# Options:
#   --cluster-name  NAME        EKS cluster name  (or set EKS_CLUSTER_NAME)
#   --region        REGION      AWS region         (or set AWS_REGION, default: us-east-1)
#   --namespace     NAMESPACE   K8s namespace      (or set BOUNDARY_NAMESPACE, default: boundary)
#   --release       RELEASE     Helm release name  (or set HELM_RELEASE, default: boundary-controller)
#   --timeout       SECONDS     kubectl wait timeout (default: 300)
#   --skip-api                  Skip API / auth endpoint tests
#   --skip-kms                  Skip AWS KMS connectivity check
#
# Prerequisites:
#   kubectl, helm, aws CLI, curl, python3
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass()    { echo -e "   ${GREEN}✅${NC}  $1"; }
fail()    { echo -e "${RED}❌  FAIL${NC}  $1"; FAILED=$((FAILED + 1)); FAILED_TESTS+=("$1"); }
info()    { echo -e "   ${CYAN}ℹ${NC}  $1"; }
warn()    { echo -e "   ${YELLOW}⚠️   WARN${NC}  $1"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

FAILED=0
FAILED_TESTS=()
PF_OPS_PID=""
PF_API_PID=""

_cleanup() {
    [ -n "${PF_OPS_PID}" ] && kill "${PF_OPS_PID}" 2>/dev/null || true
    [ -n "${PF_API_PID}" ] && kill "${PF_API_PID}" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
BOUNDARY_NAMESPACE="${BOUNDARY_NAMESPACE:-boundary}"
HELM_RELEASE="${HELM_RELEASE:-boundary-controller}"
TIMEOUT="${TIMEOUT:-300}"
SKIP_API="${SKIP_API:-false}"
SKIP_KMS="${SKIP_KMS:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) EKS_CLUSTER_NAME="$2"; shift 2 ;;
        --region)       AWS_REGION="$2";       shift 2 ;;
        --namespace)    BOUNDARY_NAMESPACE="$2"; shift 2 ;;
        --release)      HELM_RELEASE="$2";     shift 2 ;;
        --timeout)      TIMEOUT="$2";          shift 2 ;;
        --skip-api)     SKIP_API="true";       shift ;;
        --skip-kms)     SKIP_KMS="true";       shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "${EKS_CLUSTER_NAME}" ]; then
    echo "ERROR: --cluster-name (or EKS_CLUSTER_NAME env var) is required."
    exit 1
fi

echo -e "\n${BOLD}Boundary Controller — EKS Installation Validation${NC}"
echo    "  Cluster  : ${EKS_CLUSTER_NAME}"
echo    "  Region   : ${AWS_REGION}"
echo    "  Namespace: ${BOUNDARY_NAMESPACE}"
echo    "  Release  : ${HELM_RELEASE}"
echo    "  Timeout  : ${TIMEOUT}s"

# Section 1: Prerequisites
section "1. Prerequisites..."

for cmd in kubectl helm aws curl python3; do
    if command -v "${cmd}" >/dev/null 2>&1; then
        pass "'${cmd}' is available"
    else
        fail "'${cmd}' is not installed or not on PATH"
    fi
done

# Section 2: EKS cluster connectivity
section "2. EKS Cluster Connectivity..."

info "Updating kubeconfig for cluster '${EKS_CLUSTER_NAME}'..."
if aws eks update-kubeconfig \
        --region "${AWS_REGION}" \
        --name "${EKS_CLUSTER_NAME}" \
        --alias "eks-${EKS_CLUSTER_NAME}" >/dev/null 2>&1; then
    pass "kubeconfig updated"
else
    fail "Failed to update kubeconfig — check AWS credentials and cluster name"
fi

KUBE_CONTEXT="eks-${EKS_CLUSTER_NAME}"

info "Checking cluster API server reachability..."
if kubectl cluster-info --context "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    pass "Cluster API server is reachable"
else
    fail "Cluster API server is not reachable"
fi

# Section 3: Namespace
section "3. Kubernetes Namespace..."

if kubectl get namespace "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    pass "Namespace '${BOUNDARY_NAMESPACE}' exists"
else
    fail "Namespace '${BOUNDARY_NAMESPACE}' not found"
fi

# Section 4: Helm release status
section "4. Helm Release..."

HELM_STATUS=$(helm status "${HELM_RELEASE}" \
    --namespace "${BOUNDARY_NAMESPACE}" \
    --kube-context "${KUBE_CONTEXT}" \
    --output json 2>/dev/null || echo "{}")

HELM_DEPLOY_STATUS=$(echo "${HELM_STATUS}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('info',{}).get('status','unknown'))" 2>/dev/null || echo "unknown")

if [ "${HELM_DEPLOY_STATUS}" = "deployed" ]; then
    pass "Helm release '${HELM_RELEASE}' status: deployed"
else
    fail "Helm release '${HELM_RELEASE}' status: ${HELM_DEPLOY_STATUS} (expected: deployed)"
fi

HELM_CHART=$(echo "${HELM_STATUS}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('chart','unknown'))" 2>/dev/null || echo "unknown")
info "Chart: ${HELM_CHART}"

HELM_REVISION=$(echo "${HELM_STATUS}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo "?")
info "Revision: ${HELM_REVISION}"

# Section 5: Kubernetes Resources
section "5. Kubernetes Resources..."

# Deployment
if kubectl get deployment "${HELM_RELEASE}" \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    pass "Deployment '${HELM_RELEASE}' exists"
else
    fail "Deployment '${HELM_RELEASE}' not found"
fi

# ConfigMap
if kubectl get configmap \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" \
        -l "app.kubernetes.io/name=boundary-controller" >/dev/null 2>&1; then
    pass "ConfigMap exists"
else
    warn "No ConfigMap with label app.kubernetes.io/name=boundary-controller found"
fi

# Secret
if kubectl get secret boundary-controller-secrets \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    pass "Secret 'boundary-controller-secrets' exists"
else
    fail "Secret 'boundary-controller-secrets' not found"
fi

# ServiceAccount
SA_NAME=$(kubectl get serviceaccount \
    -n "${BOUNDARY_NAMESPACE}" \
    --context "${KUBE_CONTEXT}" \
    -l "app.kubernetes.io/name=boundary-controller" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${SA_NAME}" ]; then
    pass "ServiceAccount '${SA_NAME}' exists"
    # Check IRSA annotation
    IRSA_ARN=$(kubectl get serviceaccount "${SA_NAME}" \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" \
        -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
    if [ -n "${IRSA_ARN}" ]; then
        pass "IRSA annotation present: ${IRSA_ARN}"
    else
        warn "IRSA annotation 'eks.amazonaws.com/role-arn' not set on ServiceAccount"
    fi
else
    fail "No ServiceAccount with label app.kubernetes.io/name=boundary-controller found"
fi

# PodDisruptionBudget
if kubectl get pdb \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" \
        -l "app.kubernetes.io/name=boundary-controller" >/dev/null 2>&1; then
    pass "PodDisruptionBudget exists"
else
    warn "No PodDisruptionBudget found (may be disabled in values)"
fi

# Services
for svc_purpose in api cluster; do
    # Primary lookup by chart naming convention: <release>-api / <release>-cluster.
    SVC=$(kubectl get svc "${HELM_RELEASE}-${svc_purpose}" \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" \
        -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

    # Backward-compatibility fallback for older label conventions.
    if [ -z "${SVC}" ]; then
        SVC=$(kubectl get svc \
            -n "${BOUNDARY_NAMESPACE}" \
            --context "${KUBE_CONTEXT}" \
            -l "app.kubernetes.io/name=boundary-controller,app.kubernetes.io/component=${svc_purpose}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    if [ -n "${SVC}" ]; then
        pass "Service (${svc_purpose}) '${SVC}' exists"
    else
        fail "Service for purpose '${svc_purpose}' not found"
    fi
done

# Section 6: Deployment readiness
section "6. Deployment Readiness..."

info "Waiting for deployment to become available (timeout: ${TIMEOUT}s)..."
if kubectl wait \
        --for=condition=available \
        --timeout="${TIMEOUT}s" \
        deployment/"${HELM_RELEASE}" \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    pass "Deployment is available"
else
    fail "Deployment did not become available within ${TIMEOUT}s"
fi

# Replica counts
DESIRED=$(kubectl get deployment "${HELM_RELEASE}" \
    -n "${BOUNDARY_NAMESPACE}" \
    --context "${KUBE_CONTEXT}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
READY=$(kubectl get deployment "${HELM_RELEASE}" \
    -n "${BOUNDARY_NAMESPACE}" \
    --context "${KUBE_CONTEXT}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

info "Replicas: ${READY}/${DESIRED} ready"
if [ "${READY}" = "${DESIRED}" ] && [ "${DESIRED}" -gt 0 ]; then
    pass "All ${DESIRED} replica(s) are ready"
else
    fail "Only ${READY}/${DESIRED} replica(s) ready"
fi

# Running pod
POD=$(kubectl get pods \
    -n "${BOUNDARY_NAMESPACE}" \
    --context "${KUBE_CONTEXT}" \
    -l "app.kubernetes.io/name=boundary-controller,app.kubernetes.io/component=controller" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${POD}" ]; then
    pass "Running pod found: ${POD}"
else
    fail "No running controller pod found"
fi


# Section 7: AWS KMS connectivity
section "7. AWS KMS Connectivity..."

if [ "${SKIP_KMS}" = "true" ]; then
    warn "KMS check skipped (--skip-kms)"
else
    for alias in alias/boundary-root alias/boundary-recovery alias/boundary-worker-auth; do
        KEY_ID=$(aws kms describe-key \
            --key-id "${alias}" \
            --region "${AWS_REGION}" \
            --query 'KeyMetadata.KeyId' \
            --output text 2>/dev/null || echo "")
        if [ -n "${KEY_ID}" ]; then
            KEY_STATE=$(aws kms describe-key \
                --key-id "${alias}" \
                --region "${AWS_REGION}" \
                --query 'KeyMetadata.KeyState' \
                --output text 2>/dev/null || echo "Unknown")
            if [ "${KEY_STATE}" = "Enabled" ]; then
                pass "KMS key '${alias}' is Enabled (${KEY_ID})"
            else
                fail "KMS key '${alias}' state: ${KEY_STATE} (expected: Enabled)"
            fi
        else
            fail "KMS key '${alias}' not found in region ${AWS_REGION}"
        fi
    done
fi

# Section 8: Controller health (port-forward to ops endpoint)
section "8. Controller Ops Health Endpoint..."

if [ "${SKIP_API}" = "true" ]; then
    warn "Ops health check skipped (--skip-api)"
elif [ -z "${POD}" ]; then
    warn "Skipping ops health check — no running pod available"
else
    info "Port-forwarding pod/${POD} :9203 -> localhost:19203..."
    kubectl port-forward \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" \
        "pod/${POD}" 19203:9203 >/dev/null 2>&1 &
    PF_OPS_PID=$!

    OPS_STATUS=""
    for i in $(seq 1 30); do
        if curl -sf --max-time 1 http://localhost:19203/health >/dev/null 2>&1; then
            OPS_STATUS="ok"
            break
        fi
        sleep 0.5
    done

    kill "${PF_OPS_PID}" 2>/dev/null || true
    wait "${PF_OPS_PID}" 2>/dev/null || true
    PF_OPS_PID=""

    if [ "${OPS_STATUS}" = "ok" ]; then
        pass "Ops health endpoint /health returned 200"
    else
        fail "Ops health endpoint /health did not return 200 within 15s"
    fi
fi

# Section 9: Controller API endpoint reachability
section "9. Controller API Endpoint..."

if [ "${SKIP_API}" = "true" ]; then
    warn "API endpoint check skipped (--skip-api)"
elif [ -z "${POD}" ]; then
    warn "Skipping API check — no running pod available"
else
    info "Port-forwarding pod/${POD} :9200 -> localhost:19200..."
    kubectl port-forward \
        -n "${BOUNDARY_NAMESPACE}" \
        --context "${KUBE_CONTEXT}" \
        "pod/${POD}" 19200:9200 >/dev/null 2>&1 &
    PF_API_PID=$!

    API_HTTP_CODE="000"
    for i in $(seq 1 30); do
        API_HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 \
            http://localhost:19200/v1/scopes/global 2>/dev/null || echo "000")
        if [ "${API_HTTP_CODE}" = "200" ] || [ "${API_HTTP_CODE}" = "401" ]; then
            break
        fi
        sleep 0.5
    done

    kill "${PF_API_PID}" 2>/dev/null || true
    wait "${PF_API_PID}" 2>/dev/null || true
    PF_API_PID=""

    if [ "${API_HTTP_CODE}" = "200" ] || [ "${API_HTTP_CODE}" = "401" ]; then
        pass "Controller API /v1/scopes/global responded with HTTP ${API_HTTP_CODE}"
    else
        fail "Controller API did not respond as expected (HTTP ${API_HTTP_CODE})"
    fi
fi


# Summary
echo ""
echo -e "${BOLD}────────────────────────────────────────${NC}"
if [ "${FAILED}" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✅  All checks passed.${NC}"
else
    echo -e "${RED}${BOLD}❌  ${FAILED} check(s) failed:${NC}"
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "     ${RED}•${NC} ${t}"
    done
    echo -e "${BOLD}────────────────────────────────────────${NC}"
    exit 1
fi
echo -e "${BOLD}────────────────────────────────────────${NC}"
