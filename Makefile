# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

# Load .env if present; shell-exported vars take precedence over .env values.
-include .env
export BOUNDARY_LICENSE
export BOOTSTRAP_ADMIN_PASSWORD
export BOOTSTRAP_ADMIN_USERNAME
export K8S_MATRIX_VERSIONS

# ================================
# PHONY Declarations
# ================================
.PHONY: help format deps clean lint test unit-test chart-test
.PHONY: setup-helm setup-kubeconform setup-trivy setup-kubescape setup-helm-unittest lint-helm-k8s trivy-scan kubescape-scan
.PHONY: acceptance-setup acceptance-helm acceptance-test acceptance-full acceptance-cleanup
.PHONY: kind-matrix-test
.PHONY: eks-setup eks-apply eks-db-init-recovery eks-test eks-full eks-destroy
.PHONY: gke-setup gke-apply gke-db-init-recovery gke-test gke-full gke-destroy
.PHONY: aks-auth-check aks-setup aks-apply aks-db-init-recovery aks-test aks-full aks-destroy

HELM_TEST_RELEASE ?= boundary-controller
HELM_TEST_NAMESPACE ?= boundary
HELM_TEST_KUBE_CONTEXT ?=

# ================================
# Help Target
# ================================
help:
	@echo "================================"
	@echo "Boundary Controller Helm Chart - Targets"
	@echo "================================"
	@echo "Available targets:"
	@echo "  make format            - Format all YAML files with Prettier"
	@echo "  make deps              - Install required tools (macOS)"
	@echo "  make lint              - Run all lints and scans locally (deps + lint + scans)"
	@echo "  make test              - Run unit tests (alias for unit-test)"
	@echo "  make unit-test         - Run Helm unit tests with helm-unittest"
	@echo "  make chart-test        - Run Helm chart tests on a live cluster with helm test"
	@echo "  make clean             - Clean generated files"
	@echo ""
	@echo "CI/CD targets:"
	@echo "  make setup-helm              - Install Helm for CI"
	@echo "  make setup-helm-unittest     - Install helm-unittest plugin for CI"
	@echo "  make setup-kubeconform       - Install Kubeconform for CI"
	@echo "  make setup-trivy             - Install Trivy for CI"
	@echo "  make setup-kubescape         - Install Kubescape for CI"
	@echo "  make lint-helm-k8s           - Run Helm lint, render templates, and K8s validation"
	@echo "  make trivy-scan              - Run security scan with Trivy"
	@echo "  make kubescape-scan          - Run security scan with Kubescape"
	@echo ""
	@echo "Acceptance Testing targets:"
	@echo "  make acceptance-setup        - Install dependencies and set up KIND cluster"
	@echo "  make acceptance-helm         - Deploy postgres + install controller Helm chart"
	@echo "  make acceptance-test         - Run controller API acceptance tests"
	@echo "  make acceptance-full         - Full acceptance workflow (setup + helm + test)"
	@echo "  make acceptance-cleanup      - Delete acceptance KIND cluster and cached KIND binaries"
	@echo "  make kind-matrix-test        - Run controller-api-test.sh across K8s versions using KIND (requires acceptance-setup)"
	@echo ""
	@echo "EKS Integration Testing targets:"
	@echo "  make eks-setup               - Initialise Terraform for EKS integration tests"
	@echo "  make eks-apply               - Provision EKS cluster (phase 1), update kubeconfig, then deploy chart (phase 2)"
	@echo "  make eks-db-init-recovery    - Reinstall Helm release only when controller reports uninitialized DB"
	@echo "  make eks-test                - Run eks-integration-test.sh against the provisioned cluster"
	@echo "  make eks-full                - Full EKS integration workflow (setup + apply + test)"
	@echo "  make eks-destroy             - Destroy all EKS integration resources via Terraform"
	@echo "  make eks-destroy DESTROY_EKS_RESOURCES=true - Also destroy EKS infra via Terraform"
	@echo ""
	@echo "AKS Integration Testing targets:"
	@echo "  make aks-setup               - Initialise Terraform for AKS integration tests"
	@echo "  make aks-apply               - Provision AKS cluster and deploy chart via Terraform"
	@echo "  make aks-db-init-recovery    - Reinstall Helm release only when controller reports uninitialized DB"
	@echo "  make aks-test                - Run aks-integration-test.sh against the provisioned AKS cluster"
	@echo "  make aks-full                - Full AKS integration workflow (setup + apply + test)"
	@echo "  make aks-destroy             - Uninstall AKS Helm release only (default)"
	@echo "  make aks-destroy DESTROY_AKS_RESOURCES=true - Also destroy AKS infra via Terraform"
	@echo ""
	@echo "GKE Integration Testing targets:"
	@echo "  make gke-setup               - Initialise Terraform for GKE integration tests"
	@echo "  make gke-apply               - Provision GKE cluster (phase 1), update kubeconfig, then deploy chart (phase 2)"
	@echo "  make gke-db-init-recovery    - Reinstall Helm release only when controller reports uninitialized DB"
	@echo "  make gke-test                - Run gke-integration-test.sh against the provisioned cluster"
	@echo "  make gke-full                - Full GKE integration workflow (setup + apply + test)"
	@echo "  make gke-destroy             - Uninstall GKE Helm release only (default)"
	@echo "  make gke-destroy DESTROY_GKE_RESOURCES=true - Also destroy GKE infra via Terraform"
	@echo "================================"

# ================================
# Local Development Targets
# ================================

deps:
	@echo "Installing required tools..."
	@command -v helm >/dev/null 2>&1 || brew install helm
	@command -v kubeconform >/dev/null 2>&1 || brew install kubeconform
	@command -v yamllint >/dev/null 2>&1 || brew install yamllint
	@command -v trivy >/dev/null 2>&1 || brew install trivy
	@command -v kubescape >/dev/null 2>&1 || brew install kubescape
	@command -v prettier >/dev/null 2>&1 || npm install -g prettier
	@helm plugin list | grep -q unittest || helm plugin install https://github.com/helm-unittest/helm-unittest.git
	@echo "✅ All tools installed"

format:
	@echo "================================"
	@echo "Formatting YAML files with Prettier"
	@echo "================================"
	@if ! command -v prettier >/dev/null 2>&1; then \
		echo "❌ Prettier not found. Install with: npm install -g prettier"; \
		exit 1; \
	fi
	@echo "Formatting YAML files..."
	@prettier --write "**/*.{yaml,yml}" \
		--ignore-path .gitignore \
		--print-width 80 \
		--tab-width 2 \
		--prose-wrap preserve
	@echo "✅ All YAML files formatted"
	@echo ""

