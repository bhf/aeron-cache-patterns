# Local chart patches

These vendored charts carry a small local patch on top of the upstream copy recorded in `VENDOR.lock`.
Re-running `scripts/sync-charts.sh` overwrites chart contents, so re-apply this afterwards (or drop it
once upstream ships the change).

## aeroncache-sse — release-aware resource names

Upstream's `aeroncache-sse` chart hardcodes `fullnameOverride: "aeroncache-sse"`,
`serviceAccount.name: "aeroncache-sse"` and the ConfigMap name `aeroncache-sse-config`, so two installs
in one namespace collide on those resource names. This pattern fans the sse gateway out into per-instance
releases (`aeroncache-sse-0`, `aeroncache-sse-1`, …), so the chart is patched to be **release-aware** —
exactly like the upstream `aeroncache-http` / `aeroncache-cluster` / `aeroncache-ephemeral` charts
already are:

- `values.yaml`: `fullnameOverride: ""`, `serviceAccount.name: ""`, `aeroncacheWSConfigmap: ""`
- `templates/_helpers.tpl`: add a `aeroncache-sse.configmapName` helper defaulting to `<fullname>-config`
- `templates/configmap.yaml` and `templates/deployment.yaml`: reference that helper for the ConfigMap name

Every resource name then derives from the Helm release name, so per-instance releases don't collide.
Drop this patch once upstream makes the chart release-aware (bhf/aeron-cache #305).
