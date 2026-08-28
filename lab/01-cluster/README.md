# Module 01 — Your own cloud: Talos Linux + Cilium

## The goal

At the end of this module a two-node Kubernetes cluster called **cloudbox** runs on your
laptop: Talos Linux nodes — real VMs where `tbx` works, Docker containers everywhere else —
networked by Cilium's eBPF datapath, with **no kube-proxy and no SSH anywhere**. You can
prove it with `kubectl get nodes` showing two
Ready nodes and `./verify.sh` green — and, more importantly, you can explain what's
*missing* from these nodes and why.

## Why this matters

Every cloud provider runs an OS under your Kubernetes that you never see. Today you own
that layer. Talos Linux is an immutable, API-only operating system built solely to run
Kubernetes: no shell, no SSH, no package manager — the entire machine is one declarative
config document managed over a gRPC API (`talosctl`). Cilium replaces both the CNI *and*
kube-proxy with eBPF programs in the kernel. This combination is what "production-grade"
looks like in 2026 — and it fits on your laptop. `create-cluster.sh` picks the substrate
for you (`talos-box` VMs, or Talos-in-Docker); everything below is the same on both.

## The task

1. Create the cluster — **without a network**:

   ```bash
   ./scripts/create-cluster.sh --skip-cilium
   ```

   While it runs (~2–3 min), read the script. It is short on purpose — everything it does,
   you could type.

2. Look at what you own: `kubectl get nodes`. Both nodes are **NotReady** — and they will
   stay that way forever, because this cluster has **no CNI**. Convince yourself of why
   before fixing it: `kubectl describe node` one of them and find the complaint;
   `kubectl -n kube-system get pods` and explain the `Pending` ones; find the
   `cluster.network.cni: none` decision in the Talos machine config (hint 2). A cloud
   provider made this choice for you on every cluster you've ever used. Today it's yours.