clean:
	@echo "Cleaning generated files..."
	@rm -f rendered.yaml yamllint-output.txt trivy-output.txt kubescape-output.json
	@echo "✅ Clean complete"

lint: deps
	@echo "================================"
	@echo "Running All Lints and Scans"
	@echo "================================"
	@echo ""
	@$(MAKE) lint-helm-k8s
	@echo ""
	@$(MAKE) trivy-scan
	@echo ""
	@$(MAKE) kubescape-scan
	@echo ""
	@echo "================================"
	@echo "✅ All lints and scans completed successfully!"
	@echo "================================"

# ================================
# Unit Testing Targets
# ================================

test: unit-test

unit-test:
	@echo "================================"
	@echo "Running Helm Unit Tests"
	@echo "================================"
	@if ! helm plugin list | grep -q unittest; then \
		echo "❌ helm-unittest plugin not found. Installing..."; \
		helm plugin install https://github.com/helm-unittest/helm-unittest.git; \
	fi
	@echo "Running unit tests..."
	@helm unittest . -f 'tests/unit/*_test.yaml'
	@echo "✅ Unit tests passed!"

chart-test:
	@echo "================================"
	@echo "Running Helm Chart Tests"
	@echo "================================"
	@command -v helm >/dev/null 2>&1 || (echo "❌ Helm not found"; exit 1)
	@helm test $(HELM_TEST_RELEASE) \
		--namespace $(HELM_TEST_NAMESPACE) \
		$(if $(HELM_TEST_KUBE_CONTEXT),--kube-context $(HELM_TEST_KUBE_CONTEXT),) \
		--logs
	@echo "✅ Helm chart tests passed!"

# ================================
# CI/CD Setup Targets
# ================================

setup-helm-unittest:
	@echo "Installing helm-unittest plugin..."
	@helm plugin install https://github.com/helm-unittest/helm-unittest.git || true
	@helm plugin list | grep unittest
	@echo "✅ helm-unittest plugin installed"

setup-helm:
	@echo "Installing Helm..."
	@curl -fsSL -o /tmp/get-helm-3.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
	@chmod +x /tmp/get-helm-3.sh
	@/tmp/get-helm-3.sh
	@helm version
	@echo "✅ Helm installed"

setup-kubeconform:
	@echo "Installing Kubeconform..."
	@curl -fsSL -o /tmp/kubeconform.tar.gz https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz
	@tar -xzf /tmp/kubeconform.tar.gz -C /tmp
	@sudo mv /tmp/kubeconform /usr/local/bin/
	@kubeconform -v
	@echo "✅ Kubeconform installed"

setup-trivy:
	@echo "Installing Trivy..."
	@sudo apt-get install -y wget apt-transport-https gnupg lsb-release
	@wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
	@echo "deb https://aquasecurity.github.io/trivy-repo/deb $$(lsb_release -sc) main" | sudo tee -a /etc/apt/sources.list.d/trivy.list
	@sudo apt-get update
	@sudo apt-get install -y trivy
	@trivy --version
	@echo "✅ Trivy installed"

setup-kubescape:
	@echo "Installing Kubescape..."
	@curl -fsSL -o /tmp/kubescape-install.sh https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh
	@chmod +x /tmp/kubescape-install.sh
	@/tmp/kubescape-install.sh
	@export PATH=$$PATH:$$HOME/.kubescape/bin && \
		sudo cp $$HOME/.kubescape/bin/kubescape /usr/local/bin/ && \
		kubescape version
	@echo "✅ Kubescape installed"

# ================================
# CI/CD Lint & Scan Targets
# ================================

lint-helm-k8s:
	@echo "================================"
	@echo "Running Helm Lint"
	@echo "================================"
	@helm lint .
	@echo "✅ Helm lint passed!"
	@echo ""
	@echo "================================"
	@echo "Rendering Helm Templates"
	@echo "================================"
	@helm template boundary-controller . --set controller.secretRefs.validateExisting=false > rendered.yaml
	@echo "✅ Templates rendered successfully!"
	@echo "Rendered file size: $$(wc -l < rendered.yaml) lines"
	@echo ""
	@echo "================================"
	@echo "Running Kubernetes Validation"
	@echo "================================"
	@kubeconform -strict rendered.yaml
	@echo "✅ Kubernetes validation passed!"

trivy-scan:
	@echo "================================"
	@echo "Running Security Scan with Trivy"
	@echo "================================"
	@trivy config rendered.yaml --exit-code 0 2>&1 | tee trivy-output.txt
	@CRITICAL_COUNT=$$(grep -E 'CRITICAL: [0-9]+' trivy-output.txt | sed -E 's/.*CRITICAL: ([0-9]+).*/\1/' | head -1); \
	HIGH_COUNT=$$(grep -E 'HIGH: [0-9]+' trivy-output.txt | sed -E 's/.*HIGH: ([0-9]+).*/\1/' | head -1); \
	MEDIUM_COUNT=$$(grep -E 'MEDIUM: [0-9]+' trivy-output.txt | sed -E 's/.*MEDIUM: ([0-9]+).*/\1/' | head -1); \
	LOW_COUNT=$$(grep -E 'LOW: [0-9]+' trivy-output.txt | sed -E 's/.*LOW: ([0-9]+).*/\1/' | head -1); \
	CRITICAL_COUNT=$${CRITICAL_COUNT:-0}; \
	HIGH_COUNT=$${HIGH_COUNT:-0}; \
	MEDIUM_COUNT=$${MEDIUM_COUNT:-0}; \
	LOW_COUNT=$${LOW_COUNT:-0}; \
	echo ""; \
	echo "Security Scan Results:"; \
	echo "  CRITICAL: $$CRITICAL_COUNT"; \
	echo "  HIGH: $$HIGH_COUNT"; \
	echo "  MEDIUM: $$MEDIUM_COUNT"; \
	echo "  LOW: $$LOW_COUNT"; \
	echo ""; \
	if [ $$CRITICAL_COUNT -gt 0 ] || [ $$HIGH_COUNT -gt 0 ]; then \
		echo "❌ Security scan FAILED: $$CRITICAL_COUNT CRITICAL, $$HIGH_COUNT HIGH issues"; \
		exit 1; \
	elif [ $$MEDIUM_COUNT -gt 0 ] || [ $$LOW_COUNT -gt 0 ]; then \
		echo "⚠️  Security scan completed with warnings: $$MEDIUM_COUNT MEDIUM, $$LOW_COUNT LOW issues"; \
	else \
		echo "✅ Security scan passed!"; \
	fi

