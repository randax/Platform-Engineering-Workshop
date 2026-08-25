# Vendored: knative-serving (+ Kourier)

| | |
|---|---|
| Source | https://github.com/knative/serving + https://github.com/knative-extensions/net-kourier |
| Version | **knative-v1.23.0** for all three files (serving + net-kourier; verified 2026-07-13) |
| Files | `serving-crds.yaml`, `serving-core.yaml`, `kourier.yaml` |

## Re-vendor

The recipe lives **once**, in the `curation` block further down this file —
`scripts/check-vendor-drift.sh` runs it, so it cannot rot into a stale copy of
itself. Re-vendoring is: reproduce the file with that recipe, re-apply the
curation below, then `./scripts/check-vendor-drift.sh --only knative-serving`.

## Workshop curation applied (re-apply after re-vendoring)

This list is **complete and mechanically verified**: `diff <pristine-upstream>
<vendored>` produces nothing outside the items below. `serving-crds.yaml`
carries **no** curation — it is byte-identical to upstream. Re-verify the same
way after every re-vendor; anything in the diff that is not on this list is
either a new upstream change or a curation someone forgot to write down.

### `serving-core.yaml`

1. **Halved every Deployment container's cpu/memory *requests*** (limits
   untouched) — the k0s-blog small-cluster pattern; drops idle footprint to
   ~0.6 GiB. Script used (state-machine over `requests:` blocks): halve
   `NNNm`/`NNNMi` quantities. Resulting requests: activator 150m/30Mi,
   autoscaler + controller 50m/50Mi, webhook 50m/50Mi.
2. **`config-deployment`**: `registries-skipping-tag-resolving` includes the
   in-cluster Zot registry, its node-side NodePort 30500 aliases, and `ghcr.io` —
   the controller must not try to digest-resolve those images. `ghcr.io` is on the list because tag
   resolution runs from the controller pod, bypassing the node registry
   mirror (offline-breaking at the venue); drop it once the first-party
   images are published and digest-pinned (issue #7).
3. **`config-domain`**: add the data key `kn.cloudbox.k8s.test: ""`
   (`KNATIVE_DOMAIN`, `scripts/versions.env`), and delete
   the ConfigMap's `metadata.annotations` block (upstream ships only
   `knative.dev/example-checksum` there).
   **Do not skip this one.** Without the domain key, `config-domain` holds
   only `_example`, Knative falls back to `svc.cluster.local`, that domain is
   cluster-local and *not* served by the external Kourier NodePort, and every
   ksvc URL 404s — module 06 fails. With it, ksvc URLs become
   `http://<name>-<ns>.kn.cloudbox.k8s.test` (curation 4's
   `domain-template`), which the single `*.kn.cloudbox.k8s.test` wildcard
   Ingress in `ingress.yaml` routes to the Kourier gateway — browsable with no
   `Host` header and no port on both substrates (`:31080` with a `Host` header
   stays as the fallback). The domain key was found
   by rehearsal-in-CI, commit `a0687a2` (with the former local sslip domain, which only
   ever worked where the laptop's loopback WAS the cluster — the docker
   substrate). The annotation deletion arrived in
   that same commit; it is inert (the checksum only guards `_example`, which
   we do not touch) and is preserved as-is rather than re-litigated during a
   version bump — the other two curated ConfigMaps keep their annotation.
4. **`config-network`**: two keys.
   - `ingress-class: "kourier.ingress.networking.knative.dev"` — Kourier is the
     only ingress implementation installed.
   - `domain-template: "{{.Name}}-{{.Namespace}}.{{.Domain}}"` — **do not skip
     this one either.** Upstream's default is
     `"{{.Name}}.{{.Namespace}}.{{.Domain}}"`, which makes every ksvc host *two*
     DNS labels deep under `kn.cloudbox.k8s.test`. A Kubernetes Ingress wildcard
     host matches exactly **one** label, so that shape cannot be covered by any
     single rule: `ingress.yaml` had to carry one `*.<ns>.kn.…` rule per
     namespace, and a ksvc in a namespace nobody had listed — which is every
     namespace the Console's Application XR composes into, since the attendee
     picks the project — got **no route at all**. The dash form is upstream's
     own documented alternative for precisely this problem (see the
     `domain-template` commentary in the `_example` block of the same
     ConfigMap). With it every ksvc is one label, `ingress.yaml` is a single
     `*.kn.cloudbox.k8s.test` rule, and `.status.url` on the Knative Service
     reports the dashed host — which is what the labs' verifiers read.
     Revert it and module 06 still works while modules 08/09 quietly lose
     routing for anything an attendee names themselves.
