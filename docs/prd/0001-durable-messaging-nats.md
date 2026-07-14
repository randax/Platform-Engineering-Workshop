# PRD-0001 — Durable messaging with NATS JetStream

**Status:** Proposed (stretch module) · **Verdict:** Build, demo/stretch
**Depends on:** stable core + module 09 capstone · **Not in the published abstract**

## Problem

The capstone pipeline (module 09) runs on Knative Eventing's **in-memory
broker**. It teaches the event-driven *contract* well — CloudEvents, broker →
trigger routing, scale-from-zero — but the in-memory channel is explicitly
dev-only: it loses in-flight events on restart, is best-effort, and can't
replay. Attendees leave without seeing *why* a real platform needs a durable
broker, or what one gives them.

## Goal & non-goals

**Goal:** in ~15 minutes, make the durability gap visceral and show the
production-grade answer — durable streams, at-least-once delivery, replay.

**Non-goals:** teaching Kafka; making every attendee re-plumb Knative Eventing;
building a messaging-theory module. This is a *punchline*, not a lecture.

## What it adds (teaching value)

The single beat that carries it: **kill the broker pod mid-pipeline.**
- In-memory: the in-flight resize event is *gone* — the thumbnail never appears.
- JetStream: the event is persisted; on restart the consumer *replays* it and
  the thumbnail shows up. "That's the difference between a demo and a platform."

Plus, if time allows: `nats stream ls` / `nats consumer info` to make the
durable stream and its state visible — messaging you can *inspect*.

## Design

**Component:** single-node **NATS 2.11/2.12 + JetStream**, official Helm chart,
one Deployment, no external deps. Vendor the rendered manifests into
`gitops/components/nats/` and add a `gitops/catalog/nats.yaml` Application
(same pattern as every other capability). Cap it at ~256 MiB.

**Integration — two options, pick the reliable one:**
1. **Standalone (recommended):** the capstone uploader/resizer publish/consume
   a durable JetStream stream *directly* via the NATS client lib, in parallel
   to (or instead of) the CloudEvent path. Most reliable; no Knative coupling.
2. **Knative-backed (demo-only, risky):** swap the `MTChannelBasedBroker`
   default channel from `InMemoryChannel` to `NatsJetStreamChannel`
   (`knative-extensions/eventing-natss`, beta project / alpha channel, adds 2
   controller pods). Conceptually a one-line channel swap; operationally a
   live-debugging rabbit hole under a workshop clock.

**Recommendation:** ship option 1. Optionally *demonstrate* option 2 from the
lectern to show Knative's pluggable-channel design, but never require it.

⚠️ Do **not** wire anything to the deprecated `NatssChannel` (NATS Streaming /
STAN) — STAN reached EOL in 2023. JetStream is the modern path.

## Cost

- **RAM:** ~150–256 MiB (standalone). Trivial against real headroom.
- **Time:** ~15 min as a demo; ~25–30 as a light hands-on (deploy + publish +
  the kill-and-replay).
- **Build effort:** ~1 evening to vendor + catalog NATS; ~1 evening for the
  publish/consume code in the capstone apps + the lab writeup.
- **Images to pre-pull:** `nats:<pinned>` (+ nats-box for the CLI demo).

## Risks

- eventing-natss JetStream channel is alpha → **mitigated** by making the
  hands-on path standalone, not Knative-backed.
- Idle-RAM figure is from vendor docs, not measured on Talos-in-Docker →
  confirm with the kubelet `workingSetBytes` snapshot (issue #8) before pinning.

## Decision

**Build as a stretch module** once the capstone is solid. It's the natural,
cheap "and here's how you'd make it real" coda to the event-driven story the
workshop already tells.
