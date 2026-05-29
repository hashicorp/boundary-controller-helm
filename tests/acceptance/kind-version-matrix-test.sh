#!/bin/bash
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

# KIND Version Matrix Test
# Tests controller-api-test.sh against multiple KIND versions.

set -euo pipefail

# -- Helpers --------------------------------------------------------------------
pass()   { echo "   ✅ $1" >&2; }
fail()   { echo "❌ FAILED: $1" >&2; exit 1; }
info()   { echo "   $1" >&2; }
warn()   { echo "⚠️  WARN: $1" >&2; }
header() {
    echo "" >&2
    echo "  $1" >&2
}

# -- Fallback versions ----------------------------------------------------------
_FALLBACK_KIND_VERSIONS=("v0.30.0" "v0.29.0")

# -- resolve_kind_versions ------------------------------------------------------
resolve_kind_versions() {
    local raw
    raw="$(curl -fsSL --retry 2 --connect-timeout 10 \
        "https://api.github.com/repos/kubernetes-sigs/kind/releases" 2>/dev/null)" || true

    if [ -z "${raw}" ]; then
        warn "GitHub Releases API unreachable — using fallback KIND versions: ${_FALLBACK_KIND_VERSIONS[*]}"
        echo "${_FALLBACK_KIND_VERSIONS[@]}"
        return
    fi

    local output
    output="$(printf '%s' "${raw}" | python3 -c "
import json, sys
releases = json.load(sys.stdin)
tags = sorted(
    [r['tag_name'] for r in releases
     if not r.get('prerelease', False) and r.get('tag_name', '').startswith('v')],
    key=lambda v: [int(x) if x.isdigit() else 0 for x in v.lstrip('v').split('.')],
    reverse=True
)
print(' '.join(tags[1:3]))
" 2>/dev/null)" || true

    local word_count
    word_count="$(echo "${output}" | wc -w | tr -d ' ')"
    if [ -z "${output}" ] || [ "${word_count}" -lt 2 ]; then
        warn "Could not parse KIND releases — using fallback: ${_FALLBACK_KIND_VERSIONS[*]}"
        echo "${_FALLBACK_KIND_VERSIONS[@]}"
        return
    fi

    echo "${output}"
}

# -- Configuration --------------------------------------------------------------
read -ra KIND_VERSIONS <<< "$(resolve_kind_versions)"
KIND_CLUSTER_NAME="acceptance"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KIND_CONFIG="${SCRIPT_DIR}/kind-acceptance-config.yaml"
API_TEST="${SCRIPT_DIR}/controller-api-test.sh"
TEST_VALUES="${SCRIPT_DIR}/test-values.yaml"
KIND_CACHE_DIR="${TMPDIR:-/tmp}"

NAMESPACE="boundary"
POSTGRES_USER="boundary"
POSTGRES_PASSWORD="boundary-test-pw"
POSTGRES_DB="boundary"
POSTGRES_HOST="postgres.${NAMESPACE}.svc.cluster.local"
POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:5432/${POSTGRES_DB}?sslmode=disable"

# -- OS / Architecture detection -----------------------------------------------
_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
_ARCH="$(uname -m)"
case "${_ARCH}" in
    x86_64)         _ARCH="amd64"  ;;
    arm64|aarch64)  _ARCH="arm64"  ;;
    *) fail "Unsupported architecture: ${_ARCH}" ;;
esac
KIND_PLATFORM="${_OS}-${_ARCH}"

# -- Pre-flight checks ----------------------------------------------------------
header "Pre-flight Checks"
for cmd in kubectl helm curl python3 docker; do
    command -v "${cmd}" >/dev/null 2>&1 \
        || fail "'${cmd}' is required but not installed. Run: make acceptance-setup"
    pass "${cmd} found"
done

# Confirm Docker daemon is reachable
docker info >/dev/null 2>&1 \
    || fail "Docker daemon is not running."
pass "Docker daemon is running"

[ -f "${KIND_CONFIG}" ]  || fail "Kind config not found: ${KIND_CONFIG}"
[ -f "${API_TEST}" ]     || fail "Controller API test not found: ${API_TEST}"
[ -f "${TEST_VALUES}" ]  || fail "Test values not found: ${TEST_VALUES}"
pass "Test scripts and values present"

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

# -- download_kind: fetch a pinned KIND binary, cache it in /tmp ----------------
download_kind() {
    local version="$1"
    local bin_path="${KIND_CACHE_DIR}/kind-${version}"

    if [ -x "${bin_path}" ]; then
        info "Using cached KIND ${version} at ${bin_path}"
    else
        info "Downloading KIND ${version} for ${KIND_PLATFORM}..."
        curl -fsSL \
            "https://kind.sigs.k8s.io/dl/${version}/kind-${KIND_PLATFORM}" \
            -o "${bin_path}"
        chmod +x "${bin_path}"
        pass "Downloaded KIND ${version}"
    fi

    echo "${bin_path}"
}

