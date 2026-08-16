# Vendored: knative-eventing

| | |
|---|---|
| Source | https://github.com/knative/eventing |
| Version | **knative-v1.23.0** for all four files (verified 2026-07-14). Same version as the vendored knative-serving — at 1.23.0 the two releases finally line up (1.22.x had eventing one patch ahead of serving). |
| Files | `eventing-crds.yaml`, `eventing-core.yaml`, `in-memory-channel.yaml`, `mt-channel-broker.yaml` |

## Re-vendor

The recipe lives **once**, in the `curation` block further down this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy of
itself. Re-vendoring is: reproduce the file with that recipe, re-apply the
curation below, then `./scripts/check-vendor-drift.sh --only knative-eventing`.

## Workshop curation applied (re-apply after re-vendoring)

This list is **complete and mechanically verified**: `diff <pristine-upstream>
<vendored>` produces nothing outside the items below. `eventing-crds.yaml`
carries **no** curation — it is byte-identical to upstream. Re-verify the same
way after every re-vendor.

1. **Halved every Deployment container's cpu/memory *requests*** in
   `eventing-core.yaml` and `mt-channel-broker.yaml` (limits untouched) —
   same k0s-blog small-cluster pattern as knative-serving. Resulting
   requests: eventing-controller 50m/50Mi, job-sink 62m/32Mi,
   pingsource-mt-adapter 62m/32Mi, eventing-webhook 50m/25Mi,
   mt-broker-filter + mt-broker-ingress + mt-broker-controller 50m/50Mi.
   `in-memory-channel.yaml` ships no requests upstream — **added 25m/32Mi
   requests to imc-controller and imc-dispatcher** (no limits) so the
   scheduler accounts for them. `request-reply` ships no requests either.
2. **`config-observability` (in `eventing-core.yaml`)**: six real config
   keys wiring eventing's own telemetry to the OTel Collector (#65).
   **A literal re-vendor silently drops all six** — everything inside
   `_example` is inert documentation — and the capstone's trace waterfall
   then breaks apart at the async Broker hop:

   | key | value |
   |---|---|
   | `tracing-protocol` | `http/protobuf` |
   | `tracing-endpoint` | `http://otel-collector.observability.svc.cluster.local:4318/v1/traces` |
   | `tracing-sampling-rate` | `1` |
   | `metrics-protocol` | `http/protobuf` |
   | `metrics-endpoint` | `http://otel-collector.observability.svc.cluster.local:4318/v1/metrics` |
   | `metrics-export-interval` | `60s` |

   Tracing is what makes the Broker hop its own span *and*
   propagates `traceparent` across the async event hop, so
   uploader → resizer stays ONE connected trace and forms a service-graph
   edge. The endpoints are the current collector, not the removed otel-lgtm
   `jaeger-collector` the `_example` still names.

Those are the only curations: no images repointed, no services exposed —
eventing is control-plane + in-cluster data-plane only (the Broker ingress
is `broker-ingress.knative-eventing.svc.cluster.local`, ClusterIP).

### The same list, machine-readable

`scripts/check-vendor-drift.sh` reproduces the pristine upstream artifact from
the `render` recipe below and diffs it against the vendored file. Every hunk
needs an `allow` line here: an unlisted hunk fails (undocumented curation, or
upstream moved under us) and an `allow` line whose hunk has **disappeared**
fails too — that is a curation lost in a re-vendor, which is exactly how these
docs went wrong before. The prose above is the *why*; these lines are only the
bookkeeping that keeps the prose honest. `--update` rewrites the ids; you still
write the label.

