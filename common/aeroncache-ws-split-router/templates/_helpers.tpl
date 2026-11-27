{{/*
Chart name.
*/}}
{{- define "aeroncache-ws-split-router.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. If the release name already contains the chart name it is used as-is, so
installing under the release "aeroncache-ws-split-router" yields a clean resource name.
*/}}
{{- define "aeroncache-ws-split-router.fullname" -}}
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

{{- define "aeroncache-ws-split-router.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "aeroncache-ws-split-router.labels" -}}
helm.sh/chart: {{ include "aeroncache-ws-split-router.chart" . }}
app.kubernetes.io/name: {{ include "aeroncache-ws-split-router.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: aeroncache
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- with .Values.extraLabels }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/*
Ingress path rules: one prefix per endpoint role. Both use pathType: Prefix (no regex), and the two
prefixes are disjoint, so ingress-nginx's longest-prefix match sends each endpoint to its gateway:

  /api/ws/v1/bidi           -> bidi gateway   (read-write command channel)
  /api/ws/v1/cache[/...]    -> stream gateway (plain subscribe + hydrate; "with or without hydration")
*/}}
{{- define "aeroncache-ws-split-router.paths" -}}
- path: {{ .Values.bidi.path | quote }}
  pathType: Prefix
  backend:
    service:
      name: {{ .Values.bidi.service }}
      port:
        number: {{ .Values.bidi.port }}
- path: {{ .Values.stream.path | quote }}
  pathType: Prefix
  backend:
    service:
      name: {{ .Values.stream.service }}
      port:
        number: {{ .Values.stream.port }}
{{- end }}
