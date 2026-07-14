# Vendored: knative-eventing

| | |
|---|---|
| Source | https://github.com/knative/eventing |
| Version | **knative-v1.22.2** for all four files (released 2026-06-16; verified 2026-07-14). Same minor as the vendored knative-serving (v1.22.1) — eventing 1.22.x had one more patch release than serving. |
| Files | `eventing-crds.yaml`, `eventing-core.yaml`, `in-memory-channel.yaml`, `mt-channel-broker.yaml` |

## Re-vendor

```sh
BASE=https://github.com/knative/eventing/releases/download/knative-v1.22.2
for f in eventing-crds.yaml eventing-core.yaml in-memory-channel.yaml mt-channel-broker.yaml; do
  curl -sL -o $f $BASE/$f
done
```

## Workshop curation applied (re-apply after re-vendoring)

1. **Halved every Deployment container's cpu/memory *requests*** in
   `eventing-core.yaml` and `mt-channel-broker.yaml` (limits untouched) —
   same k0s-blog small-cluster pattern as knative-serving. Resulting
   requests: eventing-controller 50m/50Mi, job-sink 62m/32Mi,
   pingsource-mt-adapter 62m/32Mi, eventing-webhook 50m/25Mi,
   mt-broker-filter + mt-broker-ingress + mt-broker-controller 50m/50Mi.
   `in-memory-channel.yaml` ships no requests upstream (imc-controller,
   imc-dispatcher) — left as-is. `request-reply` ships no requests either.

That is the only curation: no images repointed, no services exposed —
eventing is control-plane + in-cluster data-plane only (the Broker ingress
is `broker-ingress.knative-eventing.svc.cluster.local`, ClusterIP).

## Images (all upstream digest-pinned; verified pullable via crane 2026-07-14)

All `gcr.io/knative-releases/knative.dev/eventing/cmd/...@sha256:...` —
must be in the pre-pull list (`scripts/images.txt`):

- `.../cmd/controller@sha256:866896c0d955ec7774e6c85e6349e034470ccb3317d34f08b3273c950c59eb39` (eventing-controller)
- `.../cmd/webhook@sha256:b116f58ff8b3b8d2c03d96ebefa32f7d66715d07e31528c3cbdf0bbc9626e85e` (eventing-webhook)
- `.../cmd/jobsink@sha256:bd23e8d8cef444bba1873efc629fed5785257fa3a3ceb0621a2ec8ac5a19a3cc` (job-sink)
- `.../cmd/mtping@sha256:963722f316ec570fcaf116363c2e0f6fc1bd3fbbed8e25ae1eefee9b930bb091` (pingsource-mt-adapter)
- `.../cmd/requestreply@sha256:f4d194097b43865e396f54b4fd94f779a2ed96c9691a3a8de4740722e5535804` (request-reply)
- `.../cmd/in_memory/channel_controller@sha256:0855eba113da71ebd433ca5e7c583ba2601c4d55e0c52ca0d6ab19edfbed1513` (imc-controller)
- `.../cmd/in_memory/channel_dispatcher@sha256:aa39224456b80b2734729450a9eb6076b13e008060a522436e2475b1ca9b058e` (imc-dispatcher)
- `.../cmd/broker/filter@sha256:9080a69414303816e82886ea2b280a01f5c0fd1e0cadad06283450bc2b39d78b` (mt-broker-filter)
- `.../cmd/broker/ingress@sha256:8b14a777da20f25d477c367ffdd26dec31fdb3d14bd50c99134ef527c540fbe1` (mt-broker-ingress)
- `.../cmd/mtchannel_broker@sha256:9ea2a9c99843614f544738c01b6d4e2e0fa5b06722aa50380f18b8af80918f59` (mt-broker-controller)

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