```curation
render eventing-crds.yaml
fetch  https://github.com/knative/eventing/releases/download/knative-v1.23.0/eventing-crds.yaml

render eventing-core.yaml
fetch  https://github.com/knative/eventing/releases/download/knative-v1.23.0/eventing-core.yaml

render in-memory-channel.yaml
fetch  https://github.com/knative/eventing/releases/download/knative-v1.23.0/in-memory-channel.yaml

render mt-channel-broker.yaml
fetch  https://github.com/knative/eventing/releases/download/knative-v1.23.0/mt-channel-broker.yaml

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  eventing-core.yaml  eedd7191  curation 2 — the six real config-observability keys pointing eventing telemetry at the OTel Collector (a literal re-vendor silently drops all six)
allow  eventing-core.yaml  02de06f1  curation 1 — halved requests 100m/100Mi → 50m/50Mi (eventing-controller, mt-broker-*)
allow  eventing-core.yaml  3dd1e004  curation 1 — halved requests 125m/64Mi → 62m/32Mi (job-sink, pingsource-mt-adapter)
allow  eventing-core.yaml  bbd482a6  curation 1 — halved requests 100m/50Mi → 50m/25Mi (eventing-webhook)
allow  in-memory-channel.yaml  1ae27e05  curation 1 — added 25m/32Mi requests to imc-controller and imc-dispatcher (upstream ships none)
allow  mt-channel-broker.yaml  02de06f1  curation 1 — halved requests 100m/100Mi → 50m/50Mi (mt-broker-filter/-ingress/-controller)
```

## Images (all upstream digest-pinned; verified pullable via crane 2026-07-14)

All `gcr.io/knative-releases/knative.dev/eventing/cmd/...@sha256:...` —
must be in the pre-pull list (`scripts/images.txt`):

- `.../cmd/controller@sha256:dd385d5632b8ce1a49c45421a3a11db91837c8fb12ea56c7ebde4f9aad2e825c` (eventing-controller)
- `.../cmd/webhook@sha256:3f6dfc52cfaf0b5a8e0c098f83f60eb237d3b8bfbbd4d0faea7c08fad98a1215` (eventing-webhook)
- `.../cmd/jobsink@sha256:bb9777c85adbf4238e60f9e99f236cc9224b92baaa68a115867e88d086eede1f` (job-sink)
- `.../cmd/mtping@sha256:2fc8713fb4807df0f5d8f9506d03c16c168eed61f19c04e04092266248bd0353` (pingsource-mt-adapter)
- `.../cmd/requestreply@sha256:0e9e6d121e9bcd57b01beb33124bb5387b70d4820caebe326264db92db1e1336` (request-reply)
- `.../cmd/in_memory/channel_controller@sha256:4cf6f399bc42a3a36676d62f3a684a07a88948a6de4a1b7a377c44116696707b` (imc-controller)
- `.../cmd/in_memory/channel_dispatcher@sha256:950eb883f04cd6f0329757cb200c180d0f1bbebc436c6eb9135138be633b3ae5` (imc-dispatcher)
- `.../cmd/broker/filter@sha256:d7bb470ad790a9460c9a6b526d73a9b87a16ab9b94094745bc59a97507f0f466` (mt-broker-filter)
- `.../cmd/broker/ingress@sha256:d5bfc081eb9dccb47eb15f9971f0b3d8a24d0224573315a46d4afd87074b84ab` (mt-broker-ingress)
- `.../cmd/mtchannel_broker@sha256:e600b78ee63225b3ab905fc3daf1f73772e8756b26ca5ace26fbaf4d81d3f8e5` (mt-broker-controller)

Notes:
- `eventing-core.yaml` includes the CRDs too; applying crds+core is
  upstream's documented flow and idempotent under server-side apply.
- `config-br-defaults` (eventing-core) already defaults
  `brokerClass: MTChannelBasedBroker` + in-memory channel, so a bare
  `Broker` works; picture-pipeline still sets the
  `eventing.knative.dev/broker.class: MTChannelBasedBroker` annotation
  explicitly for teachability.
- The in-memory channel is **not durable** (dispatcher restart loses
  in-flight events) — deliberate for the workshop; Kafka is out of scope.
- HPAs ship for eventing-webhook, broker-ingress, broker-filter
  (min 1) — harmless without metrics-server; they just report Unknown.
