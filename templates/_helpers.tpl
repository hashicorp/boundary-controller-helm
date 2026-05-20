{{/*
Expand the name of the chart.
*/}}
{{- define "boundary.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
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
{{- if .Values.serviceAccount.create }}
{{- default (include "boundary.controller.serviceName" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
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
{{- /* No-op: repair trigger is inferred from migrate.enabled + non-empty repair.version. */ -}}
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
{{- $requiredKeys := list .Values.secretRefs.keys.databaseUrl .Values.secretRefs.keys.license -}}
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
{{- $expectedCert := printf "tls_cert_file = \"%s/tls.crt\"" .Values.tls.mountPath -}}
{{- $expectedKey := printf "tls_key_file  = \"%s/tls.key\"" .Values.tls.mountPath -}}
{{- if not (contains $expectedCert $configNoComments) }}
{{- fail (printf "tls.disabled=false but controller.config is missing expected cert path %q. Keep listener tls_cert_file aligned with tls.mountPath." (printf "%s/tls.crt" .Values.tls.mountPath)) }}
{{- end }}
{{- if not (contains $expectedKey $configNoComments) }}
{{- fail (printf "tls.disabled=false but controller.config is missing expected key path %q. Keep listener tls_key_file aligned with tls.mountPath." (printf "%s/tls.key" .Values.tls.mountPath)) }}
{{- end }}
{{- end }}
{{- end }}