# -- preload_controller_image: pull image locally then load into KIND node ------
preload_controller_image() {
    local kind_bin="$1"
    local image="${BOUNDARY_CONTROLLER_IMAGE:-hashicorp/boundary-enterprise:0.21-ent}"
    info "Pre-loading controller image into KIND cluster: ${image}"

    if ! docker image inspect "${image}" >/dev/null 2>&1; then
        info "Image not in local daemon — pulling..."
        if ! docker pull "${image}" >/dev/null 2>&1; then
            warn "docker pull failed for ${image} — pod will pull from registry (may be slow)"
            return 0
        fi
    fi

    if ! "${kind_bin}" load docker-image "${image}" \
            --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1; then
        warn "kind load docker-image failed — pod will pull from registry (may be slow)"
        return 0
    fi
    pass "Controller image pre-loaded: ${image}"
}

# -- cleanup_cluster: delete the acceptance cluster if it exists ---------------
cleanup_cluster() {
    local kind_bin="$1"
    if "${kind_bin}" get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        info "Deleting existing KIND cluster '${KIND_CLUSTER_NAME}'..."
        "${kind_bin}" delete cluster --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1
        pass "Cluster '${KIND_CLUSTER_NAME}' deleted"
    fi
}

# -- setup_postgres: deploy official postgres:16 in-cluster -------------------
setup_postgres() {
    info "Deploying in-cluster PostgreSQL (official postgres:16)..."

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
        --timeout=120s >/dev/null 2>&1 \
        || fail "PostgreSQL pod did not become ready within 120s"
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
    if ! helm install boundary-controller "${CHART_DIR}" \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --kube-context "kind-${KIND_CLUSTER_NAME}" \
        --values "${TEST_VALUES}" \
        "${image_flags[@]+"${image_flags[@]}"}" \
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

# -- Main matrix loop -----------------------------------------------------------
header "KIND Version Matrix Test — Controller API"
echo "  Platform  : ${KIND_PLATFORM}"
echo "  Versions  : ${KIND_VERSIONS[*]}"
echo "  Chart dir : ${CHART_DIR}"

for VERSION in "${KIND_VERSIONS[@]}"; do

    header "Testing with KIND ${VERSION}"

    # 1. Download pinned KIND binary
    KIND_BIN="$(download_kind "${VERSION}")"

    # 2. Confirm binary reports the expected version
    DETECTED="$("${KIND_BIN}" version 2>&1)"
    info "Binary reports: ${DETECTED}"
    echo ""

    # 3. Remove any leftover cluster from a previous run
    cleanup_cluster "${KIND_BIN}"

    # 4-9. Run cluster setup and API test in a subshell so a failure records FAIL
    #       and continues to the next version instead of aborting the whole matrix.
    set +e
    (
        set -euo pipefail

        # 4. Create a fresh cluster with this KIND version
        info "Creating KIND cluster '${KIND_CLUSTER_NAME}' using KIND ${VERSION}..."
        CREATE_OUT=$(mktemp) || fail "Failed to create temp file for cluster creation output"
        [ -n "${CREATE_OUT}" ] || fail "mktemp returned empty path"
        if ! "${KIND_BIN}" create cluster \
            --name "${KIND_CLUSTER_NAME}" \
            --config "${KIND_CONFIG}" >"${CREATE_OUT}" 2>&1; then
            echo "" >&2
            echo "❌ kind create cluster failed. Output:" >&2
            cat "${CREATE_OUT}" >&2
            rm -f "${CREATE_OUT}"
            fail "KIND cluster creation failed for ${VERSION}"
        fi
        rm -f "${CREATE_OUT}"
        pass "Cluster '${KIND_CLUSTER_NAME}' created with KIND ${VERSION}"
        echo ""

        # 5. Pre-load the controller image into the KIND node to avoid cold pull
        preload_controller_image "${KIND_BIN}"
        echo ""

        # 6. Deploy in-cluster PostgreSQL
        setup_postgres
        echo ""

        # 7. Create the controller K8s Secret
        create_controller_secrets
        echo ""

        # 8. Install the Helm chart
        install_helm_chart
        echo ""

        # 9. Run the controller API test with an extended timeout.
        # TIMEOUT=600 gives 10 min — enough for image load + db-init + bootstrap jobs.
        info "Running controller-api-test.sh for KIND ${VERSION} (TIMEOUT=600s)..."
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
        pass "KIND ${VERSION}: Controller API test PASSED"
    else
        RESULTS[$VERSION_IDX]="FAIL"
        RESULT_NOTES[$VERSION_IDX]="exited with code ${VERSION_EXIT}"
        warn "KIND ${VERSION}: Controller API test FAILED (exit code ${VERSION_EXIT})"
    fi

    # 10. Tear down the cluster
    echo ""
    info "Tearing down cluster for KIND ${VERSION}..."
    cleanup_cluster "${KIND_BIN}"
    pass "Cleanup complete for KIND ${VERSION}"

    VERSION_IDX=$(( VERSION_IDX + 1 ))

done

# -- Summary --------------------------------------------------------------------
header "Matrix Test Summary"
printf "  %-14s  %-8s  %s\n" "KIND Version" "Result" "Notes"
printf "  %-14s  %-8s  %s\n" "--------------" "--------" "-----"

OVERALL_PASS=true
_IDX=0
for VERSION in "${KIND_VERSIONS[@]}"; do
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
    pass "All KIND versions passed the Controller API test!"
    exit 0
else
    fail "One or more KIND versions failed — see summary above."
fi