kubescape-scan:
	@echo "================================"
	@echo "Running Security Scan with Kubescape"
	@echo "================================"
	@kubescape scan rendered.yaml \
		--format json \
		--output kubescape-output.json \
		--exceptions ./kubescape-exceptions.json \
		--verbose; KUBESCAPE_EXIT=$$?; \
	if [ $$KUBESCAPE_EXIT -ne 0 ] && [ ! -f kubescape-output.json ]; then \
		echo "❌ Kubescape failed to run (exit code: $$KUBESCAPE_EXIT)"; \
		exit $$KUBESCAPE_EXIT; \
	fi
	@echo ""
	@echo "================================"
	@echo "Kubescape Scan Results"
	@echo "================================"
	@if [ -f kubescape-output.json ]; then \
		if command -v jq >/dev/null 2>&1; then \
			COMPLIANCE_SCORE=$$(jq -r '.summaryDetails.complianceScore // 0' kubescape-output.json); \
			PASSED_RESOURCES=$$(jq -r '.summaryDetails.ResourceCounters.passedResources // 0' kubescape-output.json); \
			FAILED_CONTROLS=$$(jq '[.summaryDetails.controls[] | select(.failedResources != null and .failedResources > 0)] | length' kubescape-output.json); \
		else \
			echo "⚠️  jq not found, using grep fallback (less reliable)"; \
			COMPLIANCE_SCORE="N/A"; \
			PASSED_RESOURCES=$$(grep -o '"passedResources":[0-9]*' kubescape-output.json | head -1 | cut -d':' -f2 || echo "0"); \
			FAILED_CONTROLS=0; \
		fi; \
		echo "  Compliance Score: $$COMPLIANCE_SCORE%"; \
		echo "  Passed Resources: $$PASSED_RESOURCES"; \
		echo "  Failed Controls: $$FAILED_CONTROLS"; \
		echo ""; \
		if [ "$$FAILED_CONTROLS" -gt 0 ]; then \
			echo "❌ Kubescape scan FAILED: $$FAILED_CONTROLS control(s) have failed resources"; \
			exit 1; \
		else \
			echo "✅ Kubescape scan passed! All controls passed (compliance: $$COMPLIANCE_SCORE%)"; \
		fi; \
	else \
		echo "⚠️  Kubescape output file not found"; \
	fi

# ================================
# Acceptance Testing Targets
# ================================

acceptance-setup:
	@echo "================================"
	@echo "Setting up Acceptance Environment"
	@echo "================================"
	@echo ""
	@echo "Checking dependencies..."
	@if ! command -v kubectl >/dev/null 2>&1; then \
		echo "❌ kubectl is not installed"; \
		echo "Please install kubectl: https://kubernetes.io/docs/tasks/tools/"; \
		exit 1; \
	fi
	@echo "✅ kubectl is installed ($$(kubectl version --client --short 2>/dev/null || kubectl version --client))"
	@if ! command -v kind >/dev/null 2>&1; then \
		echo "❌ kind is not installed"; \
		echo "Installing kind..."; \
		if [ "$$(uname)" = "Darwin" ]; then \
			brew install kind; \
		else \
			curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64; \
			chmod +x ./kind; \
			sudo mv ./kind /usr/local/bin/kind; \
		fi; \
	fi
	@echo "✅ kind is installed ($$(kind version))"
	@if ! command -v helm >/dev/null 2>&1; then \
		echo "❌ helm is not installed"; \
		echo "Installing helm..."; \
		curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; \
	fi
	@echo "✅ helm is installed ($$(helm version --short 2>/dev/null || helm version))"
	@if ! command -v boundary >/dev/null 2>&1; then \
		echo "⚠️  boundary CLI is not installed"; \
		echo "Installing boundary CLI..."; \
		ENV=$$(uname); \
		if [ "$$ENV" = "Darwin" ]; then \
			brew tap hashicorp/tap && brew install hashicorp/tap/boundary; \
		elif [ "$$ENV" = "Linux" ]; then \
			wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; \
			echo "deb [arch=$$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list; \
			sudo apt update && sudo apt install -y boundary; \
		else \
			echo "❌ Failed to install Boundary"; \
			exit 1; \
		fi; \
	fi
	@echo "✅ boundary CLI is installed ($$(boundary version 2>/dev/null | head -n1 || echo 'version unknown'))"
	@echo ""
	@echo "Setting up KIND cluster..."
	@if kind get clusters | grep -q "^acceptance$$"; then \
		echo "⚠️  Acceptance cluster already exists"; \
	else \
		kind create cluster --config tests/acceptance/kind-acceptance-config.yaml; \
		echo "✅ Acceptance cluster created"; \
	fi
	@echo ""
	@echo "Verifying cluster..."
	@kubectl cluster-info --context kind-acceptance
	@echo "✅ Cluster is ready"
	@echo ""
	@echo "Installed tools:"
	@echo "  - kubectl:  $$(kubectl version --client --short 2>/dev/null | head -n1 || echo 'installed')"
	@echo "  - kind:     $$(kind version)"
	@echo "  - helm:     $$(helm version --short 2>/dev/null | head -n1 || echo 'installed')"
	@echo "  - boundary: $$(boundary version 2>/dev/null | head -n1 || echo 'installed')"
	@echo ""
	@echo "Next steps:"
	@echo "  - Install Helm chart: make acceptance-helm"
	@echo "  - Run tests:          make acceptance-test"
	@echo "  - Full workflow:      make acceptance-full"
	@echo "  - Cleanup:            make acceptance-cleanup"

