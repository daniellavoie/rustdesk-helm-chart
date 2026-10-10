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

{{/*
The relay list passed to hbbs with -r. An explicit list always wins. Otherwise, when hbbr is
on a tailnet whose DNS suffix is known, hbbr's tailnet name is predictable from its hostname,
so the relay can be set at install time: hbbs and hbbr are separate tailnet nodes, which
breaks the client-side `<ID server host>:<port + 1>` derivation (ADR-0005). hbbs never
resolves this name; it passes it to clients, which resolve it through Tailscale DNS.
*/}}
{{- define "rustdesk-server.hbbs.relayServers" -}}
{{- if .Values.hbbs.config.relayServers }}
{{- join "," .Values.hbbs.config.relayServers }}
{{- else if and .Values.tailscale.magicDNSDomain (include "rustdesk-server.tailscale.enabled" (dict "ctx" . "role" "hbbr")) }}
{{- printf "%s.%s:%d" (include "rustdesk-server.tailscale.hostname" (dict "ctx" . "role" "hbbr")) .Values.tailscale.magicDNSDomain (int .Values.hbbr.port) }}
{{- end }}
{{- end }}

{{/* A role's tailnet name, when the tailnet's DNS suffix is known. Empty otherwise. */}}
{{- define "rustdesk-server.tailscale.fqdn" -}}
{{- if .ctx.Values.tailscale.magicDNSDomain }}
{{- printf "%s.%s" (include "rustdesk-server.tailscale.hostname" .) .ctx.Values.tailscale.magicDNSDomain }}
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

{{/*
Tailscale sidecar. A role gets one only when its own pre-auth key Secret is referenced.
Call the role helpers with (dict "ctx" $ "role" "hbbs").
*/}}
{{- define "rustdesk-server.tailscale.enabled" -}}
{{- $cfg := index .ctx.Values .role }}
{{- if and $cfg.enabled $cfg.tailscale.authKey.existingSecret }}true{{- end }}
{{- end }}

{{/* Whether any role in the release runs a sidecar. */}}
{{- define "rustdesk-server.tailscale.any" -}}
{{- if or (include "rustdesk-server.tailscale.enabled" (dict "ctx" . "role" "hbbs")) (include "rustdesk-server.tailscale.enabled" (dict "ctx" . "role" "hbbr")) }}true{{- end }}
{{- end }}

{{- define "rustdesk-server.tailscale.hostname" -}}
{{- $cfg := index .ctx.Values .role }}
{{- default (include "rustdesk-server.roleFullname" .) $cfg.tailscale.hostname }}
{{- end }}

{{/* Where tailscaled keeps its node state. Created by the chart, written by tailscaled. */}}
{{- define "rustdesk-server.tailscale.stateSecretName" -}}
{{- printf "%s-tailscale-state" (include "rustdesk-server.roleFullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rustdesk-server.tailscale.serviceAccountName" -}}
{{- printf "%s-tailscale" (include "rustdesk-server.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rustdesk-server.tailscale.image" -}}
{{- printf "%s/%s:%s" .Values.tailscale.image.registry .Values.tailscale.image.repository .Values.tailscale.image.tag }}
{{- end }}

{{/*
A release is either entirely on the tailnet or not at all. With only hbbs on it, clients
reach the ID server but derive a relay address that does not exist, and the failure shows
up much later as relayed sessions that never connect.
*/}}
{{- define "rustdesk-server.tailscale.validate" -}}
{{- $on := list }}
{{- $off := list }}
{{- range $role := (list "hbbs" "hbbr") }}
{{- $cfg := index $.Values $role }}
{{- if $cfg.enabled }}
{{- if $cfg.tailscale.authKey.existingSecret }}
{{- $on = append $on $role }}
{{- if $cfg.hostNetwork }}
{{- fail (printf "%s.tailscale and %s.hostNetwork cannot be combined: the sidecar would install routes and a tun device in the node's own network namespace." $role $role) }}
{{- end }}
{{- else }}
{{- $off = append $off $role }}
{{- end }}
{{- end }}
{{- end }}
{{- if and $on $off }}
{{- fail (printf "Tailscale is configured for %s but not for %s. Set %s.tailscale.authKey.existingSecret too: a release must be on the tailnet entirely or not at all." (join ", " $on) (join ", " $off) (join ", " $off)) }}
{{- end }}
{{- end }}

{{/*
The sidecar container. Kernel networking, not userspace: in userspace mode every tailnet
connection reaches hbbs from 127.0.0.1, and hbbs records the observed source as the peer's
endpoint for hole punching. With a tun device the real tailnet address arrives intact,
which is the whole point of running the sidecar rather than routing in through a subnet
router that SNATs.
*/}}
{{- define "rustdesk-server.tailscale.container" -}}
{{- $cfg := index .ctx.Values .role }}
{{- $ts := .ctx.Values.tailscale }}
{{- $args := list }}
{{- if $ts.loginServer }}
{{- $args = append $args (printf "--login-server=%s" $ts.loginServer) }}
{{- end }}
{{- $args = concat $args $ts.extraArgs }}
- name: tailscale
  image: {{ include "rustdesk-server.tailscale.image" .ctx }}
  imagePullPolicy: {{ $ts.image.pullPolicy }}
  env:
    {{- /* Not optional: a missing Secret holds the pod rather than starting it off the tailnet. */}}
    - name: TS_AUTHKEY
      valueFrom:
        secretKeyRef:
          name: {{ $cfg.tailscale.authKey.existingSecret }}
          key: {{ $cfg.tailscale.authKey.key }}
    {{- /* Use the key only when there is no saved login, so a restart never re-registers. */}}
    - name: TS_AUTH_ONCE
      value: "true"
    - name: TS_HOSTNAME
      value: {{ include "rustdesk-server.tailscale.hostname" . | quote }}
    - name: TS_KUBE_SECRET
      value: {{ include "rustdesk-server.tailscale.stateSecretName" . }}
    - name: TS_USERSPACE
      value: "false"
    {{- /* The pod resolves through cluster DNS; MagicDNS would replace its resolv.conf. */}}
    - name: TS_ACCEPT_DNS
      value: "false"
    {{- /* Lets tailscaled attach its Events to this pod. */}}
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    {{- with $args }}
    - name: TS_EXTRA_ARGS
      value: {{ join " " . | quote }}
    {{- end }}
  {{- /* Privileged by default; see tailscale.securityContext. The RustDesk containers are untouched. */}}
  {{- with $ts.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $ts.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: tailscale-tmp
      mountPath: /tmp
    - name: tailscale-run
      mountPath: /var/run/tailscale
    - name: tailscale-state
      mountPath: /var/lib/tailscale
    {{- /* The API token reaches this container only; the RustDesk containers get none. */}}
    - name: tailscale-sa-token
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
{{- end }}

{{- define "rustdesk-server.tailscale.volumes" -}}
- name: tailscale-tmp
  emptyDir: {}
- name: tailscale-run
  emptyDir: {}
- name: tailscale-state
  emptyDir: {}
- name: tailscale-sa-token
  projected:
    sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items:
            - key: ca.crt
              path: ca.crt
      - downwardAPI:
          items:
            - path: namespace
              fieldRef:
                fieldPath: metadata.namespace
{{- end }}
