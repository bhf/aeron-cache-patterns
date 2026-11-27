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
The body of a hash-routing location: hash $cache_id (set by the enclosing location's named capture) to
a shard with the standard CRC-32 (ngx.crc32_long matches zlib / python zlib.crc32) modulo shardCount,
then proxy the ORIGINAL request URI to <release>-<shard>.<namespace>.svc:<port>. proxy_pass uses a
variable (the shard is only known per-request), which is why a resolver is required. Connection and any
interface-specific tuning (buffering, timeouts, Upgrade) are set by the caller, before this block.
Call with a dict: (dict "release" <stem> "port" <port> "root" $).
*/}}
{{- define "aeroncache-hash-router.shardProxy" -}}
{{- $ := .root -}}
set_by_lua_block $cache_shard {
    local id = ngx.var.cache_id or ""
    if id == "" then return "0" end
    return tostring(ngx.crc32_long(id) % {{ $.Values.shardCount }})
}
set $cache_upstream {{ .release }}-$cache_shard.{{ $.Values.namespace }}.svc.cluster.local:{{ .port }};
# Surface the chosen shard to the client (response) and the gateway (request) — handy for the verify
# and for `curl -i` by hand. `always` so it is set even on error responses.
add_header X-Aeroncache-Shard $cache_shard always;
proxy_set_header X-Aeroncache-Shard $cache_shard;
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_pass http://$cache_upstream$request_uri;
{{- end }}

{{/*
The nginx server-snippet that does the hash routing. It adds regex location(s) that capture the cache
id from the request path, hash it to a shard, and proxy to the gateway that owns that shard. A regex
location wins over ingress-nginx's own prefix "location /", so cache traffic is hashed while anything
else falls through to the default backend. Shapes per interface:
  http : one location  — /api/v1/cache/<id>            -> readRelease  (reads + writes)
  sse  : two locations — /api/sse/v1/cache/[hydrate/]<id> -> readRelease (sse, read-only), and
                         /api/v1/cache/<id>             -> writeRelease (the http writer on the SAME shard)
  ws   : two locations — /api/ws/v1/cache/<id>          -> readRelease (ws subscribe), and
                         /api/v1/cache/<id>             -> writeRelease (the http writer on the SAME shard)
Reads and writes for a given id hash identically, so they share one backend. The bidi ws endpoint
carries the id in the frame (not the path), so it is intentionally not routed here.
*/}}
{{- define "aeroncache-hash-router.serverSnippet" -}}
{{- $ := . -}}
{{- $read := dict "release" .Values.readRelease "port" .Values.readPort "root" $ -}}
{{- $write := dict "release" .Values.writeRelease "port" .Values.writePort "root" $ -}}
# --- aeroncache hash routing: shard = crc32(cacheId) % {{ .Values.shardCount }} ---
resolver {{ .Values.resolver }} valid=10s ipv6=off;
{{- if eq .Values.interface "http" }}
# http serves both reads and writes on /api/v1/cache/<id>.
location ~ ^/api/v1/cache/(?<cache_id>[^/]+) {
    proxy_set_header Connection "";
    {{- include "aeroncache-hash-router.shardProxy" $read | nindent 4 }}
}
{{- else if eq .Values.interface "sse" }}
# read: routed SSE subscribe/hydrate -> the sse gateway on the id's shard. SSE is a long-lived event
# stream, so nginx must not buffer it and must not time the upstream out.
location ~ ^/api/sse/v1/cache/(?:hydrate/)?(?<cache_id>[^/]+) {
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_set_header Connection "";
    {{- include "aeroncache-hash-router.shardProxy" $read | nindent 4 }}
}
# write: SSE is read-only, so writes go to the http writer on the SAME shard.
location ~ ^/api/v1/cache/(?<cache_id>[^/]+) {
    proxy_set_header Connection "";
    {{- include "aeroncache-hash-router.shardProxy" $write | nindent 4 }}
}
{{- else if eq .Values.interface "ws" }}
# read: routed WS subscribe -> the ws gateway on the id's shard. Carry the upgrade through and keep the
# connection open for a quiet subscription.
location ~ ^/api/ws/v1/cache/(?<cache_id>[^/]+) {
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    {{- include "aeroncache-hash-router.shardProxy" $read | nindent 4 }}
}
# write: the subscribe route is read-only, so writes go to the http writer on the SAME shard.
location ~ ^/api/v1/cache/(?<cache_id>[^/]+) {
    proxy_set_header Connection "";
    {{- include "aeroncache-hash-router.shardProxy" $write | nindent 4 }}
}
{{- else }}
{{- fail (printf "aeroncache-hash-router: interface must be http|sse|ws, got %q" .Values.interface) }}
{{- end }}
{{- end }}
