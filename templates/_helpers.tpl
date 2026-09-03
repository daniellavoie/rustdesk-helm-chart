{{/* Chart name, overridable. */}}
{{- define "rustdesk-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rustdesk-server.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "rustdesk-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rustdesk-server.labels" -}}
helm.sh/chart: {{ include "rustdesk-server.chart" . }}
{{ include "rustdesk-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rustdesk-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rustdesk-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Per-role names and labels. Call with (dict "ctx" $ "role" "hbbs"). */}}
{{- define "rustdesk-server.roleFullname" -}}
{{- printf "%s-%s" (include "rustdesk-server.fullname" .ctx) .role | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rustdesk-server.roleLabels" -}}
{{ include "rustdesk-server.labels" .ctx }}
app.kubernetes.io/component: {{ .role }}
{{- end }}

{{- define "rustdesk-server.roleSelectorLabels" -}}
{{ include "rustdesk-server.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .role }}
{{- end }}

{{/* Images. Tags default to appVersion so the utility image always matches the server. */}}
{{- define "rustdesk-server.image" -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "rustdesk-server.utilsImage" -}}
{{- printf "%s/%s:%s" .Values.utilsImage.registry .Values.utilsImage.repository (default .Chart.AppVersion .Values.utilsImage.tag) }}
{{- end }}

{{- define "rustdesk-server.kubectlImage" -}}
{{- printf "%s/%s:%s" .Values.kubectlImage.registry .Values.kubectlImage.repository .Values.kubectlImage.tag }}
{{- end }}

{{/* The Secret holding the key pair. It is authoritative; the volume is a cache of it. */}}
{{- define "rustdesk-server.keySecretName" -}}
{{- if .Values.key.existingSecret }}
{{- .Values.key.existingSecret }}
{{- else }}
{{- default (printf "%s-key" (include "rustdesk-server.fullname" .)) .Values.key.secretName }}
{{- end }}
{{- end }}

{{- define "rustdesk-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rustdesk-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Whether the chart must generate a key pair. It must not when the user brought their own,
and it need not when a key Secret already exists — which is what makes reinstalling over a
surviving Secret work, and is why enrolled clients keep working across a full uninstall.
`lookup` returns empty during `helm template` and dry runs, so the hook renders there; that
is harmless because nothing applies it.
*/}}
{{- define "rustdesk-server.shouldGenerateKey" -}}
{{- if or .Values.key.existingSecret (not .Values.hbbs.enabled) }}
{{- else if (lookup "v1" "Secret" .Release.Namespace (include "rustdesk-server.keySecretName" .)) }}
{{- else }}
{{- true }}
{{- end }}
{{- end }}

{{/* Derived ports. hbbs computes these in code from its base port; we must not diverge. */}}
{{- define "rustdesk-server.hbbs.natTestPort" -}}{{ sub (int .Values.hbbs.port) 1 }}{{- end }}
{{- define "rustdesk-server.hbbs.wsPort" -}}{{ add (int .Values.hbbs.port) 2 }}{{- end }}
{{- define "rustdesk-server.hbbr.wsPort" -}}{{ add (int .Values.hbbr.port) 2 }}{{- end }}

{{- define "rustdesk-server.hbbs.pvcName" -}}
{{- if .Values.hbbs.persistence.existingClaim }}
{{- .Values.hbbs.persistence.existingClaim }}
{{- else }}
{{- printf "%s-data" (include "rustdesk-server.roleFullname" (dict "ctx" . "role" "hbbs")) }}
{{- end }}
{{- end }}

{{/*
Where hbbr gets the public key for relay validation.

hbbr only ever holds the PUBLIC half: it compares an opaque string and performs no signature
verification or decryption, so the private key never leaves the hbbs pod. When the key comes
from a Secret, the reference is deliberately NOT optional — a missing Secret must hold the pod
in CreateContainerConfigError rather than start an unvalidated relay open to the internet.
*/}}
{{- define "rustdesk-server.hbbr.keyEnv" -}}
{{- if .Values.hbbr.key.validation }}
{{- if .Values.hbbr.key.publicKey }}
- name: KEY
  value: {{ .Values.hbbr.key.publicKey | quote }}
{{- else if .Values.hbbr.key.existingSecret }}
- name: KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.hbbr.key.existingSecret }}
      key: {{ .Values.hbbr.key.existingSecretKey }}
{{- else if .Values.hbbs.enabled }}
- name: KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "rustdesk-server.keySecretName" . }}
      key: {{ .Values.key.publicKeyKey }}
{{- else }}
{{- fail "hbbr.key.validation is enabled but no public key is available: this is a relay-only release (hbbs.enabled=false), so set hbbr.key.publicKey or hbbr.key.existingSecret to the installation's public key. Set hbbr.key.validation=false only if you intend to run a relay open to anyone who knows its address." }}
{{- end }}
{{- end }}
{{- end }}