acceptance-helm:
	@echo "============================================"
	@echo "Installing Helm Chart in Acceptance Cluster"
	@echo "============================================"
	@echo ""
	@command -v helm >/dev/null 2>&1 || (echo "❌ Helm not found. Run 'make acceptance-setup' first"; exit 1)
	@if [ -z "$$BOUNDARY_LICENSE" ]; then \
		echo "❌ BOUNDARY_LICENSE is not set. Add it to .env or export it."; \
		exit 1; \
	fi
	@if [ -z "$$BOOTSTRAP_ADMIN_PASSWORD" ]; then \
		echo "❌ BOOTSTRAP_ADMIN_PASSWORD is not set. Add it to .env or export it."; \
		exit 1; \
	fi
	@BOOTSTRAP_ADMIN_USERNAME=$${BOOTSTRAP_ADMIN_USERNAME:-admin}; \
	CONTROLLER_IMAGE=$${BOUNDARY_CONTROLLER_IMAGE:-hashicorp/boundary-enterprise:1.0.0-ent}; \
	POSTGRES_IMAGE=$${POSTGRES_IMAGE:-postgres:16}; \
	echo "Pre-loading controller image into KIND: $$CONTROLLER_IMAGE"; \
	if ! docker image inspect "$$CONTROLLER_IMAGE" >/dev/null 2>&1; then \
		echo "Controller image not in local daemon, pulling..."; \
		if ! docker pull "$$CONTROLLER_IMAGE" >/dev/null 2>&1; then \
			echo "⚠️  WARN: Failed to pull $$CONTROLLER_IMAGE; cluster may pull from registry (slower)"; \
		fi; \
	fi; \
	if ! kind load docker-image "$$CONTROLLER_IMAGE" --name acceptance >/dev/null 2>&1; then \
		echo "⚠️  WARN: Failed to load $$CONTROLLER_IMAGE into kind; cluster may pull from registry (slower)"; \
	else \
		echo "✅ Controller image pre-loaded"; \
	fi; \
	echo "Deploying in-cluster PostgreSQL ($$POSTGRES_IMAGE)..."; \
	echo "Pre-loading PostgreSQL image into KIND: $$POSTGRES_IMAGE"; \
	if ! docker image inspect "$$POSTGRES_IMAGE" >/dev/null 2>&1; then \
		echo "PostgreSQL image not in local daemon, pulling..."; \
		if ! docker pull "$$POSTGRES_IMAGE" >/dev/null 2>&1; then \
			echo "⚠️  WARN: Failed to pull $$POSTGRES_IMAGE; cluster may pull from registry (slower)"; \
		fi; \
	fi; \
	if ! kind load docker-image "$$POSTGRES_IMAGE" --name acceptance >/dev/null 2>&1; then \
		echo "⚠️  WARN: Failed to load $$POSTGRES_IMAGE into kind; cluster may pull from registry (slower)"; \
	else \
		echo "✅ PostgreSQL image pre-loaded"; \
	fi; \
	kubectl create namespace boundary --context kind-acceptance --dry-run=client -o yaml \
		| kubectl apply -f - --context kind-acceptance; \
	kubectl apply -f tests/acceptance/postgres.yaml --context kind-acceptance; \
	echo "Waiting for PostgreSQL to be ready..."; \
	kubectl wait --for=condition=ready pod \
		-n boundary \
		--context kind-acceptance \
		-l "app=postgres" \
		--timeout=300s; \
	echo "✅ PostgreSQL is ready"; \
	echo ""; \
	echo "Creating boundary-controller-secrets Secret..."; \
	kubectl create secret generic boundary-controller-secrets \
		--namespace boundary \
		--context kind-acceptance \
		--from-literal="database-url=postgresql://boundary:boundary-test-pw@postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable" \
		--from-literal="license=$$BOUNDARY_LICENSE" \
		--from-literal="admin-username=$$BOOTSTRAP_ADMIN_USERNAME" \
		--from-literal="admin-password=$$BOOTSTRAP_ADMIN_PASSWORD" \
		--dry-run=client -o yaml | kubectl apply -f - --context kind-acceptance; \
	echo "✅ Secret created"; \
	echo ""; \
	echo "Installing boundary-controller chart with test values..."
	@helm upgrade --install boundary-controller . \
		--namespace boundary \
		--create-namespace \
		--kube-context kind-acceptance \
		--values tests/acceptance/test-values.yaml \
		--timeout 10m >/dev/null
	@echo "✅ Helm chart installed successfully"
	@echo ""
	@echo "Waiting for all controller replicas to be ready..."
	@kubectl wait --for=condition=available --timeout=10m \
		deployment/boundary-controller \
		-n boundary \
		--context kind-acceptance
	@echo "✅ Deployment is ready ($$(kubectl get deployment boundary-controller -n boundary --context kind-acceptance -o jsonpath='{.status.readyReplicas}') replica(s) up)"

acceptance-test:
	@echo "================================"
	@echo "Running Controller Acceptance Tests"
	@echo "================================"
	@echo ""
	@if [ -z "$$BOOTSTRAP_ADMIN_PASSWORD" ]; then \
		echo "❌ BOOTSTRAP_ADMIN_PASSWORD is not set. Add it to .env or export it."; \
		exit 1; \
	fi
	@if [ -z "$$BOUNDARY_LICENSE" ]; then \
		echo "❌ BOUNDARY_LICENSE is not set. Add it to .env or export it."; \
		exit 1; \
	fi
	@export BOOTSTRAP_ADMIN_USERNAME=$${BOOTSTRAP_ADMIN_USERNAME:-admin};
	@bash tests/acceptance/cluster-smoke-test.sh
	@K8S_MATRIX_VERSIONS="$$K8S_MATRIX_VERSIONS" \
		BOUNDARY_LICENSE="$$BOUNDARY_LICENSE" \
		BOOTSTRAP_ADMIN_PASSWORD="$$BOOTSTRAP_ADMIN_PASSWORD" \
		BOOTSTRAP_ADMIN_USERNAME="$${BOOTSTRAP_ADMIN_USERNAME:-admin}" \
		bash tests/acceptance/kind-version-matrix-test.sh
	@echo ""
	@echo "✅ All acceptance tests passed!"

acceptance-full:
	@echo "================================"
	@echo "Full Controller Acceptance Workflow"
	@echo "================================"
	@echo ""
	@$(MAKE) acceptance-setup
	@$(MAKE) acceptance-helm
	@$(MAKE) acceptance-test
	@echo ""
	@echo "✅ End-to-end acceptance workflow completed successfully"
	@echo ""
	@echo "To cleanup: make acceptance-cleanup"

acceptance-cleanup:
	@echo "================================"
	@echo "Cleaning Up Acceptance Environment"
	@echo "================================"
	@echo ""
	@if kind get clusters 2>/dev/null | grep -q "^acceptance$$"; then \
		echo "Deleting KIND cluster 'acceptance'..."; \
		kind delete cluster --name acceptance; \
		echo "✅ Cluster deleted"; \
	else \
		echo "⚠️  No 'acceptance' cluster found"; \
	fi
	@echo "Removing cached KIND binaries..."
	@find "$${TMPDIR:-/tmp}" -maxdepth 1 -name 'kind-v[0-9]*' 2>/dev/null | while read -r BIN; do \
		rm -f "$$BIN"; \
		echo "✅ Removed cached $$(basename $$BIN) binary"; \
	done
	@echo "✅ Acceptance cleanup complete"

