#!/bin/bash
# Copyright IBM Corp. 2026


set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TEST_NAMESPACE="boundary-controller-test"
CONTEXT="kind-acceptance"

echo "Acceptance Test Suite"

# Function to print test results
print_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✅ PASSED:${NC} $2"
    else
        echo -e "${RED}❌ FAILED:${NC} $2"
        exit 1
    fi
}

# Test 1: Verify cluster is accessible
echo "Test 1: Verifying cluster accessibility..."
if kubectl cluster-info --context "${CONTEXT}" > /dev/null 2>&1; then
    print_result 0 "Cluster is accessible"
else
    print_result 1 "Cluster is not accessible"
fi
echo ""

# Test 2: Create test namespace
echo "Test 2: Creating test namespace '${TEST_NAMESPACE}'..."
if kubectl create namespace "${TEST_NAMESPACE}" --context "${CONTEXT}" > /dev/null 2>&1; then
    print_result 0 "Namespace created successfully"
else
    # Check if namespace already exists
    if kubectl get namespace "${TEST_NAMESPACE}" --context "${CONTEXT}" > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  WARNING:${NC} Namespace already exists, continuing..."
    else
        print_result 1 "Failed to create namespace"
    fi
fi
echo ""

# Test 3: Verify namespace exists
echo "Test 3: Verifying namespace exists..."
if kubectl get namespace "${TEST_NAMESPACE}" --context "${CONTEXT}" > /dev/null 2>&1; then
    print_result 0 "Namespace '${TEST_NAMESPACE}' exists"
else
    print_result 1 "Namespace '${TEST_NAMESPACE}' does not exist"
fi
echo ""

# Test 4: List all namespaces and verify test namespace is present
echo "Test 4: Listing all namespaces..."
NAMESPACES=$(kubectl get namespaces --context "${CONTEXT}" -o jsonpath='{.items[*].metadata.name}')
echo "Available namespaces: ${NAMESPACES}"
echo ""

if echo "${NAMESPACES}" | grep -q "${TEST_NAMESPACE}"; then
    print_result 0 "Test namespace found in namespace list"
else
    print_result 1 "Test namespace not found in namespace list"
fi
echo ""

# Test 5: Get namespace details
echo "Test 5: Getting namespace details..."
kubectl get namespace "${TEST_NAMESPACE}" --context "${CONTEXT}" -o yaml > /dev/null 2>&1
if [ $? -eq 0 ]; then
    print_result 0 "Successfully retrieved namespace details"
    echo ""
    echo "Namespace status:"
    kubectl get namespace "${TEST_NAMESPACE}" --context "${CONTEXT}"
else
    print_result 1 "Failed to retrieve namespace details"
fi
echo ""

# Cleanup
echo "Cleaning up test namespace..."
if kubectl delete namespace "${TEST_NAMESPACE}" --context "${CONTEXT}" --wait=false > /dev/null 2>&1; then
    echo "✅ Test Namespace Successfully Cleaned Up"
else
    echo -e "${YELLOW}⚠️  WARNING:${NC} Failed to cleanup test namespace"
fi
echo ""
echo "✅ Cluster Smoke test passed!"
