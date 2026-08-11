# Vendored: VictoriaTraces (single-node)

| | |
|---|---|
| Component | VictoriaTraces 0.10.0 — single-node trace database (observability rework, [issue #57](https://github.com/randax/Platform-Engineering-Workshop/issues/57) — replaces otel-lgtm's Tempo) |
| Image | `docker.io/victoriametrics/victoria-traces:v0.10.0` — `sha256:66e784a595c4a88e5b1dfab5d153dea442cf1caaeae4d67839c550414c33b3b0` (crane, 2026-08-11; linux/amd64 + arm64 + arm + ppc64le — `linux/386` was dropped at 0.10.0) |
| Source | Official image, https://hub.docker.com/r/victoriametrics/victoria-traces · docs https://docs.victoriametrics.com/victoriatraces/ |
| Files | `victoria-traces.yaml` (PVC + Service + Deployment) |

## Why VictoriaTraces (chosen over Tempo)

Unifies the observability stack under one vendor — VictoriaMetrics + VictoriaLogs
+ **VictoriaTraces** — instead of bolting Grafana Tempo onto a Victoria stack.
It's built *on top of* VictoriaLogs internally (spans are stored as structured
logs), so it inherits the same lightweight single-node story.

It's new (v0.10.x), so the two workshop-critical risks are managed explicitly:

- **Offline** — pinned by digest (never `:latest`), on `scripts/images.txt`.
- **Grafana** — VictoriaTraces exposes a **Jaeger-compatible query API**, *not*
  Tempo/TraceQL. So Grafana queries it with the **built-in Jaeger datasource** —
  the one datasource in the stack that needs no plugin at all, unlike
  VictoriaMetrics and VictoriaLogs, whose native plugins are baked into
  `ghcr.io/randax/cloudbox-grafana` at build time (#65). There is **no**
  VictoriaTraces datasource in the Grafana plugin catalog at all — checked
  2026-08-11, `grafana.com/api/plugins?filter=victoria` returns only the metrics
  and logs datasources — so the built-in Jaeger type is not a preference, it is
  the only option. Baking one in stays a stretch goal on #57 for whenever
  upstream publishes and signs it.

## Config & curation

- **Listens on :10428** — one port for everything:
  - OTLP traces ingest → `POST /insert/opentelemetry/v1/traces` (the OTel
    Collector's `otlphttp/traces` exporter targets this).
  - Jaeger Query API → `GET /select/jaeger/api/*` — Grafana's Jaeger datasource
    URL is `http://victoria-traces.observability.svc.cluster.local:10428/select/jaeger`.
- **Data on a PVC** (`local-path`, 2 Gi) at `/victoria-traces-data`
  (`-storageDataPath`). `Prune=false` so disabling the app doesn't wipe traces
  mid-workshop — same protection as `victoria-logs` / `nats-jetstream`.
- **`-retentionPeriod=7d`** — a sandbox, not prod.
- **Deployment strategy `Recreate`**: the data PVC is ReadWriteOnce, so a rolling
  update (two pods briefly) would deadlock on the volume.
- **Security**: non-root (uid/gid 1000), all caps dropped, `readOnlyRootFilesystem`
  (VT only writes the mounted data path + `/tmp` emptyDir), `seccompProfile:
  RuntimeDefault`. `fsGroup` chowns the volume so no initContainer is needed
  (same as victoria-logs).
- **Resources**: requests 50m / 256Mi, limit 512Mi (single-tenant lab).
- **No shell in the image from 0.10.0 on** — upstream moved the base from Alpine
  to distroless (which is also why the image shrank 47.6 MB → 40.2 MB). Nothing
  in this repo `exec`s into VictoriaTraces, but a live-debugging moment now needs
  `kubectl debug` instead of `kubectl exec … -- sh`. Same story as victoria-logs;
  VictoriaMetrics is still Alpine.

## Re-vendor

Bump the tag, then re-resolve the digest:

```sh
mise x crane@0.21.9 -- crane digest docker.io/victoriametrics/victoria-traces:v0.10.0
```

VictoriaTraces is pre-1.0, so a minor bump can break things — this is a
hand-written component and the re-pin is verified the same way victoria-logs is:
diff the new binary's flag list against the old (`docker run --rm --entrypoint
/victoria-traces-prod …:v0.10.0 --help`), boot it with our exact args under the
same hardening, then POST an OTLP trace and read it back through
`/select/jaeger/api/{services,traces}`. 0.9.4 → 0.10.0: zero flags removed, two
added (`-search.fieldsLookbehind`, `-search.streamFieldsLookbehind`), and
`-search.traceServiceAndSpanNameLookbehind` deprecated in favour of those two —
we set none of the three, and the 72h default is unchanged, so `/api/services`
behaves identically. The round-tripped span payload is identical on both
versions.

Keep the `image:` in `victoria-traces.yaml` and the entry in `scripts/images.txt`
in lockstep (`check-consistency.sh` enforces it).