5. **`config-observability`**: nine real config keys wiring Knative's own
   telemetry to the OTel Collector (#65). **Do not skip this one either** —
   everything inside `_example` is inert documentation, so a literal
   re-vendor silently drops all nine and module 09's trace waterfall loses
   the activator / queue-proxy hops. The endpoints are the *current*
   collector, not the removed otel-lgtm services the `_example` still names:

   | key | value |
   |---|---|
   | `tracing-protocol` | `http/protobuf` |
   | `tracing-endpoint` | `http://otel-collector.observability.svc.cluster.local:4318/v1/traces` |
   | `tracing-sampling-rate` | `1` |
   | `metrics-protocol` | `http/protobuf` |
   | `metrics-endpoint` | `http://otel-collector.observability.svc.cluster.local:4318/v1/metrics` |
   | `metrics-export-interval` | `60s` |
   | `request-metrics-protocol` | `http/protobuf` |
   | `request-metrics-endpoint` | `http://otel-collector.observability.svc.cluster.local:4318/v1/metrics` |
   | `request-metrics-export-interval` | `60s` |

   Since 1.22 this ConfigMap — not the deprecated `config-tracing` — is where
   tracing lives. The request-metrics keys are what measure the serverless
   story (per-revision RPS, concurrency, scale-from-zero).

### `kourier.yaml`

6. **Halved requests** the same way: `net-kourier-controller` and
   `3scale-kourier-gateway` both 200m/200Mi → **100m/100Mi** (limits
   untouched).
7. **Pinned Envoy**: `docker.io/envoyproxy/envoy:v1.37-latest` (floating!) →
   `v1.37.5` (verified on Docker Hub 2026-07-13), with a comment at the
   change site saying why. Stay on the **1.37 minor** — that is the only
   Envoy line net-kourier is tested against; `scripts/upstream.list` carries
   a `^1\.37\.` track regex so the weekly report stops proposing 1.39.
8. **Service `kourier` (kourier-system)**: `type: LoadBalancer` → `NodePort`
   with `nodePort: 31080` on the `http2` port (no LB implementation in
   Talos-in-Docker). The `https` port gets no nodePort. A comment at the
   change site shows `curl http://hello-demo.kn.cloudbox.k8s.test/` — the
   ingress hostname attendees use on both substrates.

9. ~~**Envoy `stats_listener` bound back to IPv4-any.**~~ **RETIRED
   2026-08-17 — there is nothing to re-apply, and re-applying it would be
   wrong.** `kourier.yaml` now carries upstream's `address: "::"` +
   `ipv4_compat: true` verbatim.

   What it was: net-kourier#1455 (new in 1.23.0) changed the
   `kourier-bootstrap` ConfigMap's *static* stats listener from
   `address: 0.0.0.0` to `address: "::"` + `ipv4_compat: true`, for dual-stack
   clusters, and we reverted it to the 1.22.1 form. The worry was sound: a
   static listener is bound at Envoy process start, so a bind failure is fatal
   rather than degraded — an unusable IPv6 stack in the pod netns would
   crashloop `3scale-kourier-gateway` before the `:8081` readiness probe was
   ever reached, and **module 06 would lose all ingress**.

   Why it is gone: it was tested on the live rehearsal cluster (Talos v1.13.8 /
   Cilium 1.20.0 / arm64) instead of reasoned about. With upstream's `"::"`
   bootstrap applied, a **freshly created gateway pod came up 1/1 with 0
   restarts**, and inside its netns `/proc/net/tcp6` holds **eight
   `[::]:9000` listeners** (0x2328, one SO_REUSEPORT socket per Envoy worker) —
   i.e. the static listener binds the IPv6 wildcard here, which the curation
   had made unprovable. The IPv4 dynamic listeners (`:8080`, `:8081`, `:8090`)
   and the `127.0.0.1:9901` admin are unchanged, the OTel Collector's
   `GET /stats/prometheus` still answers **200** over IPv4 (v4-mapped through
   `ipv4_compat`), and the former Host-header curl still returned
   `Hello your own cloud!` (that was
   the config-domain value on the day of the evidence; it is
   `hello-demo.kn.cloudbox.k8s.test` now — re-run it with the new Host).
   Full evidence in `docs/HAZARDS.md`.

   **If this ever comes back**, the symptom is unmistakable and immediate:
   `3scale-kourier-gateway` crashloops at process start with a bind /
   "Address family not supported" error in `kubectl logs`, and module 06 has no
   ingress at all. Re-add `address: 0.0.0.0` (and drop `ipv4_compat`) as the
   fix — but re-check `/proc/net/if_inet6` and `bindv6only` in the pod first,
   because the interesting question would be what removed IPv6 from the netns.

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
render serving-crds.yaml
fetch  https://github.com/knative/serving/releases/download/knative-v1.23.0/serving-crds.yaml

render serving-core.yaml
fetch  https://github.com/knative/serving/releases/download/knative-v1.23.0/serving-core.yaml

render kourier.yaml
fetch  https://github.com/knative-extensions/net-kourier/releases/download/knative-v1.23.0/kourier.yaml

# --- accepted curation: one line per diff hunk (id, then why) ---
allow  serving-core.yaml  fa38a31c  curation 2 — config-deployment registries-skipping-tag-resolving (Zot + its aliases + ghcr.io)
allow  serving-core.yaml  797bdd28  curation 3 — config-domain's knative.dev/example-checksum annotation deleted (inert; kept as-is rather than re-litigated at each bump)
allow  serving-core.yaml  672c43eb  curation 3 — config-domain gains kn.cloudbox.k8s.test; without it every ksvc URL 404s
allow  serving-core.yaml  a8882498  curation 4 — config-network: ingress-class kourier.ingress.networking.knative.dev + the single-label domain-template (was 62912f67 before domain-template joined the same zero-context hunk)
allow  serving-core.yaml  09d0bf54  curation 5 — the nine real config-observability keys (tracing + metrics + request-metrics) to the OTel Collector
allow  serving-core.yaml  32736b89  curation 1 — halved activator requests 300m/60Mi → 150m/30Mi
allow  serving-core.yaml  02de06f1  curation 1 — halved requests 100m/100Mi → 50m/50Mi (autoscaler, controller, webhook)
allow  kourier.yaml  3d26dade  curation 6 — halved requests 200m/200Mi → 100m/100Mi (net-kourier-controller, 3scale-kourier-gateway)
allow  kourier.yaml  aff418f9  curation 7 — Envoy pinned: v1.37-latest (floating!) → v1.37.5
allow  kourier.yaml  e3b3461c  curation 8 — the comment showing the ingress-hostname curl form (was 481cf2ba before the hostname became <name>-<namespace>)
allow  kourier.yaml  ea492933  curation 8 — nodePort 31080 on the http2 port
allow  kourier.yaml  4cb63f9a  curation 8 — Service kourier type LoadBalancer → NodePort (no LB in Talos-in-Docker)
```

Notes:
- **Module 06 smoke test (was the curation-9 watch item, now just the smoke
  test):** bring up `knative-serving` + `kourier-system`, confirm
  `3scale-kourier-gateway` reaches Running (not CrashLoopBackOff), then
  `curl http://hello-demo.kn.cloudbox.k8s.test/` (no Host header, no port).
  Since curation 9 was retired on 2026-08-17 the gateway runs upstream's
  IPv6-wildcard stats listener, so the crashloop this test was watching for is
  now a real regression rather than a known risk — `awk '$4=="0A"'
  /proc/net/tcp6` inside the pod should show `[::]:9000` (0x2328), eight
  SO_REUSEPORT sockets.
- `serving-core.yaml` includes the CRDs too; applying both crds+core is
  upstream's documented flow and idempotent under server-side apply.
- Knative control-plane images are `gcr.io/knative-releases/...@sha256:...`
  digests — pinned by upstream; they must be in the pre-pull list.
- Kourier gateway runs in `kourier-system` (namespace created by
  `kourier.yaml`); the Application destination is `knative-serving`.
- Gateway API mode is deliberately NOT used (not in Cilium's conformance
  matrix); Kourier speaks plain Ingress CRDs internal to Knative.
