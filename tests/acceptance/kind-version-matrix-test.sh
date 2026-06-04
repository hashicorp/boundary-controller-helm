#!/bin/bash
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

# Kubernetes Version Matrix Test
# Tests controller-api-test.sh across configured kindest/node Kubernetes versions.
# Available tags reference: https://hub.docker.com/r/kindest/node

set -euo pipefail

# Helper functions for output formatting and error handling
pass()   { echo "   ✅ $1" >&2; }
fail()   { echo "❌ FAILED: $1" >&2; exit 1; }
info()   { echo "   $1" >&2; }
warn()   { echo "⚠️  WARN: $1" >&2; }
header() {
    echo "" >&2
    echo "  $1" >&2
}

# - K8S_VERSIONS: explicit one-off override (comma or space separated)
# - K8S_MATRIX_VERSIONS: ordered repository-configured list
k8s_versions() {
    if [ -n "${K8S_VERSIONS:-}" ]; then
        local normalized
        normalized="$(echo "${K8S_VERSIONS}" | tr ',' ' ' | xargs)"
        local count
        count="$(echo "${normalized}" | wc -w | tr -d ' ')"
        if [ "${count}" -ge 1 ]; then
            info "Using explicit versions from K8S_VERSIONS: ${normalized}"
            echo "${normalized}"
            return
        fi
    fi

    local configured="${K8S_MATRIX_VERSIONS:-}"
    [ -n "${configured}" ] || fail "Set K8S_MATRIX_VERSIONS or K8S_VERSIONS before running. See https://hub.docker.com/r/kindest/node for available tags."

    local normalized
    normalized="$(echo "${configured}" | tr ',' ' ' | xargs)"
    local count
    count="$(echo "${normalized}" | wc -w | tr -d ' ')"
    [ "${count}" -ge 1 ] || fail "K8S_MATRIX_VERSIONS did not contain any usable versions. See https://hub.docker.com/r/kindest/node for available tags."

    echo "${normalized}"
}

# Configuration and environment setup
read -ra MATRIX_K8S_VERSIONS <<< "$(k8s_versions)"
KIND_CLUSTER_NAME="acceptance"

# Ensure the KIND cluster is deleted if the script exits for any reason
# (normal exit, Ctrl+C, CI cancellation, etc.)
trap 'cleanup_cluster' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
API_TEST="${SCRIPT_DIR}/controller-api-test.sh"
TEST_VALUES="${SCRIPT_DIR}/test-values.yaml"

if [ "${PRINT_RESOLVED_K8S_VERSIONS:-false}" = "true" ]; then
    echo "${MATRIX_K8S_VERSIONS[*]}"
    exit 0
fi

NAMESPACE="boundary"
POSTGRES_USER="boundary"
POSTGRES_PASSWORD="boundary-test-pw"
POSTGRES_DB="boundary"
POSTGRES_HOST="postgres.${NAMESPACE}.svc.cluster.local"
POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:5432/${POSTGRES_DB}?sslmode=disable"

header "Pre-flight Checks"
for cmd in kubectl helm curl docker kind; do
    command -v "${cmd}" >/dev/null 2>&1 \
        || fail "'${cmd}' is required but not installed. Run: make acceptance-setup"
    pass "${cmd} found"
done

# Confirm Docker daemon is reachable
docker info >/dev/null 2>&1 \
    || fail "Docker daemon is not running."
pass "Docker daemon is running"

[ -f "${API_TEST}" ]     || fail "Controller API test not found: ${API_TEST}"
if [ -f "${TEST_VALUES}" ]; then
    pass "Test scripts and values present"
else
    warn "Test values not found at ${TEST_VALUES}; chart defaults will be used"
fi

# Check required environment variables
for var in BOUNDARY_LICENSE BOOTSTRAP_ADMIN_PASSWORD; do
    [ -n "${!var:-}" ] \
        || fail "'${var}' is not set. Add it to .env or export it before running."
done
BOOTSTRAP_ADMIN_USERNAME="${BOOTSTRAP_ADMIN_USERNAME:-admin}"
pass "Required environment variables are set"
echo ""

# Result tracking
RESULTS=()
RESULT_NOTES=()
VERSION_IDX=0

# -- preload_kind_image: pull image locally then load into KIND node ------------
preload_kind_image() {
    local image="$1"
    local label="$2"
    info "Pre-loading ${label} image into KIND cluster: ${image}"

    if ! docker image inspect "${image}" >/dev/null 2>&1; then
        info "Image not in local daemon — pulling..."
        if ! docker pull "${image}" >/dev/null 2>&1; then
            warn "docker pull failed for ${image} — pod will pull from registry (may be slow)"
            return 0
        fi
    fi

    if ! kind load docker-image "${image}" \
            --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1; then
        warn "kind load docker-image failed — pod will pull from registry (may be slow)"
        return 0
    fi
    pass "${label} image pre-loaded: ${image}"
}

