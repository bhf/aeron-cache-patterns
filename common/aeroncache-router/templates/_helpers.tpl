{{/*
Chart name.
*/}}
{{- define "aeroncache-router.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. If the release name already contains the chart name it is used as-is, so
installing under the release "aeroncache-router" yields a clean resource name.
*/}}
{{- define "aeroncache-router.fullname" -}}
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

{{- define "aeroncache-router.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "aeroncache-router.labels" -}}
helm.sh/chart: {{ include "aeroncache-router.chart" . }}
app.kubernetes.io/name: {{ include "aeroncache-router.name" . }}
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
Ingress path rules, one block per route (cache id -> instance). The cache id appears in the request
path, so each rule matches that id (anchored with (/|$) so "alpha" never also matches "alphabet", and
"(.*)" so "/alpha/<key>" still routes). use-regex: "true" (set on the Ingress) enables the regex.

  http : one rule   -> the http gateway serves both reads and writes on /api/v1/cache/<id>
  sse  : two rules  -> SSE reads on /api/sse/v1/cache/[hydrate/]<id> to the sse gateway,
                       plus writes on /api/v1/cache/<id> to the http writer (sse is read-only)
  ws   : two rules  -> WS subscribe on /api/ws/v1/cache/<id> to the ws gateway,
                       plus writes on /api/v1/cache/<id> to the http writer (the bidi endpoint carries
                       the cache id in the frame, not the URL, so it is intentionally not routed here)
*/}}
{{- define "aeroncache-router.paths" -}}
{{- $top := . -}}
{{- range $r := .Values.routes }}
{{- $readSvc := printf "%s-%v" $top.Values.readRelease $r.instance }}
{{- $writeSvc := printf "%s-%v" $top.Values.writeRelease $r.instance }}
{{- if eq $top.Values.interface "http" }}
- path: "/api/v1/cache/{{ $r.cacheId }}(/|$)(.*)"
  pathType: ImplementationSpecific
  backend:
    service:
      name: {{ $readSvc }}
      port:
        number: {{ $top.Values.readPort }}
{{- else if eq $top.Values.interface "sse" }}
- path: "/api/sse/v1/cache/(hydrate/)?{{ $r.cacheId }}(/|$)(.*)"
  pathType: ImplementationSpecific
  backend:
    service:
      name: {{ $readSvc }}
      port:
        number: {{ $top.Values.readPort }}
- path: "/api/v1/cache/{{ $r.cacheId }}(/|$)(.*)"
  pathType: ImplementationSpecific
  backend:
    service:
      name: {{ $writeSvc }}
      port:
        number: {{ $top.Values.writePort }}
{{- else if eq $top.Values.interface "ws" }}
- path: "/api/ws/v1/cache/{{ $r.cacheId }}(/|$)(.*)"
  pathType: ImplementationSpecific
  backend:
    service:
      name: {{ $readSvc }}
      port:
        number: {{ $top.Values.readPort }}
- path: "/api/v1/cache/{{ $r.cacheId }}(/|$)(.*)"
  pathType: ImplementationSpecific
  backend:
    service:
      name: {{ $writeSvc }}
      port:
        number: {{ $top.Values.writePort }}
{{- else }}
{{- fail (printf "aeroncache-router: interface must be http|sse|ws, got %q" $top.Values.interface) }}
{{- end }}
{{- end }}
{{- end }}
