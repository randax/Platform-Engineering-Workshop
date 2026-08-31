# Module 01: your own cloud with Talos Linux and Cilium

## The goal

A two-node Kubernetes cluster called **cloudbox** runs on your laptop: Talos Linux nodes
(real VMs where `tbx` works, Docker containers everywhere else), networked by Cilium's
eBPF datapath, with no kube-proxy and no SSH anywhere. Proof: `kubectl get nodes` shows
two Ready nodes and `./verify.sh` is green. And you can explain what's *missing* from
these nodes, and why.

## Why this matters

Every cloud provider runs an OS under your Kubernetes that you never see; today you own
that layer. Talos Linux is an immutable, API-only OS built solely to run Kubernetes: no
shell, no SSH, no package manager, the whole machine one declarative document managed
over a gRPC API (`talosctl`). Cilium replaces both the CNI and kube-proxy with eBPF
programs in the kernel.

## The task

1. Create the cluster, **without a network**:

   ```bash
   mise run cluster:create -- --skip-cilium
   ```

   While it runs (~2-3 min), read the script. It is short on purpose.

2. `kubectl get nodes`: both nodes are **NotReady** and stay that way, because this
   cluster has no CNI. Convince yourself why before fixing it: `kubectl describe node`
   one of them, explain the `Pending` pods in `kubectl -n kube-system get pods`, find
   the `cluster.network.cni: none` decision in the machine config (hint 2).

3. **Give your cluster a network.** Install Cilium with Helm from the vendored chart at
   `scripts/manifests/`, no internet needed. The values are Talos-specific and matter;
   hint 3 builds up to the exact command. Keep `kubectl get nodes -w` running in a second
   terminal and watch NotReady become Ready the moment the CNI lands.

   (Behind, or rebuilding? Plain `mise run cluster:create` without the flag does this
   step for you.)

4. **Prove what you built.** Answer with `talosctl` and `kubectl` (hints below):

   - There is no SSH. What *is* the management plane? Show the machine's config document
     without logging into anything.
   - Open the Talos dashboard for a node. What is the machine doing right now?
   - Which cluster members does Talos itself know about (not Kubernetes, Talos)?
   - Both nodes are `Ready`. Show that Cilium is healthy and that kube-proxy does not
     exist in this cluster. Who answers Service traffic then?

5. Run `./verify.sh`.

## Check your work

```bash
./verify.sh
```

<details>
<summary>Docker backend: the /etc/hosts block, and the one sudo prompt</summary>

On the Docker backend the `*.cloudbox.k8s.test` names need a line each in `/etc/hosts`;
`create-cluster.sh` writes them (the one sudo prompt in this workshop). If you declined
the prompt, every workshop URL fails from module 02 onward on a healthy cluster. Fix it
any time:

```bash
./scripts/install.sh --print-hosts    # exactly what would be added
./scripts/install.sh --write-hosts    # add it (sudo, once)
```

On tbx nothing is written: talos-box's own resolver answers those names.
</details>

## Hints

<details>
<summary>Hint 1: Where do I even start with talosctl?</summary>

`talosctl` talks to the Talos API on the nodes. The create script pointed the `cloudbox`
context at your control plane, so `talosctl get members` needs no `-n` flag.
`talosctl config info` prints the endpoint and node in use; read the address rather than
type it, it differs per backend. `kubectl get nodes -o wide` shows the same addresses.
</details>

<details>
<summary>Hint 2: The machine config, dashboard, and members</summary>

- Machine config (the *entire OS* as one document):
  `talosctl get machineconfig -o yaml | less`. Look for the `cluster.network.cni`
  and `cluster.proxy` sections; that's where we told Talos "no default CNI, no kube-proxy".
- Live dashboard: `talosctl dashboard` (q to quit).
- Talos' own view of the cluster: `talosctl get members`.
- Also fun: `talosctl services`. Count how few moving parts a node has.
- All four go to the node your context points at. To ask the *other* node, add
  `-n <address from kubectl get nodes -o wide>`.
</details>

<details>
<summary>Hint 3: Installing Cilium, from goal to the exact command</summary>

- **Goal:** one `helm upgrade --install` against the vendored chart
  (`scripts/manifests/cilium-<version>.tgz`, version pinned in `scripts/versions.env`),
  namespace `kube-system`, with values that (a) use Kubernetes for IPAM, (b) replace
  kube-proxy, and (c) point Cilium at the API server via **KubePrism**, Talos'
  node-local API balancer on `localhost:7445`.
- **Why the odd values?** Talos mounts cgroups itself (`cgroup.autoMount.enabled=false`,
  `hostRoot=/sys/fs/cgroup`) and its default PodSecurity needs the agent's capability
  list spelled out. This is the documented Talos+Cilium recipe:
  https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
- **Which backend am I on?** `cat ~/.cloudbox/substrate`. The command differs only
  in its ending, so use your backend's block below; each is complete and
  paste-ready, as `create-cluster.sh` step 3 runs it.

**docker backend:**

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