# -- preload_controller_image: pull image locally then load into KIND node ------
preload_controller_image() {
    local image="${BOUNDARY_CONTROLLER_IMAGE:-hashicorp/boundary-enterprise:0.21-ent}"
    preload_kind_image "${image}" "Controller"
}

# -- cleanup_cluster: delete the acceptance cluster if it exists ---------------
cleanup_cluster() {
        if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        info "Deleting existing KIND cluster '${KIND_CLUSTER_NAME}'..."
                kind delete cluster --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1
        pass "Cluster '${KIND_CLUSTER_NAME}' deleted"
    fi
}

create_kind_config_for_k8s() {
        local k8s_version="$1"
        local cfg
        cfg="$(mktemp)" || fail "Failed to create temp kind config"
        cat >"${cfg}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: kindest/node:${k8s_version}
  - role: worker
    image: kindest/node:${k8s_version}
  - role: worker
    image: kindest/node:${k8s_version}
EOF
        echo "${cfg}"
}

# -- setup_postgres: deploy official postgres:16 in-cluster -------------------
setup_postgres() {
    local postgres_image="${POSTGRES_IMAGE:-postgres:16}"
    info "Deploying in-cluster PostgreSQL (${postgres_image})..."

    preload_kind_image "${postgres_image}" "PostgreSQL"

    kubectl create namespace "${NAMESPACE}" \
        --context "kind-${KIND_CLUSTER_NAME}" \
        --dry-run=client -o yaml \
        | kubectl apply -f - --context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1

    kubectl apply -f "${SCRIPT_DIR}/postgres.yaml" \
        --context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1 \
        || fail "Failed to apply postgres.yaml"

    info "Waiting for PostgreSQL pod to be ready..."
    kubectl wait --for=condition=ready pod \
        -n "${NAMESPACE}" \
        --context "kind-${KIND_CLUSTER_NAME}" \
        -l "app=postgres" \
        --timeout=300s >/dev/null 2>&1 \
        || fail "PostgreSQL pod did not become ready within 300s"
    pass "PostgreSQL is ready"
}

# -- create_controller_secrets: create the K8s Secret required by the chart ----
create_controller_secrets() {
    info "Creating boundary-controller-secrets Kubernetes Secret..."
    kubectl create secret generic boundary-controller-secrets \
        --namespace "${NAMESPACE}" \
        --context "kind-${KIND_CLUSTER_NAME}" \
        --from-literal="database-url=${POSTGRES_URL}" \
        --from-literal="license=${BOUNDARY_LICENSE}" \
        --from-literal="admin-username=${BOOTSTRAP_ADMIN_USERNAME}" \
        --from-literal="admin-password=${BOOTSTRAP_ADMIN_PASSWORD}" \
        >/dev/null 2>&1 || true
    pass "Secret 'boundary-controller-secrets' created"
}