3. **Give your cluster a network.** Install Cilium with Helm from the vendored chart at
   `scripts/manifests/` — no internet needed. The values are Talos-specific and matter;
   hint 3 builds up to the exact command. Keep `kubectl get nodes -w` running in a second
   terminal and watch NotReady become Ready the moment the CNI lands. That transition is
   the whole lesson.

   (Behind, or rebuilding? Plain `./scripts/create-cluster.sh` without the flag does this
   step for you — that's what catch-up uses.)

4. Now **prove to yourself what you just built**. Find answers to these, using `talosctl`
   and `kubectl` (hints below if you want them):

   - There is no SSH. What *is* the management plane? Show the machine's config document
     without logging into anything.
   - Open the Talos dashboard for a node. What is the machine doing right now?
   - Which cluster members does Talos itself know about (not Kubernetes — Talos)?
   - Kubernetes says both nodes are `Ready`. What is doing the networking? Show that
     Cilium is healthy — and show that **kube-proxy does not exist** in this cluster.
     Who answers Service traffic then?

5. Run `./verify.sh`.

## Hints

<details>
<summary>Hint 1: Where do I even start with talosctl?</summary>

`talosctl` talks to the Talos API on the nodes — your talosconfig was set up by the create
script, which pointed the `cloudbox` context at your control plane. So you need **no `-n`
flag**: `talosctl get members` already knows which node to ask. `talosctl config info`
prints the endpoint and node it will use (the address differs per substrate — a DHCP lease
in a talos-box VM, an address in the Talos docker network — which is exactly why you read
it rather than type it). `kubectl get nodes -o wide` shows the same addresses.
</details>

<details>
<summary>Hint 2: The machine config, dashboard, and members</summary>

- Machine config (the *entire OS* as one document):
  `talosctl get machineconfig -o yaml | less` — look for the `cluster.network.cni`
  and `cluster.proxy` sections; that's where we told Talos "no default CNI, no kube-proxy".
- Live dashboard: `talosctl dashboard` (q to quit).
- Talos' own view of the cluster: `talosctl get members`.
- Also fun: `talosctl services` — count how few moving parts a node has.
- All four go to the node your context points at. To ask the *other* node, add
  `-n <address from kubectl get nodes -o wide>`.
</details>

<details>
<summary>Hint 3: Installing Cilium — from goal to the exact command</summary>

- **Goal:** one `helm upgrade --install` against the vendored chart
  (`scripts/manifests/cilium-<version>.tgz`, version pinned in `scripts/versions.env`),
  namespace `kube-system`, with values that (a) use Kubernetes for IPAM, (b) replace
  kube-proxy, and (c) point Cilium at the API server via **KubePrism** —
  Talos' node-local API balancer on `localhost:7445`.
- **Why the odd values?** Talos mounts cgroups itself (`cgroup.autoMount.enabled=false`,
  `hostRoot=/sys/fs/cgroup`) and its default PodSecurity needs the agent's capability
  list spelled out. This is the documented Talos+Cilium recipe, not workshop magic:
  https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
- **The command**, exactly as the script would run it — `create-cluster.sh` step 3 *is*
  the reference solution, and it's meant to be read:

```bash
source scripts/versions.env
helm upgrade --install cilium \
  --server-side=false \
  "scripts/manifests/cilium-${CILIUM_VERSION}.tgz" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set l2announcements.enabled=true \
  --set k8sClientRateLimit.qps=10 \
  --set k8sClientRateLimit.burst=20 \
  --set ingressController.enabled=true \
  --set ingressController.loadbalancerMode=shared \
  --set "operator.extraArgs[0]=--ingress-default-request-timeout=24h" \
  --set ingressController.service.type=NodePort \
  --set ingressController.service.insecureNodePort="${NODEPORT_INGRESS}"
```

(`l2announcements` and the raised client rate limit are set on **both** substrates on
purpose, so `cilium config view` reads the same on every laptop in the room; only tbx
actually announces anything.)

The last five flags are the shared **ingress**, and they are not optional: one
Cilium ingress serves every `*.cloudbox.k8s.test` hostname you will use for the
rest of the day, and `verify.sh` checks for it. The script builds them from
`cilium_ingress_values()` in `scripts/lib.sh`, the single source it shares with
the kind lifeboat.

Those two `service.*` lines are the **docker** shape. Check which substrate you
are on with `cat ~/.cloudbox/substrate`, because **tbx needs a different ending**
— a real LoadBalancer instead of a NodePort (the L2 announcer already enabled above
is what claims its VIP on the network), plus host routing so the VIP is reachable
from your laptop:

```bash
  --set ingressController.service.type=LoadBalancer \
  --set bpf.hostLegacyRouting=true          # so the VIP is reachable from your laptop
```

**And on tbx the flags alone are not enough.** A LoadBalancer Service needs an
address to hand out, which means two more objects — a `CiliumLoadBalancerIPPool`
and a `CiliumL2AnnouncementPolicy` — and without them `cilium-ingress` sits in
`<pending>` forever and `verify.sh` fails with nothing to tell you why. They are
the one part the script does for you rather than making you type subnet
arithmetic: once your Cilium is up, run

```bash
./scripts/create-cluster.sh --post-cni
```

It does exactly three things — applies the pool and the policy, waits for your
Cilium rollout and the nodes, and proves `cilium-ingress` got `.200` — and
nothing else: no preflight, no `tbx doctor`, no VM is touched. (Do **not** re-run
the bare `./scripts/create-cluster.sh`: on tbx it refuses because the cluster
already exists.)

- Then watch: `kubectl -n kube-system rollout status ds/cilium` and your
  `kubectl get nodes -w` terminal.

**If a node stays `NotReady` for more than a few minutes**, it is usually not
Cilium — it is an image pull that stalled on the way into the VM. Ask the node
itself:

```bash
talosctl -n <node-ip> -e <node-ip> service kubelet    # or: service etcd
```

A service sitting in `Preparing` whose byte count in the events has not moved
between two looks is a stalled pull. Power-cycle that node — the disk survives,
the pull restarts:

```bash
talosctl -n <node-ip> -e <node-ip> reboot --wait=false
# or, from the outside:
tbx node stop  cloudbox cloudbox-worker-1             # or cloudbox-cp-1
tbx node start cloudbox cloudbox-worker-1
```

then keep watching `kubectl get nodes -w`. (talos-box v0.1.2 adds `tbx node
restart` and makes `tbx status cloudbox` say "stalled" directly; on the pinned
v0.1.1 the `service` command is the honest signal.)
</details>

<details>
<summary>Hint 4: Proving the Cilium / no-kube-proxy story</summary>

- Cilium health, without any extra tools:
  `kubectl -n kube-system get pods -l k8s-app=cilium` and
  `cilium status --wait` (the CLI reads cluster state).
- kube-proxy is absent: `kubectl -n kube-system get ds,pods | grep -c kube-proxy` should
  find nothing. Yet `kubectl get svc -A` shows Services with ClusterIPs that work.
- Ask Cilium who handles Services:
  `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i kubeproxy` —
  look for `KubeProxyReplacement: True`. eBPF programs attached in the kernel are doing
  what iptables rules used to do.
- One more: Cilium reaches the API server via `localhost:7445` — that's Talos **KubePrism**,
  a node-local API-server load balancer. Find it in the machine config.
</details>

<details>
<summary>Full solution</summary>

```bash
./scripts/create-cluster.sh --skip-cilium
kubectl get nodes                # NotReady — no CNI, by your own choice

# Give it a network yourself (hint 3 has the full command with values):
source scripts/versions.env
helm upgrade --install cilium --server-side=false \
  "scripts/manifests/cilium-${CILIUM_VERSION}.tgz" -n kube-system \
  --set ipam.mode=kubernetes --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost --set k8sServicePort=7445 \
  --set cgroup.autoMount.enabled=false --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set l2announcements.enabled=true \
  --set k8sClientRateLimit.qps=10 --set k8sClientRateLimit.burst=20 \
  --set ingressController.enabled=true \
  --set ingressController.loadbalancerMode=shared \
  --set "operator.extraArgs[0]=--ingress-default-request-timeout=24h" \
  --set ingressController.service.type=NodePort \
  --set ingressController.service.insecureNodePort="${NODEPORT_INGRESS}"   # <- docker ending
kubectl get nodes -w             # NotReady -> Ready, live

# On tbx (cat ~/.cloudbox/substrate) REPLACE the two docker lines above with
# the tbx ending, then run the post step — the pool and policy the VIP needs:
#   --set ingressController.service.type=LoadBalancer \
#   --set bpf.hostLegacyRouting=true
# ./scripts/create-cluster.sh --post-cni

# The management plane is an API, not SSH:
talosctl config info                     # which node/endpoint this context talks to
talosctl get machineconfig -o yaml | less   # /cni and /proxy to find the sections
talosctl dashboard                       # q to quit
talosctl get members
talosctl services

# Kubernetes + Cilium:
kubectl get nodes -o wide
cilium status --wait
kubectl -n kube-system get ds                            # cilium yes, kube-proxy: absent
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i kubeproxy

cd lab/01-cluster && ./verify.sh
```
</details>

## Check your work

```bash
./verify.sh
```

It checks: your two Talos nodes exist on whichever substrate you are on (talos-box VMs
via `tbx status`, Talos node containers via `docker ps`); both nodes are `Ready`; the
Cilium DaemonSet is fully available; the Cilium operator is Available; Cilium reports
kube-proxy replacement active; no kube-proxy is running anywhere; CoreDNS is Available;
and the shared ingress holds the endpoint every `*.cloudbox.k8s.test` name lands on.

On the **docker** substrate those names also need a line each in `/etc/hosts`, and that
is the one step in this whole workshop that asks for your password. `create-cluster.sh`
writes them for you — including on the `--skip-cilium` path you just took. If you
declined the prompt, or the block never got written, every `*.cloudbox.k8s.test` URL
fails from module 02 onward on a perfectly healthy cluster. Fix it any time, the cluster
keeps running:

```bash
./scripts/install.sh --print-hosts    # exactly what would be added
./scripts/install.sh --write-hosts    # add it (sudo, once)
```

(On **tbx** nothing is written: talos-box's own resolver answers those names.)

## Explain-back

Tell your neighbor: this node has no SSH and no package manager. Name two concrete
*operational* problems that design deletes (think: patching, drift, attack surface, "who
changed what").

## Going deeper

- Break a node on purpose, then put it back. Watch `kubectl get nodes -w` in a second
  terminal while you do it — the worker goes `NotReady` in ~40 s, and its pods are
  rescheduled or stay Pending (there is only one other node, and it is the control plane).
  Pick the half that matches your substrate — `cat ~/.cloudbox/substrate` if you are not
  sure:

  <details>
  <summary>talos-box (VMs)</summary>

  ```bash
  tbx node stop  cloudbox cloudbox-worker-1   # power it off; the disk survives
  tbx status cloudbox                          # phase: stopped
  tbx node start cloudbox cloudbox-worker-1   # boot it again
  ```

  Both verbs are upstream tbx (`tbx node start|stop <cluster> <node>`), and neither
  touches the node's disk — this is a power cycle, not a re-create.
  </details>

  <details>
  <summary>docker substrate (containers)</summary>

  ```bash
  docker pause   cloudbox-worker-1   # docker substrate only
  docker unpause cloudbox-worker-1   # docker substrate only
  ```
  </details>
- `talosctl read /proc/version` — you can read files via the API, but try to
  *write* something. What stops you?
- Compare `kubectl -n kube-system get pods` on this cluster with any managed-cloud cluster
  you have access to. What's missing here, and what does the cloud hide from you there?

## If it goes wrong

The cluster is cattle: destroying and recreating it takes ~5 minutes (images are already
local). Name the substrate on both halves —

```bash
CLOUDBOX_SUBSTRATE=docker ./scripts/destroy-cluster.sh && \
CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh     # or =tbx, whichever you are on
```

— because the destroy removes `~/.cloudbox/substrate` with the cluster, and a bare
`create-cluster.sh` then decides again from scratch rather than rebuilding what you had.
`./scripts/install.sh --check` prints which one you are on. On the kind lifeboat neither
script applies: rebuild with `./scripts/kind-fallback.sh --delete && ./scripts/kind-fallback.sh`.
If Talos-in-Docker fights
your machine specifically, `./scripts/kind-fallback.sh` gives you a kind+Cilium cluster
with the same ingress, the same hostnames and the same `/etc/hosts` block — you lose the
Talos exploration but every later module works the same. Remove it afterwards with
`./scripts/kind-fallback.sh --delete` (cluster, hosts block **and** the recorded
identity); `destroy-cluster.sh` refuses there — it tears down substrates, and kind is
not one.

**On the lifeboat this module is not gradeable.** `./verify.sh` checks a *Talos*
cluster — Talos node containers or tbx VMs, and the ingress shape the substrate
gives it — so it prints "kind lifeboat: module 01 is not gradeable here" and exits
0 rather than failing a cluster that is working exactly as documented. That is the
whole price of the lifeboat: module 02 onward is identical, and `verify.sh` in every
later module grades you normally.
