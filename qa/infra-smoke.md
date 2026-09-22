# QA Runbook: workshop infra smoke

| | |
|---|---|
| **Tier** | Infra smoke ("did anything rot") |
| **Target** | Platform-Engineering-Workshop, this checkout |
| **Estimated duration** | ~20 min (assumes `cloudbox-init.sh` has already populated the mirror) |
| **Destructive** | Creates/destroys the cloudbox cluster; never touches the mirror volume |
| **Runbook version** | record `git rev-parse HEAD` of this checkout in your report |

## How to execute this runbook (agent instructions)

You are running QA, not demos. For every charter: run the steps exactly, compare against **Expected observations**, and record **PASS**, **FAIL**, or **PASS-with-friction**. Friction is anything a careful human would frown at — a confusing message, doc/behavior drift, output that is technically correct but misleading — and is a first-class result even on passing charters. Never improvise recovery mid-charter: capture the evidence under **On failure**, mark FAIL, continue unless a dependency is stated.

**Report destination**: one GitHub issue per run on `randax/Platform-Engineering-Workshop`, label `qa-run`, title `QA infra-smoke <date>`, using the template at the bottom.

## Preflight

Report BLOCKED (not FAIL) if these don't hold:

1. Docker daemon running; `docker ps` works.
2. Mirror container `cloudbox-mirror` exists and `curl -s localhost:5001/v2/_catalog` returns JSON (if not: `cloudbox-init.sh` has not been run — that's home-prep, out of smoke scope).
3. Pinned CLIs on PATH via mise: `talosctl version --client`, `kubectl version --client`, `helm version`, `crane version`, `jq --version` all succeed.
4. No cloudbox cluster running (`docker ps --format '{{.Names}}' | grep -c cloudbox-` returns only the mirror); if leftovers exist, run `./scripts/destroy-cluster.sh` first.

## Charters

### C1 — Environment gate

**Goal**: the go/no-go gate passes exactly as an attendee would see it.

Steps:
1. `./scripts/install.sh --check`

Expected observations: exit 0; the counters report 3/3 host images, 65/65 mirror images, architecture-matched (the amd64-only Backstage image exempt); NodePorts 30300/30080/30500/30600/30700/30900/31080 free; pinned CLI versions match `scripts/versions.env`.

Pass criteria: exit code 0.

On failure: capture the full output; note exactly which counter or check failed.

### C2 — First cluster: module 01 solve→verify (depends on C1)

**Goal**: the core rails stand — Talos-in-Docker cluster with Cilium, from the canonical solution.

Steps:
1. `./lab/01-cluster/solve.sh` (record duration)
2. `./lab/01-cluster/verify.sh`

Expected observations: solve completes without error; verify exits 0; `kubectl get nodes` shows 2 Ready nodes; the Cilium DaemonSet is fully available; no kube-proxy pods exist; `cilium-dbg status` (via the cilium CLI) reports `KubeProxyReplacement: True`.

Pass criteria: both scripts exit 0 within 15 min combined.

On failure: capture both exit codes, `kubectl get nodes,pods -A -o wide`, and the last 50 lines of solve output.

### C3 — Offline leak sentinels (depends on C1; independent of C2)

**Goal**: the two known at-venue network leaks are answerable by the local mirror before anyone is offline.

Steps:
1. `crane manifest localhost:5001/library/busybox:1.37.0 >/dev/null && echo busybox-ok` — module 07's build base, which the module docs source from Docker Hub despite the mirror carrying it.
2. `crane manifest localhost:5001/docker/library/golang:1.25-alpine >/dev/null && echo golang-ok || echo golang-MISSING` — module 08 going-deeper's base image, **known absent from images.txt**.

Expected observations: step 1 prints `busybox-ok`. Step 2 is expected to print `golang-MISSING` today — report it as the standing known gap (workshop must either add it to `images.txt` or keep that path documented online-only); if it prints `golang-ok`, the gap was fixed — note that as a change.

Pass criteria: step 1 succeeds. Step 2 has no pass/fail — record its state either way.

On failure: capture crane's error and `curl -s localhost:5001/v2/_catalog | jq .` output.

### C4 — Cleanup (always run)

**Goal**: leave the machine mirror-warm but cluster-free.

Steps:
1. `./scripts/destroy-cluster.sh`
2. `curl -s localhost:5001/v2/_catalog | jq '.repositories | length'`

Expected observations: cluster containers gone; the mirror still answers with a non-empty catalog (destroy must never touch the mirror volume).

Pass criteria: no `cloudbox-` cluster containers remain; mirror catalog non-empty.

On failure: list what was left behind, exactly.

## Report template

```markdown
## QA infra-smoke — <date>

- workshop commit:
- host (OS, arch, Docker variant):
- Preflight: OK | BLOCKED (<why>)

| Charter | Verdict | Duration | Notes |
|---|---|---|---|
| C1 gate | | | |
| C2 module-01 | | | |
| C3 leak sentinels | | | golang base: present/missing |
| C4 cleanup | | | |

### Friction log
<numbered; every PASS-with-friction and any doc drift, quoted exactly>

### Failures
<per failure: charter, step, expected vs observed, evidence>
```
