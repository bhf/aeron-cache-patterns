{{/*
Chart name.
*/}}
{{- define "aeroncache-hash-router.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. If the release name already contains the chart name it is used as-is, so
installing under the release "aeroncache-hash-router" yields a clean resource name.
*/}}
{{- define "aeroncache-hash-router.fullname" -}}
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

{{- define "aeroncache-hash-router.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "aeroncache-hash-router.labels" -}}
helm.sh/chart: {{ include "aeroncache-hash-router.chart" . }}
app.kubernetes.io/name: {{ include "aeroncache-hash-router.name" . }}
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
The nginx server-snippet that does the hash routing. It adds one regex location that:
  - captures the cache id from /api/v1/cache/<id>(/...)  (named capture -> $cache_id)
  - computes the shard with the standard CRC-32 (ngx.crc32_long matches zlib/python zlib.crc32)
    modulo shardCount
  - proxies the ORIGINAL request URI to <readRelease>-<shard>.<namespace>.svc:<readPort>
A regex location wins over ingress-nginx's own prefix "location /", so cache traffic is hashed while
anything else falls through to the default backend. proxy_pass uses a variable (the shard is only
known per-request), which is why a resolver is required.
*/}}
{{- define "aeroncache-hash-router.serverSnippet" -}}
# --- aeroncache hash routing: shard = crc32(cacheId) % {{ .Values.shardCount }} ---
resolver {{ .Values.resolver }} valid=10s ipv6=off;
location ~ ^/api/v1/cache/(?<cache_id>[^/]+) {
    set_by_lua_block $cache_shard {
        local id = ngx.var.cache_id or ""
        if id == "" then return "0" end
        return tostring(ngx.crc32_long(id) % {{ .Values.shardCount }})
    }
    set $cache_upstream {{ .Values.readRelease }}-$cache_shard.{{ .Values.namespace }}.svc.cluster.local:{{ .Values.readPort }};
    # Surface the chosen shard to the client (response) and the gateway (request) — handy for the
    # verify and for `curl -i` by hand. `always` so it is set even on error responses.
    add_header X-Aeroncache-Shard $cache_shard always;
    proxy_set_header X-Aeroncache-Shard $cache_shard;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://$cache_upstream$request_uri;
}
{{- end }}
