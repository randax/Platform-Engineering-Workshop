# Vendored: knative-serving (+ Kourier)

| | |
|---|---|
| Source | https://github.com/knative/serving + https://github.com/knative-extensions/net-kourier |
| Version | **knative-v1.22.1** for all three files (releases 2026-06-02; verified 2026-07-13) |
| Files | `serving-crds.yaml`, `serving-core.yaml`, `kourier.yaml` |

## Re-vendor

```sh
BASE=https://github.com/knative/serving/releases/download/knative-v1.22.1
curl -sL -o serving-crds.yaml $BASE/serving-crds.yaml
curl -sL -o serving-core.yaml $BASE/serving-core.yaml
curl -sL -o kourier.yaml \
  https://github.com/knative-extensions/net-kourier/releases/download/knative-v1.22.1/kourier.yaml
```

## Workshop curation applied (re-apply after re-vendoring)

1. **Halved every Deployment container's cpu/memory *requests*** in
   `serving-core.yaml` and `kourier.yaml` (limits untouched) — the k0s-blog
   small-cluster pattern; drops idle footprint to ~0.6 GiB. Script used
   (state-machine over `requests:` blocks): halve `NNNm`/`NNNMi` quantities.
   Resulting requests: activator 150m/30Mi, autoscaler+controller 50m/50Mi,
   webhook 50m/50Mi, kourier controller+gateway 100m/100Mi.
2. **`config-network`**: `ingress-class: "kourier.ingress.networking.knative.dev"`.
3. **`config-deployment`**: `registries-skipping-tag-resolving:
   "zot.zot.svc.cluster.local:5000,localhost:30500,127.0.0.1:30500"` — the
   controller must not try to digest-resolve images in the in-cluster
   registry / its NodePort aliases.
4. **Service `kourier` (kourier-system)**: `LoadBalancer` → `NodePort` with
   `nodePort: 31080` on port 80 (no LB implementation in Talos-in-Docker).
5. **Pinned Envoy**: `docker.io/envoyproxy/envoy:v1.37-latest` (floating!) →
   `v1.37.2` (verified on Docker Hub 2026-07-13).

Notes:
- `serving-core.yaml` includes the CRDs too; applying both crds+core is
  upstream's documented flow and idempotent under server-side apply.
- Knative control-plane images are `gcr.io/knative-releases/...@sha256:...`
  digests — pinned by upstream; they must be in the pre-pull list.
- Kourier gateway runs in `kourier-system` (namespace created by
  `kourier.yaml`); the Application destination is `knative-serving`.
- Gateway API mode is deliberately NOT used (not in Cilium's conformance
  matrix); Kourier speaks plain Ingress CRDs internal to Knative.
