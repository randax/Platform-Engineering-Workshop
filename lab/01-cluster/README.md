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

1. Create the cluster:

   ```bash
   ./scripts/create-cluster.sh
   ```

   While it runs (~3–5 min), read the script. It is short on purpose — everything it does,
   you could type.

2. Now **prove to yourself what you just built**. Find answers to these, using `talosctl`
   and `kubectl` (hints below if you want them):

   - There is no SSH. What *is* the management plane? Show the machine's config document
     without logging into anything.
   - Open the Talos dashboard for a node. What is the machine doing right now?
   - Which cluster members does Talos itself know about (not Kubernetes — Talos)?
   - Kubernetes says both nodes are `Ready`. What is doing the networking? Show that
     Cilium is healthy — and show that **kube-proxy does not exist** in this cluster.
     Who answers Service traffic then?

3. Run `./verify.sh`.

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
<summary>Hint 3: Proving the Cilium / no-kube-proxy story</summary>

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
./scripts/create-cluster.sh

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

The cluster is cattle: `./scripts/destroy-cluster.sh && ./scripts/create-cluster.sh` is
always safe and takes ~5 minutes (images are already local). If Talos-in-Docker fights
your machine specifically, `./scripts/kind-fallback.sh` gives you a kind+Cilium cluster —
you lose the Talos exploration but every later module works the same.
