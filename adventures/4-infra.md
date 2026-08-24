# Door 4 — Infra: the metal layer on your terms

**You came for:** Talos and Cilium themselves — the layer everything else stood
on all day without you looking at it. Zero new images: this door runs on what
every laptop already has.

**Prerequisites:** module 01. That's it. (`./scripts/catch-up.sh 5` if you want
workloads to observe while you operate.)

## The mission

Operate the cluster like it's production: read and patch the machine config,
take the backup you'd want before an incident, reshape the network layer, and
survive a rebuild. This is the door where `destroy-cluster.sh` is a tool, not a
failure.

## Warm-up (~10 min)

```bash
talosctl --context cloudbox dashboard          # the node, live
talosctl --context cloudbox get machineconfig -o yaml | less
```

Find three deliberate choices in that config: the CNI is `none` (Cilium came by
Helm — module 01), the kubelet's image, and KubePrism on `localhost:7445`
(which is why Cilium's `k8sServiceHost` is `localhost` — check
`scripts/create-cluster.sh:266`). Talos has **no SSH and no shell**; everything
you just did went through an authenticated API. That's the security model.

## The build

**Arc 1 — machine-config surgery.** Patch, don't edit: write a strategic-merge
patch (e.g. a sysctl under `machine.sysctls`, or a registry mirror under
`machine.registries`) and apply it:

```bash
talosctl --context cloudbox patch machineconfig --nodes <node-ip> --patch @patch.yaml
```

Watch what reboots and what doesn't (Talos tells you which changes are
hot-applied). Then verify the sysctl inside a pod. This patch workflow — not
golden-image rebuilds, not config drift — is how real Talos fleets are managed.

**Arc 2 — the backup you'd want at 3am.** `talosctl etcd snapshot db.snapshot`
against the control-plane node. Inspect what you got (it's the whole cluster:
every secret, every object — now reason about where such a file may live).
Then the drill on paper: from `talosctl etcd status`, which member would you
bootstrap from, and what does `--recover-from` need? (Full restore on
Talos-in-Docker is at-home material; taking + siting the snapshot is the
in-room skill.)

**Arc 3 — Gateway API.** NodePorts got us through the day; give the platform a
real front door. Cilium 1.20 implements Gateway API natively — no new
controller. The Helm release is yours (vendored chart, `scripts/manifests/`):

```bash
helm upgrade cilium scripts/manifests/cilium-1.20.0.tgz -n kube-system \
  --reuse-values --set gatewayAPI.enabled=true
```

Traps section first, then: a `Gateway` + an `HTTPRoute` to the Console, and
retire one NodePort. Pair with door 2's cert-manager for HTTPS and you've
rebuilt a cloud load balancer + ACM out of parts you own.

**Arc 4 — rebuild with two workers.** `create-cluster.sh` pins `--workers 1`.
Destroy, bump it, recreate, `catch-up.sh 5` — about ten minutes of wall clock,
all of it scripted (this exact path is what the recovery-path CI job proves).
Now you have scheduling to play with: cordon and drain the old worker and watch
CNPG and Knative reschedule; find what has a PodDisruptionBudget and what
merely should.

## You know it works when…

- Arc 1: your sysctl reads back from a pod; `talosctl get machineconfig` shows
  your patch merged.
- Arc 2: the snapshot file exists and you can say, in one sentence, which
  member you'd restore from.
- Arc 3: the Console loads through the Gateway's address with the NodePort
  service deleted.
- Arc 4: `kubectl get nodes` shows two workers and the pipeline still passes an
  upload while one of them is cordoned.

## Known traps

- **Gateway API CRDs are not vendored** — Cilium implements the API but doesn't
  ship the CRDs. Installing them is the one internet-touching step on this
  door (or pull them from the repo maintainers' machines; they're plain YAML).
  Apply CRDs *before* the helm upgrade, or the controller sulks.
- The Cilium install is **Helm-managed, not GitOps-managed** — deliberate
  bootstrap-ordering choice (the CNI can't be delivered by a GitOps engine
  whose pods need a CNI). Use `--reuse-values` or you'll silently reset the
  Talos-specific values and lose the cluster's networking. Copy the full
  invocation from `create-cluster.sh` if unsure.
- Talos-in-Docker has no installer flow: node OS upgrades and full etcd
  restore drills belong on real metal (or a VM at home), not in this room.
- Rebuilding re-rolls NodePorts? No — they're pinned in the manifests. But your
  browser's tabs from before the rebuild hold session state that won't survive
  Gitea being re-seeded; hard-refresh before concluding something's broken.
- Memory: two workers double the worker RAM envelope. On a 16 GB machine,
  drop `TALOS_MEMORY_WORKER` accordingly or skip Arc 4 — the scheduler lesson
  works on paper too.

## At home

The real version of this door is a £150 mini-PC: Talos on metal, the same
machine-config patches, the same Cilium values, and your workshop Gitea's
`gitops/` repo pointed at it. Nothing you built today is laptop-shaped.
