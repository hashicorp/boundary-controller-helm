#!/bin/bash
# Copyright IBM Corp. 2026


set -euo pipefail

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
    if [ "$1" -eq 0 ]; then
        echo -e "${GREEN}✅ :${NC} $2"
    else
        echo -e "${RED}❌ :${NC} $2"
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

# Cleanup
echo "Cleaning up test namespace..."
if kubectl delete namespace "${TEST_NAMESPACE}" --context "${CONTEXT}" --wait=false > /dev/null 2>&1; then
    echo "✅ Test Namespace Successfully Cleaned Up"
else
    echo -e "${YELLOW}⚠️  WARNING:${NC} Failed to cleanup test namespace"
fi
echo ""
echo "✅ Cluster Smoke test passed!"
