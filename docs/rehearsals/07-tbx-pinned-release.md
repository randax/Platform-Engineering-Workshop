# Rehearsal 7: the full tbx path on the pinned release (2026-08-29)

The run that PR #223's bump of talos-box to **v0.1.4** owed under
`docs/MAINTENANCE.md` step 4. Apple Silicon, 32 GB, 10 CPUs, macOS with two LLM
review agents and a Codex run sharing the laptop for most of it. First run with
the images served from **tbxd's own mirror** (issue #206), no Docker involved,
and the first to reach modules 09 and 10 on tbx.

| | rehearsal 7 (tbx v0.1.4) |
|---|---|
| `cloudbox-init.sh --yes`: 76 refs into tbx's mirror (`--jobs` default 8) + the Talos disk image | 76 warmed, 0 failed |
| `install.sh --check` | all ✅ except the 40 GB free-disk floor (36 GB free, under it) |
| `create-cluster.sh`: VMs, config, bootstrap, Cilium, both nodes `Ready`, VIP (= lab 01; its `verify.sh` passed on the fresh cluster, both nodes `configured`) | **2 min 05 s** |
| `bootstrap-gitops.sh` | 1 min 03 s |
| `seed-gitea.sh` | 8 s |
| labs 02–10, `solve.sh` then `verify.sh` each | 02 · 9 s, 03 · 67 s, 04 · 54 s, 05 · 67 s, 06 · 79 s, 07 · 46 s (second attempt), 08 · 45 s, 09 · 57 s, 10 · 120 s (inject → solve → verify) |
| manual recovery actions | **0** (the cluster healed itself); lab re-runs: **1** (07, see below) |
| ingress VIP | 30/30 one-second probes answered once the node was back; unreachable from the host during the reboot below |

**Module 08's mirror path is offline-proven** (the rest of the offline story is
not; see below). Its golang base, the `public.ecr.aws` image on the list
that a host-side `crane` has to read, is reachable host-side through the catch-all port's path form, new in
v0.1.4 (gateway `172.30.0.1` here because this cluster got subnet index 0;
lab 08 derives it from `tbx status`):
`curl -I http://172.30.0.1:5059/v2/public.ecr.aws/docker/library/golang/manifests/1.25-alpine`
→ 200, still 200 after `tbx mirror offline on` (an uncached tag → 404), and
`crane manifest --insecure 172.30.0.1:5059/public.ecr.aws/docker/library/golang:1.25-alpine`
returns the index. That resolves the module-08 trap in `docs/HAZARDS.md`.

**The reboot.** (Times below are local, CEST = UTC+2, except where marked Z.)
During lab 07's `crane copy` to Zot the VIP reset connections at 22:01:55
and the copy died with `network is unreachable`; `tbx status` then showed
`cloudbox-cp-1` in the new **`rebooted`** phase, `tbx doctor` WARNed
"rebooted at 2026-08-29T20:02:27Z" (when tbxd *observed* the change), and
tbxd.log's own line has Talos `boot_time` moving from epoch 1788033115 to
1788033738 = 20:02:18Z (22:02:18 local) while the VM process stayed up. **Cause not
captured**: the guest's own logs only show the new boot. Concurrent evidence,
recorded not diagnosed: tbxd's balloon line at 22:02:21 read
`compressor=6808MiB` (6.6 GiB; the 21:52 line had 1091 MiB), `hostFree=12698`
(12.4 GiB), `swapUsed=19%`, `pressureLatched=true`, and the control plane's
balloon target (the line is per VM) unchanged at 4096 MiB, so the latch had
armed but had reclaimed nothing from that node, and the host
was busy with two LLM review agents and a Codex run at the time. The cluster
recovered by itself (etcd single node, kubelet `healthy`), lab 07 passed on a
plain re-run, and `lab/01`'s grader, fixed in the same PR to count `rebooted`
as configured, would have failed this healthy cluster on the old
`phase == "configured"` test. `tbx doctor` afterwards: `WARN talos-services`
for the reboot (a WARN never fails doctor), but the run as a whole exited
**non-zero** on `FAIL host-pressure: talosbox data volume is 95% used`. That
was the disk, see below, not the reboot.

**What it does not say.** Nothing was run with the mirror offline except the
path-form probe; the venue-shaped "warm at home, `tbx mirror offline on`,
create" sequence is still unrehearsed end to end. Peak node RSS at the
module-10 end state was not measured (the LIVE memory-ceiling hazard stays
open). And the host was **under** the 40 GB disk floor throughout: by the end
`tbx doctor` FAILed `host-pressure` at 95% data-volume use, a rule v0.1.3
already had, which is a detection-flipping FAIL: had it tripped before
`create-cluster.sh`, detection would have chosen docker and said so with
doctor's first FAIL line (`tbx not used: …`), next to the preflight's own ❌
for the 40 GB floor. The two floors guard the same disk from two sides.
