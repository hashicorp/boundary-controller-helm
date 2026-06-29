{{/*
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0
*/}}

{{/*
Expand the name of the chart.

Naming precedence:
- fullnameOverride: use as-is for the full resource base name
- nameOverride: prefix chart name with <nameOverride>-<chartName>
- default: chart name
*/}}
{{- define "boundary.name" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if .Values.nameOverride -}}
{{- printf "%s-%s" .Values.nameOverride .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Resolve the effective namespace for namespaced resources.
*/}}
{{- define "boundary.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "boundary.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "boundary.labels" -}}
helm.sh/chart: {{ include "boundary.chart" . }}
{{ include "boundary.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "boundary.selectorLabels" -}}
app.kubernetes.io/name: {{ include "boundary.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Controller selector labels
*/}}
{{- define "boundary.controller.selectorLabels" -}}
{{ include "boundary.selectorLabels" . }}
app.kubernetes.io/component: controller
{{- end }}

{{/*
Get the controller service name
*/}}
{{- define "boundary.controller.serviceName" -}}
{{- include "boundary.name" . -}}
{{- end }}

{{/*
Get the controller API service name
*/}}
{{- define "boundary.controller.apiServiceName" -}}
{{- printf "%s-api" (include "boundary.name" .) }}
{{- end }}

{{/*
Get the controller cluster service name
*/}}
{{- define "boundary.controller.clusterServiceName" -}}
{{- printf "%s-cluster" (include "boundary.name" .) }}
{{- end }}

{{/*
Get the controller ops service name
*/}}
{{- define "boundary.controller.opsServiceName" -}}
{{- printf "%s-ops" (include "boundary.name" .) }}
{{- end }}

{{/*
Get the controller configmap name
*/}}
{{- define "boundary.controller.configMapName" -}}
{{- printf "%s-config" (include "boundary.name" .) }}
{{- end }}

{{/*
Get the controller secret name
*/}}
{{- define "boundary.controller.secretName" -}}
{{- if .Values.secretRefs.secretName }}
{{- .Values.secretRefs.secretName }}
{{- else }}
{{- printf "%s-secrets" (include "boundary.controller.serviceName" .) }}
{{- end }}
{{- end }}

{{/*
Get the service account name for the controller
*/}}
{{- define "boundary.controller.serviceAccountName" -}}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}

{{/*
Build the controller image reference.
*/}}
{{- define "boundary.controller.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag | trim) -}}
{{- end }}

{{/*
Determines whether the ops listener has TLS disabled, by inspecting the ops
listener block in controller.config directly.

Rule: only an explicit tls_disable = false in the ops block means TLS is on.
Anything else — tls_disable = true, absent, or no ops block at all — means HTTP.
The global tls.disabled value is intentionally not used here; the probe scheme
must reflect what the ops port actually serves, not the chart-level TLS toggle.
*/}}
{{- define "boundary.controller.opsListenerTlsDisabled" -}}
{{- $configNoComments := regexReplaceAll "(?m)^\\s*#.*$" .Values.controller.config "" -}}
{{- $opsBlock := regexFind "(?s)listener\\s+\"tcp\"\\s*\\{[^}]*purpose\\s*=\\s*\"ops\"[^}]*\\}" $configNoComments -}}
{{- if and (ne $opsBlock "") (regexMatch "tls_disable\\s*=\\s*false" $opsBlock) -}}
false
{{- else -}}
true
{{- end -}}
{{- end }}

{{/*
Resolves the HTTP probe scheme (HTTP or HTTPS) for liveness and readiness probes.

Priority order:
  1. controller.livenessProbe.scheme / controller.readinessProbe.scheme is set
     explicitly to "HTTP" or "HTTPS" → use that value as-is.
  2. Otherwise, delegate to boundary.controller.opsListenerTlsDisabled, which
     reads tls_disable directly from the ops listener block in controller.config.

Examples:
  - ops: tls_disable=false          → HTTPS (only case that means TLS is on)
  - ops: tls_disable=true           → HTTP
  - ops: no tls_disable param        → HTTP  (absent = disabled by default)
  - no ops block in config           → HTTP
*/}}
{{- define "boundary.controller.probeScheme" -}}
{{- $root := .root -}}
{{- $explicit := upper (trim (default "" .explicitScheme)) -}}
{{- if or (eq $explicit "HTTP") (eq $explicit "HTTPS") -}}
{{- $explicit -}}
{{- else if eq (include "boundary.controller.opsListenerTlsDisabled" $root | trim) "true" -}}
HTTP
{{- else -}}
HTTPS
{{- end -}}
{{- end }}

{{/*
Returns true when controller config uses env://BOUNDARY_PG_URL.
Commented lines are ignored.
*/}}
{{- define "boundary.controller.usesEnvDatabaseUrl" -}}
{{- $configNoComments := regexReplaceAll "(?m)^\\s*#.*$" .Values.controller.config "" -}}
{{- if regexMatch "url\\s*=\\s*\"env://BOUNDARY_PG_URL\"" $configNoComments -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Returns true when controller config uses env://BOUNDARY_LICENSE.
Commented lines are ignored.
*/}}
{{- define "boundary.controller.usesEnvLicense" -}}
{{- $configNoComments := regexReplaceAll "(?m)^\\s*#.*$" .Values.controller.config "" -}}
{{- if regexMatch "license\\s*=\\s*\"env://BOUNDARY_LICENSE\"" $configNoComments -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Returns true when controller config uses AEAD keys via env://BOUNDARY_KMS_*.
Commented lines are ignored.
*/}}
{{- define "boundary.controller.usesEnvAeadKms" -}}
{{- $configNoComments := regexReplaceAll "(?m)^\\s*#.*$" .Values.controller.config "" -}}
{{- if regexMatch "key\\s*=\\s*\"env://BOUNDARY_KMS_(ROOT|WORKER_AUTH|RECOVERY)\"" $configNoComments -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Returns true when controller config uses env://BOUNDARY_PG_MIGRATION_URL.
Commented lines are ignored.
*/}}
{{- define "boundary.controller.usesEnvMigrationUrl" -}}
{{- $configNoComments := regexReplaceAll "(?m)^\\s*#.*$" .Values.controller.config "" -}}
{{- if regexMatch "migration_url\\s*=\\s*\"env://BOUNDARY_PG_MIGRATION_URL\"" $configNoComments -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Validate migration and repair job settings.
*/}}
{{- define "boundary.controller.validateDatabaseJobs" -}}
{{- if and .Values.database.migrate.enabled (ne (int .Values.controller.replicas) 0) -}}
{{- fail "database.migrate.enabled=true requires controller.replicas=0. Scale controllers to zero before running the migration or repair job." -}}
{{- end -}}
{{- if and (ne (printf "%v" (default "" .Values.database.repair.version) | trim) "") (not .Values.database.migrate.enabled) -}}
{{- fail "database.repair.version is set but database.migrate.enabled is false. Enable database.migrate.enabled to run the repair job during pre-upgrade." -}}
{{- end -}}
{{- end }}

{{/*
Validate manual Secret existence and required keys.
Runs only when secretRefs.validateExisting=true.
*/}}
{{- define "boundary.controller.validateSecretRefs" -}}
{{- if .Values.secretRefs.validateExisting }}
{{- $secretName := include "boundary.controller.secretName" . | trim -}}
{{- if eq $secretName "" }}
{{- fail "secretRefs.secretName resolved to empty value" }}
{{- end }}
{{- $namespace := include "boundary.namespace" . | trim -}}
{{- $secret := lookup "v1" "Secret" $namespace $secretName -}}
{{- if not $secret }}
{{- fail (printf "Secret %q not found in namespace %q (set secretRefs.secretName or disable secretRefs.validateExisting)" $secretName $namespace) }}
{{- end }}
{{- $data := default dict (get $secret "data") -}}
{{- $requiredKeys := list -}}
{{- if eq (include "boundary.controller.usesEnvDatabaseUrl" . | trim) "true" -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.databaseUrl -}}
{{- end -}}
{{- if eq (include "boundary.controller.usesEnvLicense" . | trim) "true" -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.license -}}
{{- end -}}
{{- if eq (include "boundary.controller.usesEnvMigrationUrl" . | trim) "true" -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.migrationUrl -}}
{{- end -}}
{{- if .Values.bootstrapAdmin.enabled -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.adminUsername -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.adminPassword -}}
{{- end -}}
{{- if eq (include "boundary.controller.usesEnvAeadKms" . | trim) "true" -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.kmsRoot -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.kmsWorkerAuth -}}
{{- $requiredKeys = append $requiredKeys .Values.secretRefs.keys.kmsRecovery -}}
{{- end -}}
{{- range $key := $requiredKeys }}
{{- if eq (trim $key) "" }}
{{- fail "secretRefs.keys contains an empty key name" }}
{{- end }}
{{- if not (hasKey $data $key) }}
{{- fail (printf "Secret %q is missing required key %q" $secretName $key) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Validate controller config patterns that Boundary cannot resolve safely at runtime.
*/}}
{{- define "boundary.controller.validateConfig" -}}
{{- $renderedConfig := tpl .Values.controller.config . -}}
{{- $configNoComments := regexReplaceAll "(?m)^\\s*#.*$" $renderedConfig "" -}}
{{- if regexMatch "key\\s*=\\s*\"env://BOUNDARY_KMS_(ROOT|WORKER_AUTH|RECOVERY)\"" $configNoComments }}
{{- fail "controller.config uses env://BOUNDARY_KMS_* inside AEAD kms blocks. Boundary AEAD keys do not support env:// indirection. Use an external KMS stanza (recommended for production) or inline AEAD keys only for dev/testing." }}
{{- end }}
{{- if not .Values.tls.disabled }}
{{- $expectedCertPath := regexQuoteMeta (printf "%s/tls.crt" .Values.tls.mountPath) -}}
{{- $expectedKeyPath := regexQuoteMeta (printf "%s/tls.key" .Values.tls.mountPath) -}}
{{- if not (regexMatch (printf "tls_cert_file\\s*=\\s*[\"']%s[\"']" $expectedCertPath) $configNoComments) }}
{{- fail (printf "tls.disabled=false but controller.config is missing expected cert path %q. Keep listener tls_cert_file aligned with tls.mountPath." (printf "%s/tls.crt" .Values.tls.mountPath)) }}
{{- end }}
{{- if not (regexMatch (printf "tls_key_file\\s*=\\s*[\"']%s[\"']" $expectedKeyPath) $configNoComments) }}
{{- fail (printf "tls.disabled=false but controller.config is missing expected key path %q. Keep listener tls_key_file aligned with tls.mountPath." (printf "%s/tls.key" .Values.tls.mountPath)) }}
{{- end }}
{{- end }}
{{- end }}
