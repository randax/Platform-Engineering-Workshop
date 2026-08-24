# Module 01 — Your own cloud: Talos Linux + Cilium

## The goal

At the end of this module a two-node Kubernetes cluster called **cloudbox** runs on your
laptop: Talos Linux nodes (in Docker), networked by Cilium's eBPF datapath, with **no
kube-proxy and no SSH anywhere**. You can prove it with `kubectl get nodes` showing two
Ready nodes and `./verify.sh` green — and, more importantly, you can explain what's
*missing* from these nodes and why.

## Why this matters

Every cloud provider runs an OS under your Kubernetes that you never see. Today you own
that layer. Talos Linux is an immutable, API-only operating system built solely to run
Kubernetes: no shell, no SSH, no package manager — the entire machine is one declarative
config document managed over a gRPC API (`talosctl`). Cilium replaces both the CNI *and*
kube-proxy with eBPF programs in the kernel. This combination is what "production-grade"
looks like in 2026 — and it fits in Docker on your laptop.

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
script. Try `talosctl --help`, and note most commands take `-n <node-ip>`. Find your node
IPs with `talosctl config info` or `kubectl get nodes -o wide`. In this docker cluster the
control-plane node is typically `10.5.0.2`.
</details>

<details>
<summary>Hint 2: The machine config, dashboard, and members</summary>

- Machine config (the *entire OS* as one document):
  `talosctl -n 10.5.0.2 get machineconfig -o yaml | less` — look for the `cluster.network.cni`
  and `cluster.proxy` sections; that's where we told Talos "no default CNI, no kube-proxy".
- Live dashboard: `talosctl -n 10.5.0.2 dashboard` (q to quit).
- Talos' own view of the cluster: `talosctl -n 10.5.0.2 get members`.
- Also fun: `talosctl -n 10.5.0.2 services` — count how few moving parts a node has.
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
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
```

- Then watch: `kubectl -n kube-system rollout status ds/cilium` and your
  `kubectl get nodes -w` terminal.
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
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
kubectl get nodes -w             # NotReady -> Ready, live

# The management plane is an API, not SSH:
talosctl -n 10.5.0.2 get machineconfig -o yaml | less   # /cni and /proxy to find the sections
talosctl -n 10.5.0.2 dashboard                           # q to quit
talosctl -n 10.5.0.2 get members
talosctl -n 10.5.0.2 services

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

It checks: the cloudbox Docker containers exist; both nodes are `Ready`; the Cilium
DaemonSet is fully available; Cilium reports kube-proxy replacement active; and no
kube-proxy is running anywhere.

## Explain-back

Tell your neighbor: this node has no SSH and no package manager. Name two concrete
*operational* problems that design deletes (think: patching, drift, attack surface, "who
changed what").

## Going deeper

- Break a node on purpose: `docker pause cloudbox-worker-1`, watch `kubectl get nodes -w`
  and the Talos dashboard react, then `docker unpause` it.
- `talosctl -n 10.5.0.2 read /proc/version` — you can read files via the API, but try to
  *write* something. What stops you?
- Compare `kubectl -n kube-system get pods` on this cluster with any managed-cloud cluster
  you have access to. What's missing here, and what does the cloud hide from you there?

## If it goes wrong

The cluster is cattle: `./scripts/destroy-cluster.sh && ./scripts/create-cluster.sh` is
always safe and takes ~5 minutes (images are already local). If Talos-in-Docker fights
your machine specifically, `./scripts/kind-fallback.sh` gives you a kind+Cilium cluster —
you lose the Talos exploration but every later module works the same.