# -- install_helm_chart: install / upgrade the controller chart ----------------
install_helm_chart() {
    info "Installing boundary-controller Helm chart..."

    local image_flags=()
    if [ -n "${BOUNDARY_CONTROLLER_IMAGE:-}" ]; then
        local img_repo img_tag
        if [[ "${BOUNDARY_CONTROLLER_IMAGE}" == *":"* ]]; then
            img_repo="${BOUNDARY_CONTROLLER_IMAGE%:*}"
            img_tag="${BOUNDARY_CONTROLLER_IMAGE##*:}"
        else
            img_repo="${BOUNDARY_CONTROLLER_IMAGE}"
            img_tag="latest"
        fi
        image_flags=(--set "image.repository=${img_repo}" --set "image.tag=${img_tag}")
        info "Using image override: ${BOUNDARY_CONTROLLER_IMAGE} (repo: ${img_repo}, tag: ${img_tag})"
    fi

    HELM_OUT=$(mktemp) || fail "Failed to create temp file for helm output"
    [ -n "${HELM_OUT}" ] || fail "mktemp returned empty path"
    local values_args=()
    if [ -f "${TEST_VALUES}" ]; then
        values_args=(--values "${TEST_VALUES}")
    fi

    if ! helm install boundary-controller "${CHART_DIR}" \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --kube-context "kind-${KIND_CLUSTER_NAME}" \
        "${values_args[@]}" \
        "${image_flags[@]}" \
        --timeout 10m >"${HELM_OUT}" 2>&1; then
        echo "" >&2
        echo "❌ helm install failed. Output:" >&2
        cat "${HELM_OUT}" >&2
        rm -f "${HELM_OUT}"
        fail "Helm chart installation failed"
    fi
    rm -f "${HELM_OUT}"

    # Verify at least one controller pod was scheduled
    info "Verifying controller pod was scheduled..."
    for i in $(seq 1 30); do
        POD_COUNT=$(kubectl get pods \
            -n "${NAMESPACE}" \
            --context "kind-${KIND_CLUSTER_NAME}" \
            -l "app.kubernetes.io/name=boundary-controller,app.kubernetes.io/component=controller" \
            --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [ "${POD_COUNT}" -gt 0 ] && break
        sleep 2
    done
    [ "${POD_COUNT:-0}" -gt 0 ] \
        || fail "No controller pod was scheduled after helm install"
    pass "Helm chart installed — ${POD_COUNT} pod(s) scheduled (readiness handled by API test)"
}

# K8s version matrix test
header "Kubernetes Version Matrix Test — Controller API"
echo "  Versions  : ${MATRIX_K8S_VERSIONS[*]}"
echo "  Chart dir : ${CHART_DIR}"

for VERSION in "${MATRIX_K8S_VERSIONS[@]}"; do

    header "Testing with Kubernetes ${VERSION}"
    info "Using node image: kindest/node:${VERSION}"
    echo ""

    # 1. Remove any leftover cluster from a previous run
    cleanup_cluster

    # 2-7. Run cluster setup and API test in a subshell so a failure records FAIL
    #       and continues to the next version instead of aborting the whole matrix.
    set +e
    (
        set -euo pipefail

        # 2. Create a fresh cluster with this Kubernetes version
        local_kind_cfg="$(create_kind_config_for_k8s "${VERSION}")"
        info "Creating KIND cluster '${KIND_CLUSTER_NAME}' using kindest/node:${VERSION}..."
        CREATE_OUT=$(mktemp) || fail "Failed to create temp file for cluster creation output"
        [ -n "${CREATE_OUT}" ] || fail "mktemp returned empty path"
        if ! kind create cluster \
            --name "${KIND_CLUSTER_NAME}" \
            --config "${local_kind_cfg}" >"${CREATE_OUT}" 2>&1; then
            echo "" >&2
            echo "❌ kind create cluster failed. Output:" >&2
            cat "${CREATE_OUT}" >&2
            rm -f "${local_kind_cfg}"
            rm -f "${CREATE_OUT}"
            fail "KIND cluster creation failed for Kubernetes ${VERSION}"
        fi
        rm -f "${local_kind_cfg}"
        rm -f "${CREATE_OUT}"
        pass "Cluster '${KIND_CLUSTER_NAME}' created with Kubernetes ${VERSION}"
        echo ""

        # 3. Pre-load the controller image into the KIND node to avoid cold pull
        preload_controller_image
        echo ""

        # 4. Deploy in-cluster PostgreSQL
        setup_postgres
        echo ""

        # 5. Create the controller K8s Secret
        create_controller_secrets
        echo ""

        # 6. Install the Helm chart
        install_helm_chart
        echo ""

        # 7. Run the controller API test with an extended timeout.
        # TIMEOUT=600 gives 10 min — enough for image load + db-init + bootstrap jobs.
        info "Running controller-api-test.sh for Kubernetes ${VERSION} (TIMEOUT=600s)..."
        echo ""
        TIMEOUT=600 \
        BOOTSTRAP_ADMIN_USERNAME="${BOOTSTRAP_ADMIN_USERNAME}" \
        BOOTSTRAP_ADMIN_PASSWORD="${BOOTSTRAP_ADMIN_PASSWORD}" \
        bash "${API_TEST}"
    )
    VERSION_EXIT=$?
    set -e

    if [ "${VERSION_EXIT}" -eq 0 ]; then
        RESULTS[$VERSION_IDX]="PASS"
        RESULT_NOTES[$VERSION_IDX]=""
        pass "Kubernetes ${VERSION}: Controller API test PASSED"
    else
        RESULTS[$VERSION_IDX]="FAIL"
        RESULT_NOTES[$VERSION_IDX]="exited with code ${VERSION_EXIT}"
        warn "Kubernetes ${VERSION}: Controller API test FAILED (exit code ${VERSION_EXIT})"
    fi

    # 8. Tear down the cluster
    echo ""
    info "Tearing down cluster for Kubernetes ${VERSION}..."
    cleanup_cluster
    pass "Cleanup complete for Kubernetes ${VERSION}"

    VERSION_IDX=$(( VERSION_IDX + 1 ))

done

# Summary of results
header "Matrix Test Summary"
printf "  %-14s  %-8s  %s\n" "K8s Version" "Result" "Notes"
printf "  %-14s  %-8s  %s\n" "--------------" "--------" "-----"

OVERALL_PASS=true
_IDX=0
for VERSION in "${MATRIX_K8S_VERSIONS[@]}"; do
    RESULT="${RESULTS[$_IDX]:-SKIP}"
    NOTE="${RESULT_NOTES[$_IDX]:-}"
    if [ "${RESULT}" = "PASS" ]; then
        printf "  %-14s  ✅ %-8s  %s\n" "${VERSION}" "PASS" "${NOTE}"
    else
        printf "  %-14s  ❌ %-8s  %s\n" "${VERSION}" "${RESULT}" "${NOTE}"
        OVERALL_PASS=false
    fi
    _IDX=$(( _IDX + 1 ))
done

echo ""
if [ "${OVERALL_PASS}" = "true" ]; then
    pass "All Kubernetes versions passed the Controller API test!"
    exit 0
else
    fail "One or more Kubernetes versions failed — see summary above."
fi
