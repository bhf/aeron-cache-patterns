{{/*
Chart name.
*/}}
{{- define "aeroncache-ws-keyed-router.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. If the release name already contains the chart name it is used as-is, so
installing under the release "aeroncache-ws-keyed-router" yields a clean resource name.
*/}}
{{- define "aeroncache-ws-keyed-router.fullname" -}}
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

{{- define "aeroncache-ws-keyed-router.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "aeroncache-ws-keyed-router.labels" -}}
helm.sh/chart: {{ include "aeroncache-ws-keyed-router.chart" . }}
app.kubernetes.io/name: {{ include "aeroncache-ws-keyed-router.name" . }}
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
The nginx server-snippet that does the keyed routing. It adds one regex location over the ws subscribe
routes; inside it, a set_by_lua_block inspects the `keys` query parameter ($arg_keys) and chooses the
upstream Service — the keyed gateway when `keys` is non-empty, the stream gateway otherwise — then
proxies the ORIGINAL request URI (query string included, so the gateway still sees `keys`) to it. A
regex location wins over ingress-nginx's own prefix "location /", so subscribe traffic is keyed-routed
while anything else falls through to the default backend. proxy_pass uses a variable (the target is
only known per request), which is why a resolver is required. The WebSocket upgrade is carried through
and the connection kept open for a quiet subscription.
*/}}
{{- define "aeroncache-ws-keyed-router.serverSnippet" -}}
# --- aeroncache keyed routing: keys present -> keyed gateway, else -> stream gateway ---
resolver {{ .Values.resolver }} valid=10s ipv6=off;
location ~ {{ .Values.subscribePathRegex }} {
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout {{ .Values.readTimeout }}s;
    proxy_send_timeout {{ .Values.sendTimeout }}s;
    set_by_lua_block $ws_keyed_upstream {
        local keys = ngx.var.arg_keys
        if keys ~= nil and keys ~= "" then
            return "{{ .Values.keyed.service }}.{{ .Values.namespace }}.svc.cluster.local:{{ .Values.keyed.port }}"
        end
        return "{{ .Values.stream.service }}.{{ .Values.namespace }}.svc.cluster.local:{{ .Values.stream.port }}"
    }
    set_by_lua_block $ws_sub_type {
        local keys = ngx.var.arg_keys
        if keys ~= nil and keys ~= "" then return "keyed" end
        return "stream"
    }
    # Surface the chosen class to the client/gateway (handy for the verify and `curl -i` by hand).
    add_header X-Aeroncache-Sub-Type $ws_sub_type always;
    proxy_set_header X-Aeroncache-Sub-Type $ws_sub_type;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_pass http://$ws_keyed_upstream$request_uri;
}
{{- end }}
