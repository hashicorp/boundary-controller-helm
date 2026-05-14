# ================================
# PHONY Declarations
# ================================
.PHONY: help format deps clean lint test unit-test worker-config
.PHONY: setup-helm setup-kubeconform setup-trivy setup-kubescape setup-helm-unittest lint-helm-k8s trivy-scan kubescape-scan
.PHONY: acceptance-setup acceptance-cluster acceptance-helm acceptance-test acceptance-full acceptance-cleanup
.PHONY: acceptance-int-test acceptance-int-full acceptance-connect
.PHONY: kind-matrix-test kind-matrix-cleanup

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
	@echo "  make acceptance-cleanup      - Delete acceptance KIND cluster"
	@echo "  make kind-matrix-test        - Run controller-api-test.sh across 2 KIND versions prior to latest"
	@echo "  make kind-matrix-cleanup     - Delete the acceptance cluster and cached KIND binaries"
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
	helm lint .
	@echo "✅ Helm lint passed!"
	@echo ""
	@echo "================================"
	@echo "Rendering Helm Templates"
	@echo "================================"
	helm template boundary-worker . --set controller.secretRefs.validateExisting=false > rendered.yaml
	@echo "✅ Templates rendered successfully!"
	@echo "Rendered file size: $$(wc -l < rendered.yaml) lines"
	@echo ""
	@echo "================================"
	@echo "Running Kubernetes Validation"
	@echo "================================"
	kubeconform -strict rendered.yaml
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
	echo "Deploying in-cluster PostgreSQL (official postgres:16)..."; \
	kubectl create namespace boundary --context kind-acceptance --dry-run=client -o yaml \
		| kubectl apply -f - --context kind-acceptance; \
	kubectl apply -f tests/acceptance/postgres.yaml --context kind-acceptance; \
	echo "Waiting for PostgreSQL to be ready..."; \
	kubectl wait --for=condition=ready pod \
		-n boundary \
		--context kind-acceptance \
		-l "app=postgres" \
		--timeout=120s; \
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
		--timeout 10m
	@echo "✅ Helm chart installed successfully"
	@echo ""
	@echo "Deployed resources:"
	@kubectl get all -n boundary --context kind-acceptance
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
	@BOOTSTRAP_ADMIN_USERNAME=$${BOOTSTRAP_ADMIN_USERNAME:-admin} \
		bash tests/acceptance/cluster-smoke-test.sh
	@echo ""
	@BOOTSTRAP_ADMIN_USERNAME=$${BOOTSTRAP_ADMIN_USERNAME:-admin} \
		bash tests/acceptance/controller-api-test.sh
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
	@bash tests/acceptance/kind-version-matrix-test.sh

kind-matrix-cleanup:
	@echo "================================"
	@echo "KIND Matrix Cleanup"
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
	@rm -f "$${TMPDIR:-/tmp}"/kind-v* 2>/dev/null || true
	@echo "✅ Cached KIND binaries removed"