kind-matrix-test:
	@echo "================================"
	@echo "KIND Version Matrix Test"
	@echo "================================"
	@echo ""
	@if [ -z "$$BOUNDARY_LICENSE" ]; then \
		echo "❌ BOUNDARY_LICENSE is not set. Add it to .env or export it."; \
		exit 1; \
	fi
	@if [ -z "$$BOOTSTRAP_ADMIN_PASSWORD" ]; then \
		echo "❌ BOOTSTRAP_ADMIN_PASSWORD is not set. Add it to .env or export it."; \
		exit 1; \
	fi
	@K8S_MATRIX_VERSIONS="$$K8S_MATRIX_VERSIONS" \
		BOUNDARY_LICENSE="$$BOUNDARY_LICENSE" \
		BOOTSTRAP_ADMIN_PASSWORD="$$BOOTSTRAP_ADMIN_PASSWORD" \
		BOOTSTRAP_ADMIN_USERNAME="$${BOOTSTRAP_ADMIN_USERNAME:-admin}" \
		bash tests/acceptance/kind-version-matrix-test.sh
# ================================
# EKS Integration Testing Targets	
# ================================

INTEGRATION_DIR := tests/integration/terraform/aws
AKS_INTEGRATION_DIR := tests/integration/terraform/azure
INTEGRATION_ENV := tests/integration/.env

# Load .env if it exists
ifneq (,$(wildcard $(INTEGRATION_ENV)))
  include $(INTEGRATION_ENV)
  export
endif

eks-setup:
	@echo "================================"
	@echo "Initialising Terraform (EKS Integration)"
	@echo "================================"
	@command -v terraform >/dev/null 2>&1 || (echo "❌ terraform not found. Install from https://developer.hashicorp.com/terraform/downloads"; exit 1)
	@command -v aws >/dev/null 2>&1 || (echo "❌ aws CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"; exit 1)
	@[ -f "$(INTEGRATION_ENV)" ] || (echo "❌ $(INTEGRATION_ENV) not found. Copy tests/integration/.env.example to tests/integration/.env and fill in your values."; exit 1)
	@terraform -chdir=$(INTEGRATION_DIR) init
	@echo "✅ Terraform initialised"
	@echo ""

eks-apply: eks-setup
	@echo "================================"
	@echo "Provisioning EKS Cluster + Helm Install"
	@echo "================================"
	@[ -n "$${TF_VAR_boundary_license}" ]        || (echo "❌ TF_VAR_boundary_license is not set in $(INTEGRATION_ENV)";        exit 1)
	@[ -n "$${TF_VAR_boundary_admin_password}" ]  || (echo "❌ TF_VAR_boundary_admin_password is not set in $(INTEGRATION_ENV)"; exit 1)
	@echo ""
	@echo "--- Step 1/2: Provision VPC + EKS cluster + node group ---"
	@terraform -chdir=$(INTEGRATION_DIR) apply -auto-approve \
		-target=aws_vpc.this \
		-target=aws_subnet.public \
		-target=aws_subnet.private \
		-target=aws_internet_gateway.this \
		-target=aws_eip.nat \
		-target=aws_nat_gateway.this \
		-target=aws_route_table.public \
		-target=aws_route_table_association.public \
		-target=aws_route_table.private \
		-target=aws_route_table_association.private \
		-target=aws_iam_role.eks_cluster \
		-target=aws_iam_role_policy_attachment.eks_cluster_policy \
		-target=aws_iam_role.eks_nodes \
		-target=aws_iam_role_policy_attachment.eks_worker_node_policy \
		-target=aws_iam_role_policy_attachment.eks_cni_policy \
		-target=aws_iam_role_policy_attachment.eks_ecr_read \
		-target=aws_eks_cluster.this \
		-target=aws_eks_node_group.this \
		-target=aws_iam_openid_connect_provider.eks
	@echo "✅ EKS cluster ready"
	@echo ""
	@echo "--- Updating kubeconfig ---"
	@aws eks update-kubeconfig \
		--region "$${TF_VAR_aws_region:-us-east-1}" \
		--name "$${TF_VAR_eks_cluster_name:-boundary-controller-cluster}" \
		--alias "eks-$${TF_VAR_eks_cluster_name:-boundary-controller-cluster}"
	@echo "✅ kubeconfig updated"
	@echo ""
	@echo "--- Step 2/2: Apply remaining resources (KMS, IAM, Kubernetes, Helm) ---"
	@terraform -chdir=$(INTEGRATION_DIR) apply -auto-approve
	@$(MAKE) eks-db-init-recovery
	@echo "✅ Terraform apply complete (infrastructure, PostgreSQL, and Helm chart)"
	@echo ""