**tbx:** the same command with a LoadBalancer ending (plus host routing so the VIP
is reachable from your laptop), then one required post step:

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
  --set ingressController.service.type=LoadBalancer \
  --set bpf.hostLegacyRouting=true

# REQUIRED on tbx: without a CiliumLoadBalancerIPPool and a
# CiliumL2AnnouncementPolicy, cilium-ingress sits in <pending> forever.
# This applies both, waits for the rollout, and proves the VIP got .200:
mise run cluster:create -- --post-cni
```

(Don't re-run the bare `mise run cluster:create`; on tbx it refuses over an
existing cluster. `l2announcements` and the raised rate limit are set on both
backends so `cilium config view` reads the same everywhere; only tbx actually
announces.)

The ingress flags at the end of each block are the shared **ingress** that serves
every `*.cloudbox.k8s.test` hostname for the rest of the day; `verify.sh` checks
for it. The script builds them from `cilium_ingress_values()` in `scripts/lib.sh`.

- Then watch: `kubectl -n kube-system rollout status ds/cilium` and your
  `kubectl get nodes -w` terminal.

**A node stays `NotReady` for more than a few minutes?** Usually a stalled image pull,
not Cilium. Ask the node:

```bash
talosctl -n <node-ip> -e <node-ip> service kubelet    # or: service etcd
```

A service in `Preparing` whose byte count hasn't moved between two looks is a stalled
pull. Power-cycle the node; the disk survives, the pull restarts:

```bash
talosctl -n <node-ip> -e <node-ip> reboot --wait=false
# or, from the outside (tbx):
tbx node stop  cloudbox cloudbox-worker-1             # or cloudbox-cp-1
tbx node start cloudbox cloudbox-worker-1
# or, from the outside:
docker restart cloudbox-worker-1                      # docker backend only
```

(`tbx status cloudbox` and `tbx doctor` name a stalled service too,
randax/talos-box#482. After an in-guest reboot the node shows as `rebooted` in
`tbx status` for 15 minutes; that is a configured node, not a problem.)
</details>

<details>
<summary>Hint 4: Proving the Cilium / no-kube-proxy story</summary>

- Cilium health, without extra tools:
  `kubectl -n kube-system get pods -l k8s-app=cilium` and `cilium status --wait`.
- kube-proxy is absent: `kubectl -n kube-system get ds,pods | grep -c kube-proxy` finds
  nothing. Yet `kubectl get svc -A` shows Services with ClusterIPs that work.
- Ask Cilium who handles Services:
  `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i kubeproxy`.
  Look for `KubeProxyReplacement: True`. eBPF programs in the kernel are doing what
  iptables rules used to do.
- One more: Cilium reaches the API server via `localhost:7445`. That's Talos
  **KubePrism**, a node-local API-server load balancer. Find it in the machine config.
</details>

<details>
<summary>Full solution</summary>

```bash
mise run cluster:create -- --skip-cilium
kubectl get nodes                # NotReady: no CNI, by your own choice

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
# the tbx ending, then run the post step, the pool and policy the VIP needs:
#   --set ingressController.service.type=LoadBalancer \
#   --set bpf.hostLegacyRouting=true
# mise run cluster:create -- --post-cni

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

## Explain-back

Tell your neighbor: this node has no SSH and no package manager. Name two concrete
operational problems that design deletes.

## Going deeper

- Break a node on purpose and put it back, with `kubectl get nodes -w` running: the
  worker goes `NotReady` in ~40 s.

  <details>
  <summary>talos-box (VMs)</summary>

  ```bash
  tbx node stop  cloudbox cloudbox-worker-1   # power it off; the disk survives
  tbx status cloudbox                          # phase: stopped
  tbx node start cloudbox cloudbox-worker-1   # boot it again
  ```
  </details>

  <details>
  <summary>Docker backend (containers)</summary>

  ```bash
  docker pause   cloudbox-worker-1   # Docker backend only
  docker unpause cloudbox-worker-1   # Docker backend only
  ```
  </details>
- `talosctl read /proc/version` works. Now try to *write* something. What stops you?
- Compare `kubectl -n kube-system get pods` here with any managed-cloud cluster. What's
  missing here, and what does the cloud hide there?

## If it goes wrong

The cluster is disposable: destroy and recreate takes ~5 minutes (images are local). Name
the backend on both halves, since the destroy removes `~/.cloudbox/substrate`:

```bash
CLOUDBOX_SUBSTRATE=docker mise run cluster:destroy && \
CLOUDBOX_SUBSTRATE=docker mise run cluster:create     # or =tbx, whichever you are on
```

If Talos-in-Docker fights your machine specifically, `mise run cluster:fallback` gives
you a kind+Cilium cluster with the same ingress and hostnames. You lose the Talos
exploration but every later module works the same. Remove it with
`./scripts/kind-fallback.sh --delete`; rebuild it by running the script again
(`destroy-cluster.sh` refuses on kind, which is a lifeboat, not a backend). On the
lifeboat this module's `verify.sh` prints "not gradeable here" and exits 0; every later
module grades normally.
