# Rehearsal 6: first end-to-end on tbx (2026-08-28)

The first run of the VM substrate through the labs, on Apple Silicon, with the
container images still served from the crane container on `localhost:5001`
(reached from the VMs over the Colima hop; the arrangement issue #206 has since
replaced with tbx's own mirror). Eight labs, one cluster.

| | rehearsal 6 (tbx) |
|---|---|
| `create-cluster.sh`: VMs up, config applied, etcd bootstrapped | **94 s** |
| both nodes `Ready` | **~6 min** |
| eight labs (01–08), wall clock | **~1 h 33 min** |
| manual interventions | **1**, a node reboot after a stalled image pull |
| ingress VIP | short blackouts from the host, mitigated with retries in the git helper |

**The stall.** Both nodes sat `NotReady` well past the Cilium rollout; `talosctl
service kubelet` (and `etcd` on the control plane) showed `Preparing` with a byte
count that stopped moving on a ~60 MiB blob. The pull path was Talos VM → vmnet
→ macOS → Colima VM → registry container, and a manual reboot of the node
restarted the pull and the cluster came up. That is the cost recorded in
`docs/HAZARDS.md` under the mirror entry, and the reason the tbx substrate now
pulls through tbxd's mirror on the gateway address (issue #206) and lab 01
carries the stall-recovery paragraph (issue #207). talos-box's stall signal
(randax/talos-box#482) is what lets `create-cluster.sh` do that reboot itself
(issue #208, blocked on v0.1.2).

**The VIP.** `172.30.<n>.200` dropped off for seconds at a time from the host;
the git helper was patched to retry and the labs went on. Cause unknown; issue
#209 is the 30-minute hammer-and-correlate experiment (Cilium L2 lease
renewals, `bpf.hostLegacyRouting`, `k8sClientRateLimit`), paired with
randax/talos-box#484 on a curated cluster to split "substrate property" from
"our values".

**What it does not say.** Modules 09 and 10 were not reached, nothing was run
offline, and the mirror-through-tbx path did not exist yet. Rehearsal 7 is the
first run that can retire any of that.