eks-db-init-recovery:
	@echo "--- Optional recovery: checking for DB init miss ---"
	@KCTX="eks-$${TF_VAR_eks_cluster_name:-boundary-controller-cluster}"; \
	POD=$$(kubectl get pods -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" \
		-l "app.kubernetes.io/name=boundary-controller,app.kubernetes.io/component=controller" \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); \
	if [ -z "$$POD" ]; then \
		echo "ℹ️  No controller pod yet; skipping DB-init recovery check"; \
		exit 0; \
	fi; \
	LOGS=$$(kubectl logs -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" "$$POD" --previous 2>/dev/null || \
		kubectl logs -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" "$$POD" 2>/dev/null || true); \
	if echo "$$LOGS" | grep -qi "database has not been initialized"; then \
		echo "⚠️  Detected uninitialized Boundary DB. Replacing Helm release to re-run pre-install init hooks..."; \
		terraform -chdir=$(INTEGRATION_DIR) apply -auto-approve -replace=helm_release.boundary_controller; \
		echo "✅ Recovery apply completed"; \
	else \
		echo "✅ DB-init recovery not needed"; \
	fi

eks-test:
	@echo "================================"
	@echo "Running EKS Integration Tests"
	@echo "================================"
	@bash tests/integration/eks-integration-test.sh \
		--cluster-name "$${TF_VAR_eks_cluster_name:-boundary-controller-cluster}" \
		--region "$${AWS_REGION:-us-east-1}" \
		--namespace "$${BOUNDARY_NAMESPACE:-boundary}" \
		--release "$${HELM_RELEASE:-boundary-controller}" \
		--timeout "$${TIMEOUT:-300}"
	@echo ""

eks-full:
	@echo "================================"
	@echo "Full EKS Integration Workflow"
	@echo "================================"
	@$(MAKE) eks-apply
	@$(MAKE) eks-test
	@echo ""
	@echo "✅ EKS integration workflow completed successfully"
	@echo ""
	@echo "To uninstall only Helm release: make eks-destroy"
	@echo "To destroy EKS infra as well: make eks-destroy DESTROY_EKS_RESOURCES=true"
	@echo ""

eks-destroy:
	@echo "================================"
	@echo "Destroying EKS Integration Resources"
	@echo "================================"
	@EKS_NAME="$${TF_VAR_eks_cluster_name:-boundary-controller-cluster}"; \
	REGION="$${AWS_REGION:-$${TF_VAR_aws_region:-us-east-1}}"; \
	REL_NAME="$${HELM_RELEASE:-boundary-controller}"; \
	NS_NAME="$${BOUNDARY_NAMESPACE:-boundary}"; \
	KCTX="eks-$$EKS_NAME"; \
	if command -v aws >/dev/null 2>&1; then \
		aws eks update-kubeconfig --region "$$REGION" --name "$$EKS_NAME" --alias "$$KCTX" >/dev/null 2>&1 || true; \
	fi; \
	if helm status "$$REL_NAME" --namespace "$$NS_NAME" --kube-context "$$KCTX" >/dev/null 2>&1; then \
		helm uninstall "$$REL_NAME" --namespace "$$NS_NAME" --kube-context "$$KCTX"; \
		echo "✅ EKS Helm release '$$REL_NAME' uninstalled"; \
	else \
		echo "ℹ️  Helm release '$$REL_NAME' not found in namespace '$$NS_NAME' (context: $$KCTX)"; \
	fi
	@if [ "$${DESTROY_EKS_RESOURCES:-false}" = "true" ]; then \
		echo "--- DESTROY_EKS_RESOURCES=true: destroying EKS infrastructure via Terraform ---"; \
		terraform -chdir=$(INTEGRATION_DIR) destroy -auto-approve; \
		echo "✅ All EKS integration resources destroyed"; \
	else \
		echo "ℹ️  EKS infrastructure preserved"; \
		echo "ℹ️  Set DESTROY_EKS_RESOURCES=true to destroy EKS resources as well"; \
	fi
	@echo ""

aks-test:
	@echo "================================"
	@echo "Running AKS Integration Tests"
	@echo "================================"
	@AKS_NAME="$${AKS_CLUSTER_NAME:-$${TF_VAR_aks_cluster_name:-}}"; \
	RG_NAME="$${AKS_RESOURCE_GROUP:-$${TF_VAR_resource_group_name:-}}"; \
	[ -n "$$AKS_NAME" ] || (echo "❌ AKS cluster name is not set (AKS_CLUSTER_NAME or TF_VAR_aks_cluster_name)"; exit 1); \
	[ -n "$$RG_NAME" ]  || (echo "❌ AKS resource group is not set (AKS_RESOURCE_GROUP or TF_VAR_resource_group_name)"; exit 1); \
	bash tests/integration/aks-integration-test.sh \
		--cluster-name "$$AKS_NAME" \
		--resource-group "$$RG_NAME" \
		--subscription-id "$${AZURE_SUBSCRIPTION_ID:-$${TF_VAR_azure_subscription_id:-}}" \
		--namespace "$${BOUNDARY_NAMESPACE:-boundary}" \
		--release "$${HELM_RELEASE:-boundary-controller}" \
		--timeout "$${TIMEOUT:-300}" \
		$$( [ "$${SKIP_API:-false}" = "true" ] && echo --skip-api )
	@echo ""

aks-auth-check:
	@echo "Checking Azure CLI authentication..."
	@command -v az >/dev/null 2>&1 || (echo "❌ az CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli"; exit 1)
	@TENANT="$${AZURE_TENANT_ID:-$${TF_VAR_azure_tenant_id:-}}"; \
	if [ -z "$$TENANT" ]; then \
		TENANT=$$(az account show --query tenantId -o tsv 2>/dev/null || true); \
	fi; \
	if ! az account show >/dev/null 2>&1 || \
	   ! az account get-access-token --resource-type arm >/dev/null 2>&1 || \
	   ! az account get-access-token --scope "https://graph.microsoft.com/.default" >/dev/null 2>&1; then \
		echo "❌ Azure CLI authentication is missing or expired"; \
		echo "Interactive authentication must be performed manually (not inside this script)."; \
		if [ -n "$$TENANT" ]; then \
			echo "Please run Azure login manually for tenant: $$TENANT"; \
		else \
			echo "Please run Azure login manually in your terminal."; \
		fi; \
		exit 1; \
	fi
	@echo "✅ Azure CLI is authenticated"

aks-setup: aks-auth-check
	@echo "================================"
	@echo "Initialising Terraform (AKS Integration)"
	@echo "================================"
	@command -v terraform >/dev/null 2>&1 || (echo "❌ terraform not found. Install from https://developer.hashicorp.com/terraform/downloads"; exit 1)
	@[ -f "$(INTEGRATION_ENV)" ] || (echo "❌ $(INTEGRATION_ENV) not found. Copy tests/integration/.env.example to tests/integration/.env and fill in your values."; exit 1)
	@terraform -chdir=$(AKS_INTEGRATION_DIR) init
	@echo "✅ Terraform initialised"
	@echo ""

aks-apply: aks-setup aks-auth-check
	@echo "================================"
	@echo "Provisioning AKS Cluster + Helm Install"
	@echo "================================"
	@[ -n "$${TF_VAR_boundary_license}" ]       || (echo "❌ TF_VAR_boundary_license is not set in $(INTEGRATION_ENV)"; exit 1)
	@[ -n "$${TF_VAR_boundary_admin_password}" ] || (echo "❌ TF_VAR_boundary_admin_password is not set in $(INTEGRATION_ENV)"; exit 1)
	@echo ""
	@echo "--- Step 1/3: Bootstrap AKS control plane resources ---"
	@terraform -chdir=$(AKS_INTEGRATION_DIR) apply -auto-approve \
		-target=azurerm_resource_group.this \
		-target=azurerm_kubernetes_cluster.this
	@echo "✅ AKS control plane bootstrap ready"
	@echo ""
	@echo "--- Updating kubeconfig ---"
	@az account show >/dev/null 2>&1 || (echo "❌ Not logged into Azure CLI. Run: az login"; exit 1)
	@if [ -n "$${AZURE_SUBSCRIPTION_ID:-$${TF_VAR_azure_subscription_id:-$${AKS_SUBSCRIPTION_ID:-}}}" ]; then \
		az account set --subscription "$${AZURE_SUBSCRIPTION_ID:-$${TF_VAR_azure_subscription_id:-$${AKS_SUBSCRIPTION_ID:-}}}"; \
	fi
	@az aks get-credentials \
		--resource-group "$${AKS_RESOURCE_GROUP:-$${TF_VAR_resource_group_name:-rg-boundary-controller-aks}}" \
		--name "$${AKS_CLUSTER_NAME:-$${TF_VAR_aks_cluster_name:-boundary-controller-aks}}" \
		--overwrite-existing \
		--context "aks-$${AKS_CLUSTER_NAME:-$${TF_VAR_aks_cluster_name:-boundary-controller-aks}}"
	@echo "✅ kubeconfig updated"
	@echo ""
	@echo "--- Step 2/3: Full Terraform apply (Kubernetes + Helm) ---"
	@terraform -chdir=$(AKS_INTEGRATION_DIR) apply -auto-approve
	@echo "✅ Full Terraform apply completed"
	@echo ""
	@echo "--- Step 3/3: Verify post-kubeconfig state ---"
	@$(MAKE) aks-db-init-recovery
	@echo "✅ Terraform apply complete (infrastructure, PostgreSQL, and Helm chart)"
	@echo ""

aks-db-init-recovery:
	@echo "--- Optional recovery: checking for DB init miss ---"
	@KCTX="aks-$${AKS_CLUSTER_NAME:-$${TF_VAR_aks_cluster_name:-boundary-controller-aks}}"; \
	POD=$$(kubectl get pods -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" \
		-l "app.kubernetes.io/name=boundary-controller,app.kubernetes.io/component=controller" \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); \
	if [ -z "$$POD" ]; then \
		echo "ℹ️  No controller pod yet; skipping DB-init recovery check"; \
		exit 0; \
	fi; \
	LOGS=$$(kubectl logs -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" "$$POD" --previous 2>/dev/null || \
		kubectl logs -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" "$$POD" 2>/dev/null || true); \
	if echo "$$LOGS" | grep -qi "database has not been initialized"; then \
		echo "⚠️  Detected uninitialized Boundary DB. Replacing Helm release to re-run pre-install init hooks..."; \
		terraform -chdir=$(AKS_INTEGRATION_DIR) apply -auto-approve -replace=helm_release.boundary_controller; \
		echo "✅ Recovery apply completed"; \
	else \
		echo "✅ DB-init recovery not needed"; \
	fi

aks-full:
	@echo "================================"
	@echo "Full AKS Integration Workflow"
	@echo "================================"
	@$(MAKE) aks-apply
	@$(MAKE) aks-test
	@echo ""
	@echo "✅ AKS integration workflow completed successfully"
	@echo ""
	@echo "To uninstall only Helm release: make aks-destroy"
	@echo "To destroy AKS infra as well: make aks-destroy DESTROY_AKS_RESOURCES=true"
	@echo ""

aks-destroy:
	@echo "================================"
	@echo "Destroying AKS Integration Resources"
	@echo "================================"
	@AKS_NAME="$${AKS_CLUSTER_NAME:-$${TF_VAR_aks_cluster_name:-}}"; \
	RG_NAME="$${AKS_RESOURCE_GROUP:-$${TF_VAR_resource_group_name:-}}"; \
	REL_NAME="$${HELM_RELEASE:-boundary-controller}"; \
	NS_NAME="$${BOUNDARY_NAMESPACE:-boundary}"; \
	KCTX="aks-$$AKS_NAME"; \
	if [ -n "$$AKS_NAME" ] && [ -n "$$RG_NAME" ]; then \
		if az account show >/dev/null 2>&1; then \
			if [ -n "$${AZURE_SUBSCRIPTION_ID:-$${TF_VAR_azure_subscription_id:-$${AKS_SUBSCRIPTION_ID:-}}}" ]; then \
				az account set --subscription "$${AZURE_SUBSCRIPTION_ID:-$${TF_VAR_azure_subscription_id:-$${AKS_SUBSCRIPTION_ID:-}}}" >/dev/null 2>&1 || true; \
			fi; \
			az aks get-credentials --resource-group "$$RG_NAME" --name "$$AKS_NAME" --overwrite-existing --context "$$KCTX" >/dev/null 2>&1 || true; \
		fi; \
	fi; \
	if helm status "$$REL_NAME" --namespace "$$NS_NAME" --kube-context "$$KCTX" >/dev/null 2>&1; then \
		helm uninstall "$$REL_NAME" --namespace "$$NS_NAME" --kube-context "$$KCTX"; \
		echo "✅ AKS Helm release '$$REL_NAME' uninstalled"; \
	else \
		echo "ℹ️  Helm release '$$REL_NAME' not found in namespace '$$NS_NAME' (context: $$KCTX)"; \
	fi
	@if [ "$${DESTROY_AKS_RESOURCES:-false}" = "true" ]; then \
		echo "--- DESTROY_AKS_RESOURCES=true: destroying AKS infrastructure via Terraform ---"; \
		terraform -chdir=$(AKS_INTEGRATION_DIR) destroy -auto-approve; \
		echo "✅ All AKS integration resources destroyed"; \
	else \
		echo "ℹ️  AKS infrastructure preserved"; \
		echo "ℹ️  Set DESTROY_AKS_RESOURCES=true to destroy AKS resources as well"; \
	fi
	@echo ""

# ================================
# GKE Integration Testing Targets
# ================================

GKE_INTEGRATION_DIR := tests/integration/terraform/gcp
GKE_INTEGRATION_ENV := tests/integration/.env

gke-setup:
	@echo "================================"
	@echo "Initialising Terraform (GKE Integration)"
	@echo "================================"
	@command -v terraform >/dev/null 2>&1 || (echo "❌ terraform not found. Install from https://developer.hashicorp.com/terraform/downloads"; exit 1)
	@command -v gcloud >/dev/null 2>&1 || (echo "❌ gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"; exit 1)
	@[ -f "$(GKE_INTEGRATION_ENV)" ] || (echo "❌ $(GKE_INTEGRATION_ENV) not found. Copy tests/integration/.env.example to tests/integration/.env and fill in your values."; exit 1)
	@terraform -chdir=$(GKE_INTEGRATION_DIR) init
	@echo "✅ Terraform initialised"
	@echo ""

gke-apply: gke-setup
	@echo "================================"
	@echo "Provisioning GKE Cluster + Helm Install"
	@echo "================================"
	@[ -n "$${TF_VAR_boundary_license}" ]       || (echo "❌ TF_VAR_boundary_license is not set in $(GKE_INTEGRATION_ENV)";       exit 1)
	@[ -n "$${TF_VAR_boundary_admin_password}" ] || (echo "❌ TF_VAR_boundary_admin_password is not set in $(GKE_INTEGRATION_ENV)"; exit 1)
	@[ -n "$${TF_VAR_gcp_project_id}" ]          || (echo "❌ TF_VAR_gcp_project_id is not set in $(GKE_INTEGRATION_ENV)";          exit 1)
	@echo ""
	@echo "--- Step 1/2: Provision VPC + GKE cluster + node pool ---"
	@terraform -chdir=$(GKE_INTEGRATION_DIR) apply -auto-approve \
		-target=google_compute_network.this \
		-target=google_compute_subnetwork.this \
		-target=google_container_cluster.this \
		-target=google_container_node_pool.this
	@echo "✅ GKE cluster ready"
	@echo ""
	@echo "--- Updating kubeconfig ---"
	@gcloud container clusters get-credentials \
		"$${TF_VAR_gke_cluster_name:-boundary-controller-cluster}" \
		--zone "$${TF_VAR_gke_zone:-us-central1-a}" \
		--project "$${TF_VAR_gcp_project_id}"
	@echo "✅ kubeconfig updated"
	@echo ""
	@echo "--- Step 2/2: Apply remaining resources (IAM, Kubernetes, Helm) ---"
	@terraform -chdir=$(GKE_INTEGRATION_DIR) apply -auto-approve
	@$(MAKE) gke-db-init-recovery
	@echo "✅ Terraform apply complete (infrastructure, PostgreSQL, and Helm chart)"
	@echo ""

gke-db-init-recovery:
	@echo "--- Optional recovery: checking for DB init miss ---"
	@KCTX="gke_$${TF_VAR_gcp_project_id}_$${TF_VAR_gke_zone:-us-central1-a}_$${TF_VAR_gke_cluster_name:-boundary-controller-cluster}"; \
	POD=$$(kubectl get pods -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" \
		-l "app.kubernetes.io/name=boundary-controller,app.kubernetes.io/component=controller" \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); \
	if [ -z "$$POD" ]; then \
		echo "ℹ️  No controller pod yet; skipping DB-init recovery check"; \
		exit 0; \
	fi; \
	LOGS=$$(kubectl logs -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" "$$POD" --previous 2>/dev/null || \
		kubectl logs -n "$${BOUNDARY_NAMESPACE:-boundary}" --context "$$KCTX" "$$POD" 2>/dev/null || true); \
	if echo "$$LOGS" | grep -qi "database has not been initialized"; then \
		echo "⚠️  Detected uninitialized Boundary DB. Replacing Helm release to re-run pre-install init hooks..."; \
		terraform -chdir=$(GKE_INTEGRATION_DIR) apply -auto-approve -replace=helm_release.boundary_controller; \
		echo "✅ Recovery apply completed"; \
	else \
		echo "✅ DB-init recovery not needed"; \
	fi

gke-test:
	@echo "================================"
	@echo "Running GKE Integration Tests"
	@echo "================================"
	@bash tests/integration/gke-integration-test.sh \
		--project-id "$${TF_VAR_gcp_project_id}" \
		--zone "$${TF_VAR_gke_zone:-us-central1-a}" \
		--cluster-name "$${TF_VAR_gke_cluster_name:-boundary-controller-cluster}" \
		--namespace "$${BOUNDARY_NAMESPACE:-boundary}" \
		--release "$${HELM_RELEASE:-boundary-controller}" \
		--timeout "$${TIMEOUT:-300}"
	@echo ""

gke-full:
	@echo "================================"
	@echo "Full GKE Integration Workflow"
	@echo "================================"
	@$(MAKE) gke-apply
	@$(MAKE) gke-test
	@echo ""
	@echo "✅ GKE integration workflow completed successfully"
	@echo ""
	@echo "To uninstall only Helm release: make gke-destroy"
	@echo "To destroy GKE infra as well: make gke-destroy DESTROY_GKE_RESOURCES=true"
	@echo ""

gke-destroy:
	@echo "================================"
	@echo "Destroying GKE Integration Resources"
	@echo "================================"
	@GKE_NAME="$${TF_VAR_gke_cluster_name:-boundary-controller-cluster}"; \
	ZONE="$${TF_VAR_gke_zone:-us-central1-a}"; \
	PROJECT="$${TF_VAR_gcp_project_id}"; \
	REL_NAME="$${HELM_RELEASE:-boundary-controller}"; \
	NS_NAME="$${BOUNDARY_NAMESPACE:-boundary}"; \
	KCTX="gke_$${PROJECT}_$${ZONE}_$${GKE_NAME}"; \
	if command -v gcloud >/dev/null 2>&1 && [ -n "$$PROJECT" ]; then \
		gcloud container clusters get-credentials "$$GKE_NAME" --zone "$$ZONE" --project "$$PROJECT" >/dev/null 2>&1 || true; \
	fi; \
	if helm status "$$REL_NAME" --namespace "$$NS_NAME" --kube-context "$$KCTX" >/dev/null 2>&1; then \
		helm uninstall "$$REL_NAME" --namespace "$$NS_NAME" --kube-context "$$KCTX"; \
		echo "✅ GKE Helm release '$$REL_NAME' uninstalled"; \
	else \
		echo "ℹ️  Helm release '$$REL_NAME' not found in namespace '$$NS_NAME' (context: $$KCTX)"; \
	fi
	@if [ "$${DESTROY_GKE_RESOURCES:-false}" = "true" ]; then \
		echo "--- DESTROY_GKE_RESOURCES=true: destroying GKE infrastructure via Terraform ---"; \
		terraform -chdir=$(GKE_INTEGRATION_DIR) destroy -auto-approve; \
		echo "✅ All GKE integration resources destroyed"; \
	else \
		echo "ℹ️  GKE infrastructure preserved"; \
		echo "ℹ️  Set DESTROY_GKE_RESOURCES=true to destroy GKE resources as well"; \
	fi
	@echo ""
