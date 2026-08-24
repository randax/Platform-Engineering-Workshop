# talos-box Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `tbx` (talos-box) real Talos VMs the primary workshop substrate on Apple Silicon macOS and Linux/KVM, with `talosctl cluster create docker` kept as a first-class, CI-proven fallback — one lab text, one URL scheme (`*.cloudbox.k8s.test`), one `verify.sh` contract, one image mirror.

**Architecture:** `scripts/create-cluster.sh` becomes a dispatcher that resolves `CLOUDBOX_SUBSTRATE` ∈ `{tbx, docker}`, persists the answer to `~/.cloudbox/substrate`, and sources one of `scripts/substrate/docker.sh` (today's code, moved verbatim) or `scripts/substrate/tbx.sh` (new). Both backends produce the same contract: context `admin@cloudbox`, 1 CP + 1 worker on Talos v1.13.8, `cni: none` + `proxy.disabled: true`, the registry-mirror patch, Cilium 1.20.0 from the vendored chart, and the exports `CLOUDBOX_HOST_GATEWAY` / `CLOUDBOX_API_ENDPOINT`. Reachability moves from nine published NodePorts to one Cilium shared-ingress endpoint: a real LoadBalancer VIP (`172.30.<n>.200`) on tbx, host-published `80:30880` plus a marked `/etc/hosts` block on docker. Ten `gitops/components/<x>/ingress.yaml` files (`ingressClassName: cilium`) carry the hostname scheme.

**Tech Stack:** bash (`set -euo pipefail`, shellcheck 0.11.0), Talos v1.13.8, Kubernetes 1.36.2, Cilium 1.20.0 (vendored chart `scripts/manifests/cilium-1.20.0.tgz`), ArgoCD v3.5.1, Gitea chart 12.7.0, tbx v0.1.1, mise v2026.8.6, Helm 4.2.4 (`--server-side=false`), crane 0.21.9, kubeconform v0.8.0.

**Spec:** `docs/superpowers/specs/2026-08-24-talos-box-substrate-design.md`

---

## Global Constraints

- Talos is pinned at **v1.13.8** — never 1.12.x (`cni: none` docker clusters hang, talos#12885).
- Cilium is **1.20.0**, installed by us from `scripts/manifests/cilium-1.20.0.tgz` on **both** substrates — never talos-box's curated 1.19.6.
- `scripts/versions.env` is the **single source of version pins**; `mise.toml` pins tools. Never introduce a second place a version is written down, and never `:latest`.
- Every shell script: `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean under the pinned shellcheck 0.11.0, idempotent.
- Check-only flags (`install.sh --check`, `install.sh --print-hosts`, `check-consistency.sh`) **never mutate** anything — no `/etc/hosts` writes, no cluster calls that change state.
- `verify.sh` contract: exit 0 on success, `FAIL:`-prefixed actionable messages, many small checks; every check paired with a `solve.sh` that makes it pass.
- All images pinned and pre-pulled from GHCR/the crane mirror (`scripts/images.txt`); **offline after prework** is a hard requirement. Docker Hub is rate-limited at the venue.
- Ingress endpoint: Cilium shared ingress, host NodePort **30880** on docker (30080 is ArgoCD's), LoadBalancer VIP on tbx.
- `CLOUDBOX_DOMAIN="cloudbox.k8s.test"` — one domain, one hostname scheme, both substrates.
- tbx LB-IPAM pool is `172.30.<n>.200-172.30.<n>.239`; `.200` is the ingress VIP by talos-box convention.
- ArgoCD points **only** at the in-cluster Gitea (`http://gitea-http.gitea.svc.cluster.local:3000/cloudbox/platform.git`) — never at a host URL, never at GitHub.
- Labs state outcomes, not steps; hints stay layered in collapsed `<details>` blocks.
- Windows/WSL2, Codespaces and CI are **docker by construction** (`CLOUDBOX_SUBSTRATE=docker`), and that path stays the CI-proven one.
- No tbx CI in 2026 (needs KVM runners); the go-live gate is a manual rehearsal by **Aug 31**.
- Commit messages follow this repo's style (`feat(scope): …`, `fix(x): …`, `docs: …`) and end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Tests here are `bash -n`, `shellcheck -x --source-path=SCRIPTDIR`, `./scripts/check-consistency.sh`, `helm template`, `kubectl apply --dry-run=client -f`, `kubeconform`, and `bash lab/XX/verify.sh` — there is no `scripts/tests/` or bats convention in this repo, and this plan does not invent one.

---

## Task 1: Substrate helpers in `lib.sh` and the persisted `~/.cloudbox/substrate`

**Files:**
- Modify: `scripts/lib.sh` (append after `mirror_host_endpoint()`, currently ends line 161; before `strip_registry()` at line 168)
- Modify: `scripts/versions.env` (append a `--- Substrate ---` block after the `--- Cluster ---` block that ends at line 45, `TALOS_CPU_FLOOR="2"`)
- Test: `bash -n`, `shellcheck -x --source-path=SCRIPTDIR scripts/lib.sh`, and a throwaway sourcing harness

**Interfaces:**
- Consumes: `CLUSTER_NAME`, `TALOS_SUBNET_GATEWAY` (from `scripts/versions.env`), `uname -s`, `uname -m`, `command -v tbx`, `tbx doctor`
- Produces: `CLOUDBOX_SUBSTRATE_FILE` (`${HOME}/.cloudbox/substrate`), `CLOUDBOX_SUBSTRATE_DEFAULT`, and the functions `substrate_detect()`, `substrate_persist()`, `substrate_current()`, `substrate_resolve()`, `substrate_doctor_reason()`

- [ ] **Step 1: Add the substrate pins to `scripts/versions.env`.** Insert directly after the `TALOS_CPU_FLOOR="2"` line (currently line 45):
```sh

# --- Substrate ---------------------------------------------------------------
# Which machine substrate the cluster runs on. Unset lets create-cluster.sh
# detect (tbx when `tbx doctor` passes on arm64 macOS or Linux/KVM, else
# docker); the answer is written to ~/.cloudbox/substrate so destroy-cluster.sh,
# install.sh --check, lab/00, lab/01, catch-up.sh and context-guard.sh all read
# the SAME answer later instead of re-detecting a machine that has changed.
# CLOUDBOX_SUBSTRATE is deliberately NOT assigned here — versions.env is pure
# assignments and would clobber an attendee's `CLOUDBOX_SUBSTRATE=docker ./...`.
CLOUDBOX_SUBSTRATE_DEFAULT="tbx"             # go-live gate flips this to docker
                                             # if the tbx rehearsal fails
```
- [ ] **Step 2: Write a failing sourcing test.** Create `/tmp/t1.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")" 2>/dev/null || true
source /Users/oyr/projects/Platform-Engineering-Workshop/scripts/lib.sh
declare -F substrate_detect  >/dev/null || { echo "FAIL: no substrate_detect";  exit 1; }
declare -F substrate_persist >/dev/null || { echo "FAIL: no substrate_persist"; exit 1; }
declare -F substrate_current >/dev/null || { echo "FAIL: no substrate_current"; exit 1; }
declare -F substrate_resolve >/dev/null || { echo "FAIL: no substrate_resolve"; exit 1; }
[[ "${CLOUDBOX_SUBSTRATE_FILE}" == "${HOME}/.cloudbox/substrate" ]] || { echo "FAIL: bad file"; exit 1; }
CLOUDBOX_SUBSTRATE=docker; [[ "$(substrate_resolve)" == "docker" ]] || { echo "FAIL: env override ignored"; exit 1; }
echo "ok"
```
- [ ] **Step 3: Run it, expect fail.** `bash /tmp/t1.sh` → `FAIL: no substrate_detect`, exit 1.
- [ ] **Step 4: Append the helpers to `scripts/lib.sh`** immediately after the closing `}` of `mirror_host_endpoint()` (line 161) and before the `strip_registry` comment block (line 163):
```sh
# --- Substrate ------------------------------------------------------------------
# Which machine substrate this cluster runs on: real Talos VMs via talos-box
# (`tbx`) or Talos-in-Docker containers. Both satisfy the same contract, which
# lab/01-cluster/verify.sh asserts; the difference is where the API server and
# the ingress endpoint live. See docs/superpowers/plans/2026-08-24-talos-box-substrate.md.
CLOUDBOX_SUBSTRATE_FILE="${HOME}/.cloudbox/substrate"

# substrate_doctor_reason — the first FAIL line `tbx doctor` printed, or a
# one-liner saying why tbx was not even asked. Read-only; never runs a cluster
# operation. Used by install.sh --check to explain a fallback instead of just
# announcing one.
substrate_doctor_reason() {
  if ! have tbx; then
    echo "tbx is not installed (brew install randax/tap/tbx, or the release tarball on Linux)"
    return 0
  fi
  local out
  out="$(tbx doctor 2>&1 || true)"
  local line
  line="$(printf '%s\n' "${out}" | grep -m1 '^FAIL ' || true)"
  echo "${line:-tbx doctor did not report a FAIL line}"
}

# substrate_detect — the substrate this MACHINE can run, with no persisted
# answer and no override. tbx needs its daemon+helper installed and healthy, so
# `tbx doctor` (which exits non-zero on any FAIL — cmd/tbx/doctor.go:345-347) is
# the gate, not the mere presence of the binary.
substrate_detect() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  if have tbx; then
    case "${os}:${arch}" in
      Darwin:arm64|Linux:x86_64|Linux:aarch64|Linux:arm64|Linux:amd64)
        if tbx doctor >/dev/null 2>&1; then echo "tbx"; return 0; fi ;;
    esac
  fi
  echo "docker"
}

# substrate_persist <tbx|docker> — record the substrate the cluster was CREATED
# on. Everything downstream reads this rather than re-detecting: a laptop that
# loses `tbx doctor` mid-workshop must not make destroy-cluster.sh look for
# docker containers that never existed.
substrate_persist() {
  local value="$1"
  case "${value}" in tbx|docker) ;; *) die "substrate_persist: unknown substrate '${value}'" ;; esac
  mkdir -p "$(dirname "${CLOUDBOX_SUBSTRATE_FILE}")"
  printf '%s\n' "${value}" > "${CLOUDBOX_SUBSTRATE_FILE}"
}

# substrate_current — the persisted answer, or empty when no cluster has been
# created on this machine yet. Never detects; never writes.
substrate_current() {
  [[ -r "${CLOUDBOX_SUBSTRATE_FILE}" ]] || return 0
  tr -d '[:space:]' < "${CLOUDBOX_SUBSTRATE_FILE}"
}

# substrate_resolve — the substrate to USE right now, in precedence order:
#   1. an explicit CLOUDBOX_SUBSTRATE in the environment (the documented escape
#      hatch, e.g. CLOUDBOX_SUBSTRATE=tbx on a machine that failed detection)
#   2. the persisted answer from a previous create
#   3. detection, floored by CLOUDBOX_SUBSTRATE_DEFAULT: when the default is
#      "docker" (the go-live gate having flipped it), detection never upgrades.
substrate_resolve() {
  if [[ -n "${CLOUDBOX_SUBSTRATE:-}" ]]; then
    case "${CLOUDBOX_SUBSTRATE}" in
      tbx|docker) echo "${CLOUDBOX_SUBSTRATE}"; return 0 ;;
      *) die "CLOUDBOX_SUBSTRATE='${CLOUDBOX_SUBSTRATE}' is not 'tbx' or 'docker'" ;;
    esac
  fi
  local persisted
  persisted="$(substrate_current)"
  if [[ -n "${persisted}" ]]; then echo "${persisted}"; return 0; fi
  if [[ "${CLOUDBOX_SUBSTRATE_DEFAULT}" == "docker" ]]; then echo "docker"; return 0; fi
  substrate_detect
}

# cloudbox_host_gateway — the HOST as workloads INSIDE the cluster see it.
# ONE definition, used by both backends and by bootstrap-gitops.sh (kagent's
# Ollama endpoint), catch-up.sh and the labs — each of which runs in its own
# shell long after create-cluster.sh exported CLOUDBOX_HOST_GATEWAY, so it is
# re-derived rather than inherited. Honours an already-exported value first so
# a backend that has just computed it does not pay for a second lookup.
#   tbx     172.30.<n>.1  — the cluster gateway (upstream docs/SPEC.md:186-192)
#   docker  host.docker.internal (macOS/WSL2) or TALOS_SUBNET_GATEWAY (Linux),
#           the same rule mirror_host_endpoint() uses, without scheme or port
cloudbox_host_gateway() {
  if [[ -n "${CLOUDBOX_HOST_GATEWAY:-}" ]]; then echo "${CLOUDBOX_HOST_GATEWAY}"; return 0; fi
  if [[ "$(substrate_resolve)" == "tbx" ]]; then
    local subnet
    subnet="$(tbx status "${CLUSTER_NAME}" -o json 2>/dev/null | jq -r '.subnet // ""')"
    [[ -n "${subnet}" ]] \
      || die "cannot read the tbx cluster subnet — is '${CLUSTER_NAME}' up? (tbx status ${CLUSTER_NAME})"
    echo "${subnet%.*}.1"
  elif [[ -n "${CLOUDBOX_MIRROR_HOST:-}" ]]; then
    echo "${CLOUDBOX_MIRROR_HOST}"
  elif [[ "$(uname -s)" == "Darwin" ]] || is_wsl2; then
    echo "host.docker.internal"
  else
    echo "${TALOS_SUBNET_GATEWAY}"
  fi
}
```
- [ ] **Step 5: Extend the test with the gateway helper.** Add to `/tmp/t1.sh` before the final `echo "ok"`:
```sh
declare -F cloudbox_host_gateway >/dev/null || { echo "FAIL: no cloudbox_host_gateway"; exit 1; }
CLOUDBOX_SUBSTRATE=docker; unset CLOUDBOX_HOST_GATEWAY
[[ -n "$(cloudbox_host_gateway)" ]] || { echo "FAIL: empty gateway on docker"; exit 1; }
```
- [ ] **Step 6: Run the test, expect pass.** `bash /tmp/t1.sh` → `ok`, exit 0.
- [ ] **Step 7: Lint.** `bash -n scripts/lib.sh && shellcheck -x --source-path=scripts scripts/lib.sh` → no output, exit 0.
- [ ] **Step 8: Manual check that detection is honest on this machine.**
```sh
source scripts/lib.sh; echo "detect=$(substrate_detect) resolve=$(substrate_resolve) gw=$(cloudbox_host_gateway) reason=$(substrate_doctor_reason)"
```
  Expected on a macOS machine without tbx: `detect=docker resolve=docker gw=host.docker.internal reason=tbx is not installed (brew install randax/tap/tbx, or the release tarball on Linux)`.
- [ ] **Step 9: Commit.**
```
feat(lib): resolve, persist and explain the cluster substrate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 2: Split `create-cluster.sh` into a dispatcher and `scripts/substrate/docker.sh`

The docker backend must be **behaviour-identical**: this task is a move, not a rewrite. The only new lines are the function wrapper, the `80:30880` publish (Task 5 adds the value; the port list edit happens there), and the exports.

**Files:**
- Create: `scripts/substrate/docker.sh` (from `scripts/create-cluster.sh:33-231`, verbatim inside `substrate_create()` / `substrate_destroy()`)
- Modify: `scripts/create-cluster.sh` (becomes the dispatcher; lines 1-292 rewritten around the moved body)
- Modify: `scripts/destroy-cluster.sh:39-59` (route the destroy through the backend)
- Test: `bash -n`, `shellcheck`, `git diff` word-diff of the moved body

**Interfaces:**
- Consumes: `substrate_resolve()`, `substrate_persist()` (Task 1), `mirror_running()`, `mirror_host_endpoint()`, `talos_cluster_state_dir()`, `require_workshop_context()`, all `NODEPORT_*` and `TALOS_*` pins
- Produces: `substrate_create()`, `substrate_destroy()`, `substrate_preflight()` in each backend file; exports `CLOUDBOX_HOST_GATEWAY`, `CLOUDBOX_API_ENDPOINT` from `substrate_create()`

- [ ] **Step 1: Write the failing dispatcher test.** Create `/tmp/t2.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
[[ -f "$R/scripts/substrate/docker.sh" ]] || { echo "FAIL: no scripts/substrate/docker.sh"; exit 1; }
grep -q '^substrate_create()' "$R/scripts/substrate/docker.sh" || { echo "FAIL: docker.sh has no substrate_create"; exit 1; }
grep -q '^substrate_destroy()' "$R/scripts/substrate/docker.sh" || { echo "FAIL: docker.sh has no substrate_destroy"; exit 1; }
grep -q 'substrate_resolve' "$R/scripts/create-cluster.sh" || { echo "FAIL: create-cluster.sh is not a dispatcher"; exit 1; }
grep -q 'talosctl cluster create docker' "$R/scripts/create-cluster.sh" && { echo "FAIL: docker code still in the dispatcher"; exit 1; }
echo ok
```
- [ ] **Step 2: Run it, expect fail.** `bash /tmp/t2.sh` → `FAIL: no scripts/substrate/docker.sh`.
- [ ] **Step 3: Create `scripts/substrate/docker.sh`** with this header and the body moved verbatim from `create-cluster.sh:33-231` (stale-context self-heal, stale state dir, `CNI_PATCH`, `MIRROR_PATCH`, CPU sizing, `talosctl cluster create docker`, kubeconfig rewrite):
```sh
#!/usr/bin/env bash
# =============================================================================
# substrate/docker.sh — Talos-in-Docker backend (talosctl cluster create docker)
#
# This is the CI-proven path and the only one Windows/WSL2 and Codespaces can
# take. The body below is create-cluster.sh's, moved verbatim in the substrate
# split — behaviour-identical by construction. Do not "improve" it here: the
# comments in it record bugs that cost whole rehearsals.
#
# Source me from create-cluster.sh / destroy-cluster.sh; do not run me.
# Provides: substrate_preflight, substrate_create, substrate_destroy.
# =============================================================================

substrate_preflight() {
  need talosctl
  need kubectl
  need helm
  need docker
  docker_running || die "Docker daemon is not reachable. Start Docker and re-run."
  # Talos labels every node container with talos.cluster.name=<cluster>
  if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}")" ]]; then
    die "A '${CLUSTER_NAME}' cluster already exists. Run ./scripts/destroy-cluster.sh first."
  fi
}

substrate_create() {
  # LINES 38-231 OF THE PRE-SPLIT create-cluster.sh, INDENTED BY TWO SPACES AND
  # OTHERWISE UNTOUCHED. Extract them mechanically rather than retyping them —
  # a hand-copy of 194 lines is exactly how a "verbatim move" stops being one:
  #
  #   git show HEAD:scripts/create-cluster.sh | sed -n '38,231p' \
  #     | sed 's/^./  &/' >> scripts/substrate/docker.sh
  #
  # That is: the stale-talosconfig-context self-heal, the stale state-directory
  # removal, CNI_PATCH, the mirror detection and MIRROR_PATCH, the CPU sizing,
  # `talosctl cluster create docker` with its --exposed-ports, and the whole
  # kubeconfig rewrite through `docker port … 6443/tcp`. It ends with
  # `info "kubeconfig: $(kubeconfig_in_use)"`. Do NOT bring require_workshop_context
  # (create-cluster.sh:238) across — the dispatcher calls it after this returns.
  #
  # unset first: cloudbox_host_gateway() short-circuits on an existing value, and
  # a stale export from a previous run would be handed back unchanged.
  unset CLOUDBOX_HOST_GATEWAY
  CLOUDBOX_HOST_GATEWAY="$(cloudbox_host_gateway)"; export CLOUDBOX_HOST_GATEWAY
  export CLOUDBOX_API_ENDPOINT="https://127.0.0.1:${API_PORT}"
}

substrate_destroy() {
  step "Destroying Talos cluster '${CLUSTER_NAME}'"
  if [[ -n "$(docker ps -aq --filter "label=talos.cluster.name=${CLUSTER_NAME}")" ]]; then
    talosctl cluster destroy --name "${CLUSTER_NAME}" --force
    ok "Cluster destroyed"
  else
    warn "No '${CLUSTER_NAME}' cluster found — nothing to destroy"
  fi
  local state_dir
  state_dir="$(talos_cluster_state_dir)"
  if [[ -d "${state_dir}" ]]; then
    rm -rf "${state_dir}"
    ok "Talos cluster state directory removed (${state_dir})"
  fi
}
```
  `cloudbox_host_gateway()` lives in `lib.sh` (Task 1), not here: `bootstrap-gitops.sh`
  needs the same answer from a shell that never sourced a backend.
- [ ] **Step 4: Rewrite `scripts/create-cluster.sh` as the dispatcher** (whole file):
```sh
#!/usr/bin/env bash
# =============================================================================
# create-cluster.sh — module 1: create the CloudBox Talos cluster
#
# Dispatcher. Resolves which SUBSTRATE this machine runs on, sources that
# backend, runs it, then does the shared post-steps (Cilium, ingress objects,
# node Ready wait) that must be identical on both.
#
#   CLOUDBOX_SUBSTRATE=tbx      real Talos VMs via talos-box (default where
#                               `tbx doctor` passes)
#   CLOUDBOX_SUBSTRATE=docker   talosctl cluster create docker (Windows/WSL2,
#                               Codespaces, CI, and any machine tbx fails on)
#
# Unset lets substrate_resolve() in lib.sh decide; the answer is written to
# ~/.cloudbox/substrate so every later script reads the same one.
#
# Environment overrides:
#   CLOUDBOX_SUBSTRATE    force a backend
#   CLOUDBOX_MIRROR_HOST  address where node containers/VMs reach the mirror
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

SUBSTRATE="$(substrate_resolve)"
info "Substrate: ${SUBSTRATE}"
if [[ "${SUBSTRATE}" == "docker" && -z "${CLOUDBOX_SUBSTRATE:-}" && -z "$(substrate_current)" ]]; then
  info "  (tbx not used: $(substrate_doctor_reason))"
fi
# shellcheck source=substrate/docker.sh
source "${SCRIPT_DIR}/substrate/${SUBSTRATE}.sh"

substrate_preflight
substrate_create
substrate_persist "${SUBSTRATE}"

require_workshop_context

# THE SHARED POST-STEPS, moved from the pre-split create-cluster.sh unchanged
# except where a later task names the change:
#
#   git show HEAD:scripts/create-cluster.sh | sed -n '240,292p' >> scripts/create-cluster.sh
#
#   :240-251  "Waiting for the Kubernetes API" — the --request-timeout=5s loop
#   :253-277  the Cilium helm install       — Task 6 replaces the value list
#   :279-283  wait_rollout + kubectl wait --for=condition=Ready nodes --all
#   :285-292  the "you now own a cloud" banner and next-steps lines
#
# Task 7 inserts `substrate_post_cni` between the helm install and the rollout
# wait; Task 12 inserts the /etc/hosts write after it.
```
- [ ] **Step 5: Route `destroy-cluster.sh` through the backend.** Replace lines 39-59 (the `step "Destroying …"` block and the state-directory block) with:
```sh
SUBSTRATE="$(substrate_resolve)"
info "Substrate: ${SUBSTRATE} (from ${CLOUDBOX_SUBSTRATE_FILE})"
# shellcheck source=substrate/docker.sh
source "${SCRIPT_DIR}/substrate/${SUBSTRATE}.sh"
substrate_destroy
rm -f "${CLOUDBOX_SUBSTRATE_FILE}"
```
  Keep `need talosctl` / `need docker` where they are but make `need docker` conditional: `[[ "${SUBSTRATE}" == "docker" ]] && need docker`. Keep the entire kubeconfig/talosconfig cleanup (lines 61-167) and the mirror block (169-177) unchanged — they are substrate-independent.
- [ ] **Step 6: Prove the move is verbatim.** `git show HEAD:scripts/create-cluster.sh | sed -n '38,231p' > /tmp/old.txt`, then extract the same range from `substrate_create()` in the new file and `diff -w /tmp/old.txt /tmp/new.txt` → only indentation differences, no logic changes.
- [ ] **Step 7: Run the test, expect pass.** `bash /tmp/t2.sh` → `ok`.
- [ ] **Step 8: Lint everything.** `bash -n scripts/create-cluster.sh scripts/destroy-cluster.sh scripts/substrate/docker.sh && shellcheck -x --source-path=scripts scripts/*.sh scripts/substrate/*.sh` → exit 0.
- [ ] **Step 9: End-to-end smoke on docker.** `CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh` then `bash lab/01-cluster/verify.sh` → module 01 green, and `cat ~/.cloudbox/substrate` → `docker`. Then `./scripts/destroy-cluster.sh` → "Cluster destroyed" and the substrate file is gone.
- [ ] **Step 10: Commit.**
```
refactor(scripts): split create-cluster into a dispatcher and a docker backend

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 3: `context-guard.sh` accepts the tbx API endpoint

**Files:**
- Modify: `scripts/context-guard.sh:149-165` (`workshop_api_server`), `:211` (the `expected` line in the failure block)
- Test: a table-driven bash harness over `workshop_api_server`

**Interfaces:**
- Consumes: `TALOS_SUBNET_GATEWAY` (already sourced at `context-guard.sh:73`)
- Produces: `workshop_api_server()` additionally returning 0 for `https://172.30.<n>.<h>:6443`

- [ ] **Step 1: Write the failing test.** Create `/tmp/t3.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
source /Users/oyr/projects/Platform-Engineering-Workshop/scripts/context-guard.sh
rc=0
for good in "https://127.0.0.1:54321" "https://localhost:54321" "https://10.5.0.2:6443" \
            "https://172.30.0.2:6443" "https://172.30.7.2:6443" "https://172.30.12.3:6443"; do
  workshop_api_server "$good" || { echo "FAIL: rejected $good"; rc=1; }
done
for bad in "https://10.0.0.5:6443" "https://k8s.corp.example.com:6443" "https://172.31.0.2:6443" \
           "https://172.30.0.2:443" ""; do
  workshop_api_server "$bad" && { echo "FAIL: accepted $bad"; rc=1; }
done
[[ $rc -eq 0 ]] && echo ok
exit $rc
```
- [ ] **Step 2: Run it, expect fail.** `bash /tmp/t3.sh` → three `FAIL: rejected https://172.30.…` lines, exit 1.
- [ ] **Step 3: Extend `workshop_api_server`.** Replace `context-guard.sh:149-165` with:
```sh
# workshop_api_server <server-url> — true for an API server address that a
# CloudBox cluster on this machine can legitimately have:
#   https://127.0.0.1:<port>  the docker substrate: create-cluster.sh repoints
#                             the kubeconfig at the controlplane container's
#                             published port, and kind-fallback.sh does the same.
#   https://localhost:<port>  the same address, spelled the other way.
#   https://10.5.0.2:6443     the docker substrate's documented fallback for
#                             when it cannot read the published port (fine on
#                             native Linux): the controlplane's own address
#                             inside TALOS_SUBNET, which is .2 — .1 is gateway.
#   https://172.30.<n>.<h>:6443
#                             the tbx substrate: real VMs on talos-box's own
#                             per-cluster /24 (docs/SPEC.md:186 — "cluster n ->
#                             172.30.<n>.0/24", nodes in .2-.179). There is no
#                             `docker port` rewrite there: the control plane IS
#                             routable from the host, so the kubeconfig carries
#                             the node address. 172.30.0.0/16 is RFC1918 and
#                             talos-box-owned; a corporate cluster reachable at
#                             one of these would need to be on the same laptop.
workshop_api_server() { # <server-url>
  case "$1" in
    https://127.0.0.1:[0-9]*|https://localhost:[0-9]*) return 0 ;;
    "https://${TALOS_SUBNET_GATEWAY%.*}.2:6443")       return 0 ;;
  esac
  # Pattern-matched rather than globbed: bash globs cannot express "1-3 digits".
  [[ "$1" =~ ^https://172\.30\.[0-9]{1,3}\.[0-9]{1,3}:6443$ ]]
}
```
- [ ] **Step 4: Update the `expected` line** at `context-guard.sh:211`:
```sh
  expected        : admin@${CLUSTER_NAME} (or kind-${CLUSTER_NAME}) on https://127.0.0.1:<port> (docker) or https://172.30.<n>.<h>:6443 (tbx)
```
- [ ] **Step 5: Run the test, expect pass.** `bash /tmp/t3.sh` → `ok`, exit 0.
- [ ] **Step 6: Lint.** `shellcheck -x --source-path=scripts scripts/context-guard.sh` → exit 0. (`[[ =~ ]]` needs no quoting change; shellcheck 0.11.0 accepts an unquoted RHS regex.)
- [ ] **Step 7: Prove the guard still refuses a foreign cluster.**
```sh
kubectl config set-cluster fake --server=https://k8s.corp.example.com:6443
kubectl config set-context admin@cloudbox --cluster=fake --user=admin@cloudbox
bash -c 'source scripts/lib.sh; require_workshop_context'
```
  Expected: `❌ FAIL: refusing to touch this cluster — context 'admin@cloudbox' points at https://k8s.corp.example.com:6443, which is not a cluster on this machine.` exit 1. Undo with `kubectl config delete-cluster fake`.
- [ ] **Step 8: Commit.**
```
feat(context-guard): accept the tbx substrate's 172.30.x.x:6443 endpoint

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 4: tbx pins, the generated `cloudbox.tbx.yaml`, and the pin-drift check

The cluster yaml is **generated from `versions.env`**, never hand-edited — §4 of the spec is explicit that the sizing numbers must not become a second source of truth.

**Files:**
- Modify: `scripts/versions.env` (extend the `--- Substrate ---` block from Task 1)
- Modify: `mise.toml` (`[tools]`, after the `shellcheck = "0.11.0"` entry)
- Create: `scripts/substrate/cloudbox.tbx.yaml.tmpl` (the template) — the rendered file is written to `${HOME}/.cloudbox/cloudbox.tbx.yaml` at create time, not committed
- Modify: `scripts/check-consistency.sh` (new check 10, appended before the final verdict block)
- Test: `./scripts/check-consistency.sh`, plus a render + `tbx up -f … --help`-free parse check

**Interfaces:**
- Consumes: `TALOS_VERSION`, `CLUSTER_NAME`, `CLOUDBOX_DOMAIN`
- Produces: `TBX_VERSION`, `TBX_CP_MEMORY`, `TBX_CP_CPUS`, `TBX_WORKER_MEMORY`, `TBX_WORKER_CPUS`, `TBX_DISK_SIZE`, `TBX_CLUSTER_FILE`, and `render_tbx_cluster_file()` in `scripts/substrate/tbx.sh` (Task 5 consumes it)

- [ ] **Step 1: Add the tbx pins to `scripts/versions.env`**, appended to the Task-1 block:
```sh
# talos-box (`tbx`) — the VM substrate. Pinned like everything else; see
# docs/MAINTENANCE.md for the bump procedure. Install: `brew install
# randax/tap/tbx` then `sudo tbx system install` (macOS), or the release
# tarball + the systemd helper (Linux, docs/linux.md upstream).
TBX_VERSION="v0.1.1"

# VM sizing. UNREHEARSED as of 2026-08-24 — the rehearsal in the plan's last
# task measures peak RSS at the module-10 end state and these numbers are what
# it corrects. scripts/substrate/cloudbox.tbx.yaml.tmpl is rendered FROM them,
# so the yaml is never a second place the sizes are written down.
# Host floor stays 16 GB (MIN_DOCKER_MEMORY_GB is docker-only).
TBX_CP_MEMORY="4GiB"
TBX_CP_CPUS="4"
TBX_WORKER_MEMORY="8GiB"
TBX_WORKER_CPUS="4"                          # raised to max(4, NCPU-2) at render
TBX_DISK_SIZE="20GiB"
TBX_CLUSTER_FILE="${HOME}/.cloudbox/cloudbox.tbx.yaml"

# One domain for every workshop URL, on both substrates. On tbx this is
# talos-box's own cluster domain (`domain:` in the cluster yaml), whose
# wildcard resolves to the cluster's .200 ingress VIP (docs/SPEC.md:213-216).
# On docker it is a marked block in /etc/hosts pointing at 127.0.0.1.
CLOUDBOX_DOMAIN="cloudbox.k8s.test"

# Cilium's shared ingress on the docker substrate. 30880, NOT 30080 — that is
# ArgoCD's existing NodePort. create-cluster.sh publishes host 80 -> 30880 so
# the hostnames work without a port suffix on both substrates.
NODEPORT_INGRESS="30880"
```
- [ ] **Step 2: Add the mise pin.** Insert after `shellcheck = "0.11.0"` in `mise.toml [tools]`:
```toml
# talos-box — the VM substrate (scripts/substrate/tbx.sh). Keep in sync with
# TBX_VERSION in scripts/versions.env; check-consistency.sh check 10 enforces it.
"ubi:randax/talos-box" = "0.1.1"
```
- [ ] **Step 3: Verify mise can actually resolve that backend.** `mise install "ubi:randax/talos-box@0.1.1"` and `mise x "ubi:randax/talos-box@0.1.1" -- tbx version`. Expected: `tbx 0.1.1 (darwin/arm64, daemon protocol N)`. **If ubi cannot find a matching release asset** (talos-box publishes via a Homebrew tap and a source build; `README.md` "Cloudsmith apt/dnf repositories, the AUR `tbx-bin` package, and the Nix flake are planned release channels but are not published yet"), replace the `[tools]` entry with a comment-form pin in the same place:
```toml
# talos-box is installed out-of-band (brew install randax/tap/tbx on macOS, the
# release tarball on Linux) — no mise backend publishes it yet (upstream #95/#96/#101).
# tbx = "0.1.1"
```
  and make Step 5's check read the comment form too. Record which branch you took in the commit body.
- [ ] **Step 4: Create `scripts/substrate/cloudbox.tbx.yaml.tmpl`.** `__PLACEHOLDER__` tokens are substituted by `render_tbx_cluster_file()` in Task 5:
```yaml
# GENERATED — do not edit. Rendered from scripts/versions.env by
# render_tbx_cluster_file() in scripts/substrate/tbx.sh into ${TBX_CLUSTER_FILE}.
# Edit the TBX_* pins in versions.env instead; this file is a projection of them.
#
# Deliberately SUBSTRATE-ONLY: no `cni:` key. talos-box then stops after VMs,
# networking, DNS and image delivery (upstream docs/SPEC.md:19-21) and leaves
# machine config, bootstrap and CNI to us — which is what keeps ONE Cilium
# 1.20.0 install path across both substrates. Adding `cni: cilium` here would
# hand the cluster talos-box's curated 1.19.6 and its own machine config.
# No `csi:` either (it requires `cni:`); local-path-provisioner is wave 0.
version: 1
talos:
  version: __TALOS_VERSION__
clusters:
  - name: __CLUSTER_NAME__
    controlPlanes: 1
    workers: 1
    domain: __CLOUDBOX_DOMAIN__
    node:
      memory: __TBX_WORKER_MEMORY__
      cpus: __TBX_WORKER_CPUS__
      diskSize: __TBX_DISK_SIZE__
    controlPlane:
      memory: __TBX_CP_MEMORY__
      cpus: __TBX_CP_CPUS__
      diskSize: __TBX_DISK_SIZE__
```
  Field names verified against upstream `internal/config/config.go:94-109` (`name`, `controlPlanes`, `workers`, `domain`, `node`, `controlPlane`, `worker`) and `rawNode` (`memory`, `cpus`, `diskSize`); `talos.version` at `config.go:86`. `cloudbox.k8s.test` needs no `allowUnsafeDomain` — `.test` is on upstream's safe list (`docs/SPEC.md:218-220`).
- [ ] **Step 5: Add check 10 to `scripts/check-consistency.sh`,** inserted after check 9's closing `ok "workshop kubeconfig path agrees …"` line and before the final `echo` / verdict block:
```sh
# --- 10. the tbx pin agrees between versions.env and mise.toml ----------------
# Same rule as check 3, for the substrate that is not Docker. dev-setup.sh
# installs only what mise.toml lists, so a drifted pin means an attendee runs a
# tbx whose cluster-yaml schema or `tbx manifests` sections we never tested.
before_fail=${FAILURES}
tbx_mise="$(mise_pin 'ubi:randax/talos-box')"
if [[ -z "${tbx_mise}" ]]; then
  # Fallback pin form: tbx has no published mise backend yet (upstream #95/#96/
  # #101), so mise.toml may carry it as a commented pin next to the install note.
  tbx_mise="$(sed -nE 's|^#[[:space:]]*tbx[[:space:]]*=[[:space:]]*"([^"]+)".*|\1|p' mise.toml | head -1)"
fi
if [[ -z "${tbx_mise}" ]]; then
  bad "mise.toml records no tbx pin (neither a [tools] entry nor the commented fallback) — TBX_VERSION would be the only copy and dev-setup could install anything"
elif [[ "v${tbx_mise}" != "${TBX_VERSION}" ]]; then
  bad "tbx pin drift: versions.env ${TBX_VERSION} vs mise.toml ${tbx_mise}"
fi
# The cluster yaml must stay a PROJECTION of the pins, never a second source.
if [[ -f scripts/substrate/cloudbox.tbx.yaml ]]; then
  bad "scripts/substrate/cloudbox.tbx.yaml is checked in — the tbx cluster yaml is GENERATED from versions.env into \${TBX_CLUSTER_FILE}; only the .tmpl belongs in git"
fi
for token in __TALOS_VERSION__ __CLUSTER_NAME__ __CLOUDBOX_DOMAIN__ \
             __TBX_CP_MEMORY__ __TBX_CP_CPUS__ __TBX_WORKER_MEMORY__ \
             __TBX_WORKER_CPUS__ __TBX_DISK_SIZE__; do
  grep -q -- "${token}" scripts/substrate/cloudbox.tbx.yaml.tmpl \
    || bad "scripts/substrate/cloudbox.tbx.yaml.tmpl no longer contains ${token} — a sizing value was hardcoded into the template instead of pinned in versions.env"
done
grep -qE '^[[:space:]]+cni:' scripts/substrate/cloudbox.tbx.yaml.tmpl \
  && bad "scripts/substrate/cloudbox.tbx.yaml.tmpl declares a curated 'cni:' — that hands the cluster talos-box's Cilium 1.19.6 and its own machine config; this workshop installs Cilium ${CILIUM_VERSION} itself on BOTH substrates"
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "tbx pin agrees (${TBX_VERSION}) and the cluster yaml is generated from versions.env"
```
- [ ] **Step 6: Run the drift check, expect pass.** `./scripts/check-consistency.sh` → the new line `✅ tbx pin agrees (v0.1.1) and the cluster yaml is generated from versions.env`, and `✅ no drift detected` at the end, exit 0.
- [ ] **Step 7: Prove check 10 bites.** `sed -i.bak 's/^TBX_VERSION="v0.1.1"/TBX_VERSION="v0.9.9"/' scripts/versions.env && ./scripts/check-consistency.sh; mv scripts/versions.env.bak scripts/versions.env` → expect `❌ FAIL: tbx pin drift: versions.env v0.9.9 vs mise.toml 0.1.1` and exit 1, then a clean run after the restore.
- [ ] **Step 8: Update the check-consistency header comment** (`scripts/check-consistency.sh:5-25`) to list check 10 in the `# Checks:` block: `#  10. the tbx pin agrees between versions.env and mise.toml, and the tbx cluster yaml is generated from the pins rather than checked in`.
- [ ] **Step 9: Commit.**
```
feat(versions): pin tbx, its VM sizing and the cloudbox.k8s.test domain

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 5: The `scripts/substrate/tbx.sh` backend

Every `tbx` invocation below is cited to upstream source; **no flag is invented**. Three corrections to the spec's prose, resolved here:
- `tbx up` takes **no cluster positional** — it is file-driven: `tbx up -f <path>` (`cmd/tbx/updown.go:412-425`, `flags`: `-f`, `--force`, `--quiet`).
- **`tbx down` does not delete.** It STOPS (`cmd/tbx/updown.go:371-384` maps the daemon's actions to `stopped %s`), and it has no `--delete` flag. Destroy is `tbx cluster destroy <name> --force` (`cmd/tbx/main.go:461-469`).
- `tbx manifests <cluster> balloon` is **deprecated and errors** (`internal/provision/inspection.go:99-100`), so the virtio_balloon patch is written by us, copied from `internal/manifests/manifests.go:271-278`.

**Files:**
- Create: `scripts/substrate/tbx.sh`
- Test: `bash -n`, `shellcheck`, a render-only dry run, then a real `tbx` create

**Interfaces:**
- Consumes: `TBX_*`, `TALOS_VERSION`, `CLUSTER_NAME`, `CLOUDBOX_DOMAIN`, `MIRROR_PORT`, `mirror_running()`, `wait_rollout()`
- Produces: `substrate_preflight()`, `substrate_create()`, `substrate_destroy()`, `render_tbx_cluster_file()`, `tbx_subnet_index()`, `tbx_node_ip()`; exports `CLOUDBOX_HOST_GATEWAY=172.30.<n>.1`, `CLOUDBOX_API_ENDPOINT=https://172.30.<n>.2:6443`

- [ ] **Step 1: Write the failing contract test.** Create `/tmp/t5.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
F="$R/scripts/substrate/tbx.sh"
[[ -f "$F" ]] || { echo "FAIL: no scripts/substrate/tbx.sh"; exit 1; }
for fn in substrate_preflight substrate_create substrate_destroy render_tbx_cluster_file; do
  grep -q "^${fn}()" "$F" || { echo "FAIL: missing ${fn}"; exit 1; }
done
grep -q 'tbx down .*--delete' "$F" && { echo "FAIL: invented 'tbx down --delete'"; exit 1; }
grep -q 'tbx cluster destroy "\${CLUSTER_NAME}" --force' "$F" || { echo "FAIL: destroy is not 'tbx cluster destroy <n> --force'"; exit 1; }
grep -q 'tbx up -f' "$F" || { echo "FAIL: 'tbx up' must be file-driven (-f)"; exit 1; }
grep -q 'tbx manifests .* balloon' "$F" && { echo "FAIL: uses the deprecated balloon section"; exit 1; }
echo ok
```
- [ ] **Step 2: Run it, expect fail.** `bash /tmp/t5.sh` → `FAIL: no scripts/substrate/tbx.sh`.
- [ ] **Step 3: Write `scripts/substrate/tbx.sh` — preflight and the rendered cluster file.**
```sh
#!/usr/bin/env bash
# =============================================================================
# substrate/tbx.sh — real Talos VMs via talos-box (`tbx`)
#
# SUBSTRATE-ONLY path: talos-box guarantees VMs, networking, DNS and image
# delivery, and stops there (upstream docs/SPEC.md:19-21). We generate the
# machine config, apply it, bootstrap, and install OUR Cilium 1.20.0 — the same
# sequence the docker backend runs, so one lab text covers both.
#
# Source me from create-cluster.sh / destroy-cluster.sh; do not run me.
# Provides: substrate_preflight, substrate_create, substrate_destroy.
# =============================================================================

substrate_preflight() {
  need talosctl
  need kubectl
  need helm
  need tbx "Install talos-box: 'brew install randax/tap/tbx && sudo tbx system install' (macOS) or the release tarball + systemd helper (Linux). Or run the docker substrate: CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh"
  # `tbx doctor` exits non-zero on any FAIL finding (cmd/tbx/doctor.go:345-347).
  # It checks the helper, resolver, DNS wiring, forwarding, routes, host
  # pressure, mirror health and external image access — all of which the
  # workshop needs and none of which a bare binary proves.
  if ! tbx doctor; then
    die "'tbx doctor' reports problems (above). Fix them, or run the fallback substrate: CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh"
  fi
  if tbx status "${CLUSTER_NAME}" >/dev/null 2>&1; then
    die "A '${CLUSTER_NAME}' tbx cluster already exists. Run ./scripts/destroy-cluster.sh first."
  fi
}

# render_tbx_cluster_file — project the TBX_* pins onto the template. The
# worker CPU count is the one value that scales with the host, for the same
# reason the docker backend uncaps its containers (versions.env, TALOS_CPU_FLOOR):
# a fixed small number throttles the module-10 end state on a big laptop.
# max(TBX_WORKER_CPUS, NCPU-2) — two cores left for the host and tbxd.
render_tbx_cluster_file() {
  local ncpu workers_cpus
  ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
  workers_cpus="$(awk -v n="${ncpu}" -v floor="${TBX_WORKER_CPUS}" \
    'BEGIN { c = int(n) - 2; if (c < floor) c = floor; printf "%d", c }')"
  mkdir -p "$(dirname "${TBX_CLUSTER_FILE}")"
  sed -e "s|__TALOS_VERSION__|${TALOS_VERSION}|g" \
      -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
      -e "s|__CLOUDBOX_DOMAIN__|${CLOUDBOX_DOMAIN}|g" \
      -e "s|__TBX_CP_MEMORY__|${TBX_CP_MEMORY}|g" \
      -e "s|__TBX_CP_CPUS__|${TBX_CP_CPUS}|g" \
      -e "s|__TBX_WORKER_MEMORY__|${TBX_WORKER_MEMORY}|g" \
      -e "s|__TBX_WORKER_CPUS__|${workers_cpus}|g" \
      -e "s|__TBX_DISK_SIZE__|${TBX_DISK_SIZE}|g" \
      "${SCRIPT_DIR}/substrate/cloudbox.tbx.yaml.tmpl" > "${TBX_CLUSTER_FILE}"
  info "Rendered ${TBX_CLUSTER_FILE} (worker: ${workers_cpus} CPUs, ${TBX_WORKER_MEMORY}; CP: ${TBX_CP_CPUS} CPUs, ${TBX_CP_MEMORY})"
}

# tbx_subnet_index / tbx_node_ip — read the cluster's facts from `tbx status
# -o json` rather than assuming. Node addresses are NOT tied to creation order
# (upstream README "Lifecycle": on macOS the address is a vmnet DHCP lease keyed
# by the node's MAC, so a node can come up anywhere in .2-.179), so the control
# plane's address must be READ, never computed. The subnet index IS stable and
# is what the .1 gateway and the .200-.239 LB pool are derived from
# (docs/SPEC.md:186-192; internal/manifests/manifests.go:57-59).
tbx_subnet_index() {
  tbx status "${CLUSTER_NAME}" -o json | jq -r '.subnet | split(".")[2]'
}
tbx_node_ip() { # <control-plane|worker>
  tbx status "${CLUSTER_NAME}" -o json \
    | jq -r --arg role "$1" '[.nodes[] | select(.role == $role) | .ip] | first // ""'
}
```
  `.subnet`, `.nodes[].role`, `.nodes[].ip`, `.nodes[].phase` are the documented JSON fields (`internal/daemon/operations.go:245-306` for `ClusterStatus`, `:169-176` for `NodeStatus`); roles are the literals `control-plane` / `worker` (`internal/cluster/cluster.go:25-26`) and the maintenance phase is `maintenance` (`internal/daemon/phase.go:31`).
- [ ] **Step 4: Add `substrate_create()` to the same file** — bring the VMs up, wait for maintenance, generate + apply config, bootstrap, kubeconfig:
```sh
substrate_create() {
  step "Creating Talos VMs for '${CLUSTER_NAME}' (Talos ${TALOS_VERSION}, via tbx ${TBX_VERSION})"
  render_tbx_cluster_file
  # `tbx up` is file-driven and idempotent — it reconciles reality to the file
  # (cmd/tbx/updown.go:412-425; flags are -f/--force/--quiet only). It holds its
  # answer until the nodes it started answer on apid, up to a bounded boot
  # budget, and narrates its stages to stderr.
  tbx up -f "${TBX_CLUSTER_FILE}"

  step "Waiting for both nodes to reach Talos maintenance mode"
  local waited=0 unconfigured
  while [[ "${waited}" -lt 300 ]]; do
    unconfigured="$(tbx status "${CLUSTER_NAME}" -o json \
      | jq -r '[.nodes[] | select(.phase == "maintenance")] | length')"
    [[ "${unconfigured}" == "2" ]] && break
    sleep 5; waited=$((waited + 5))
  done
  [[ "${unconfigured}" == "2" ]] \
    || die "Only ${unconfigured}/2 nodes reached maintenance mode after ${waited}s — 'tbx status ${CLUSTER_NAME}' and 'tbx console ${CLUSTER_NAME} ${CLUSTER_NAME}-cp-1' show why"

  local idx cp_ip worker_ip
  idx="$(tbx_subnet_index)"
  cp_ip="$(tbx_node_ip control-plane)"
  worker_ip="$(tbx_node_ip worker)"
  [[ -n "${cp_ip}" && -n "${worker_ip}" ]] \
    || die "Could not read node addresses from 'tbx status ${CLUSTER_NAME} -o json'"
  export CLOUDBOX_HOST_GATEWAY="172.30.${idx}.1"
  export CLOUDBOX_API_ENDPOINT="https://${cp_ip}:6443"
  info "Subnet 172.30.${idx}.0/24 — gateway ${CLOUDBOX_HOST_GATEWAY}, CP ${cp_ip}, worker ${worker_ip}"

  step "Generating the machine config (our patches, our sequence)"
  local workdir; workdir="$(mktemp -d)"
  # SAME cni:none / proxy:disabled / node-label / local-path-mount patch as the
  # docker backend. One copy would be nicer; two identical heredocs is what
  # keeps each backend readable in isolation, and check-consistency.sh check 11
  # (Task 6) asserts they stay byte-identical.
  local cni_patch mirror_patch balloon_patch
  cni_patch="$(cat <<'EOF'
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
machine:
  # Every cloud region had to start somewhere.
  nodeLabels:
    cloudbox.io/region: eu-laptop-1
    cloudbox.io/zone: under-desk-a
  kubelet:
    extraMounts:
      # local-path-provisioner writes PV data here; without this bind mount
      # every PVC on Talos stays Pending (kubelet cannot reach the host path).
      - destination: /var/local-path-provisioner
        type: bind
        source: /var/local-path-provisioner
        options: [bind, rshared, rw]
EOF
)"
  # virtio_balloon: tbxd's balloon manager needs the module loaded in the guest
  # (upstream internal/manifests/manifests.go:271-278). `tbx manifests <c>
  # balloon` is DEPRECATED and errors (internal/provision/inspection.go:99-100),
  # and `tbx manifests <c> machine` would also drag in Longhorn's kubelet mount
  # we do not use — so the two lines live here.
  balloon_patch="$(cat <<'EOF'
machine:
  kernel:
    modules:
      - name: virtio_balloon
EOF
)"
  local patches=(--config-patch "${cni_patch}" --config-patch "${balloon_patch}")
  # Two mirror layers, and they do not conflict:
  #   * OUR eight explicit registries -> the crane mirror on the host, reached
  #     at the cluster gateway. skipFallback:false, exactly as on docker.
  #   * tbx's own catch-all "*" -> its pull-through mirror on :5059, which
  #     `tbx manifests <c> mirrors` renders (internal/manifests/manifests.go:
  #     218-230). Explicit entries win over "*", so this only covers registries
  #     our list does not name. Adopting tbx's mirror as the STORE is a spec
  #     non-goal; taking its catch-all costs nothing and is what the spec asks
  #     us to merge.
  if mirror_running; then
    local endpoint="http://${CLOUDBOX_HOST_GATEWAY}:${MIRROR_PORT}"
    info "Image mirror detected — nodes will pull via ${endpoint}"
    mirror_patch="$(printf 'machine:\n  registries:\n    mirrors:\n')"
    local reg
    for reg in docker.io ghcr.io registry.k8s.io quay.io gcr.io public.ecr.aws \
               xpkg.crossplane.io docker.gitea.com; do
      mirror_patch+="$(printf '      %s:\n        endpoints:\n          - %s\n        skipFallback: false\n' "${reg}" "${endpoint}")"
    done
    patches+=(--config-patch "${mirror_patch}")
  else
    warn "cloudbox-mirror registry is not running — nodes will pull from the internet."
    warn "Fine at home; at the venue run ./scripts/cloudbox-init.sh first."
  fi
  patches+=(--config-patch "$(tbx manifests "${CLUSTER_NAME}" mirrors)")

  talosctl gen config "${CLUSTER_NAME}" "${CLOUDBOX_API_ENDPOINT}" \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --output-dir "${workdir}" \
    "${patches[@]}"

  step "Applying the machine config"
  talosctl apply-config --insecure --nodes "${cp_ip}"     --file "${workdir}/controlplane.yaml"
  talosctl apply-config --insecure --nodes "${worker_ip}" --file "${workdir}/worker.yaml"

  step "Bootstrapping etcd"
  export TALOSCONFIG="${workdir}/talosconfig"
  talosctl config endpoint "${cp_ip}"
  talosctl config node "${cp_ip}"
  local i
  for i in $(seq 1 60); do
    talosctl bootstrap >/dev/null 2>&1 && break
    sleep 5
  done
  talosctl bootstrap >/dev/null 2>&1 || talosctl version --nodes "${cp_ip}" >/dev/null \
    || die "etcd never bootstrapped — 'talosctl --talosconfig ${workdir}/talosconfig dmesg' and 'tbx console ${CLUSTER_NAME} ${CLUSTER_NAME}-cp-1'"

  step "Merging kubeconfig"
  # No `docker port` rewrite here: the control plane's own address is routable
  # from the host (upstream docs/SPEC.md "Reachability contract": host <-> node
  # IPs), so what talosctl writes is already correct on every platform.
  talosctl kubeconfig --force
  kubectl config use-context "admin@${CLUSTER_NAME}" >/dev/null
  ok "kubectl context: admin@${CLUSTER_NAME}"
  info "Kubernetes API: ${CLOUDBOX_API_ENDPOINT}"
  info "kubeconfig: $(kubeconfig_in_use)"
  # Keep the talosconfig where `talosctl --context cloudbox dashboard` finds it.
  talosctl config merge "${workdir}/talosconfig"
  rm -rf "${workdir}"
}

substrate_destroy() {
  step "Destroying Talos VMs for '${CLUSTER_NAME}'"
  if tbx status "${CLUSTER_NAME}" >/dev/null 2>&1; then
    # `tbx down` only STOPS a cluster (cmd/tbx/updown.go:371-384) and has no
    # --delete flag. Destroy is its own verb, and --force is its confirmation
    # (cmd/tbx/main.go:461-469).
    tbx cluster destroy "${CLUSTER_NAME}" --force
    ok "Cluster destroyed"
  else
    warn "No '${CLUSTER_NAME}' tbx cluster found — nothing to destroy"
  fi
  rm -f "${TBX_CLUSTER_FILE}"
}
```
- [ ] **Step 5: Add `need jq` to `substrate_preflight()`** — every introspection above goes through `jq`, which is pinned in `mise.toml` but not currently required by `create-cluster.sh`.
- [ ] **Step 6: Run the contract test, expect pass.** `bash /tmp/t5.sh` → `ok`.
- [ ] **Step 7: Lint.** `bash -n scripts/substrate/tbx.sh && shellcheck -x --source-path=scripts scripts/substrate/tbx.sh` → exit 0.
- [ ] **Step 8: Render-only check (no VMs).**
```sh
bash -c 'source scripts/lib.sh; SCRIPT_DIR=scripts; source scripts/substrate/tbx.sh; render_tbx_cluster_file; cat "${TBX_CLUSTER_FILE}"'
```
  Expected: a `version: 1` document with `version: v1.13.8`, `name: cloudbox`, `domain: cloudbox.k8s.test`, `controlPlanes: 1`, `workers: 1`, no `cni:` key, and no `__` placeholders left. Confirm with `grep -c '__' "${HOME}/.cloudbox/cloudbox.tbx.yaml"` → `0`.
- [ ] **Step 9: Real create on an Apple Silicon machine with tbx installed.**
```sh
CLOUDBOX_SUBSTRATE=tbx ./scripts/create-cluster.sh
tbx status cloudbox
kubectl get nodes -o wide
```
  Expected: two nodes, `admin@cloudbox` context, API at `https://172.30.<n>.2:6443`, and `cat ~/.cloudbox/substrate` → `tbx`. Node names will be `talos-*`, not `cloudbox-cp-1` — that is expected Talos behaviour on the substrate-only path (upstream README, "On the substrate-only path you generate the machine config yourself, and Talos assigns each node a random `talos-*` hostname"); do **not** add `machine.network.hostname`, which makes every `apply-config` fail with `static hostname is already set in v1alpha1 config` on Talos 1.13.
- [ ] **Step 10: Commit.**
```
feat(substrate): add the talos-box backend, substrate-only with our own config

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 6: Cilium ingress values on both substrates, and the docker `80:30880` publish

**Files:**
- Modify: `scripts/create-cluster.sh` (the shared Cilium step, moved from `create-cluster.sh:253-277`)
- Modify: `scripts/substrate/docker.sh` (`--exposed-ports`, from `create-cluster.sh:189`)
- Modify: `scripts/check-consistency.sh` (extend check 10 with the CNI-patch identity assertion promised in Task 5)
- Test: `helm template`, `bash lab/01-cluster/verify.sh`, a live `curl`

**Interfaces:**
- Consumes: `SUBSTRATE`, `CILIUM_VERSION`, `NODEPORT_INGRESS`
- Produces: a Cilium release with `ingressController.enabled=true`, `loadbalancerMode=shared`, `l2announcements.enabled=true`, and a per-substrate ingress Service type

- [ ] **Step 1: Write the failing render test.** Create `/tmp/t6.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
source "$R/scripts/versions.env"
common=(--set ipam.mode=kubernetes --set kubeProxyReplacement=true
        --set k8sServiceHost=localhost --set k8sServicePort=7445
        --set cgroup.autoMount.enabled=false --set cgroup.hostRoot=/sys/fs/cgroup
        --set ingressController.enabled=true
        --set ingressController.loadbalancerMode=shared
        --set l2announcements.enabled=true
        --set k8sClientRateLimit.qps=10 --set k8sClientRateLimit.burst=20)
out="$(helm template cilium "$R/scripts/manifests/cilium-${CILIUM_VERSION}.tgz" -n kube-system \
  "${common[@]}" --set ingressController.service.type=NodePort \
  --set ingressController.service.insecureNodePort="${NODEPORT_INGRESS}")"
grep -q 'name: cilium-ingress' <<<"$out" || { echo "FAIL: no cilium-ingress Service"; exit 1; }
grep -q "nodePort: ${NODEPORT_INGRESS}" <<<"$out" || { echo "FAIL: insecureNodePort not honoured"; exit 1; }
grep -q 'enable-l2-announcements: "true"' <<<"$out" || { echo "FAIL: l2announcements off"; exit 1; }
grep -q 'enable-ingress-controller: "true"' <<<"$out" || { echo "FAIL: ingress controller off"; exit 1; }
echo ok
```
- [ ] **Step 2: Run it, expect a real answer, not an assumption.** `bash /tmp/t6.sh`. If a key name differs in the vendored 1.20.0 chart, fix the test's expectation from `helm show values scripts/manifests/cilium-1.20.0.tgz | grep -A20 '^ingressController'` **before** touching the script — the values surface is the thing under test.
- [ ] **Step 3: Replace the Cilium step in `scripts/create-cluster.sh`** (what was `create-cluster.sh:253-277`) with the substrate-aware version:
```sh
# --- Cilium -------------------------------------------------------------------
step "Installing Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement + ingress)"
# Chart is vendored into scripts/manifests/ (re-vendor from CILIUM_HELM_REPO
# when bumping) so this needs no internet at the venue — principle 2.
# Base values from the official Talos Cilium guide:
# https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
# k8sServiceHost=localhost:7445 is KubePrism, Talos' local API server balancer.
# --server-side=false pins helm 3's client-side apply (docs/HAZARDS.md).
cilium_values=(
  --set ipam.mode=kubernetes
  --set kubeProxyReplacement=true
  --set k8sServiceHost=localhost
  --set k8sServicePort=7445
  --set cgroup.autoMount.enabled=false
  --set cgroup.hostRoot=/sys/fs/cgroup
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  # One ingress endpoint for the whole platform. `shared` means every Ingress
  # object lands on ONE Service (cilium-ingress in kube-system) instead of one
  # LoadBalancer per Ingress — which on tbx would burn a VIP per hostname and on
  # docker would need a published port per hostname. Both substrates get the
  # same values so `ingressClassName: cilium` means the same thing in both.
  --set ingressController.enabled=true
  --set ingressController.loadbalancerMode=shared
  # L2 announcements are what make a LoadBalancer VIP answer ARP on the shared
  # L2 segment. Enabled on BOTH substrates deliberately: on docker there is no
  # LB-IPAM pool so nothing is announced, and keeping the flag identical means
  # `cilium config view` reads the same in the room whichever laptop asks.
  --set l2announcements.enabled=true
  # Cilium's own L2 docs: the announcement leases are renewed every 5s, so a
  # 40-address pool is ~8 QPS against the API server. The chart's 1.20.0
  # defaults are lower than that on some paths; raise them explicitly. Same
  # numbers talos-box uses (internal/manifests/manifests.go:41-43).
  --set k8sClientRateLimit.qps=10
  --set k8sClientRateLimit.burst=20
)
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  # Real VIP from the LB-IPAM pool created below — .200 by talos-box convention,
  # which its resolver already answers for every *.${CLOUDBOX_DOMAIN} name.
  cilium_values+=(--set ingressController.service.type=LoadBalancer)
else
  # No LB implementation in a docker cluster. The controlplane container
  # publishes host 80 -> this NodePort, so the hostnames work port-free there too.
  cilium_values+=(--set ingressController.service.type=NodePort)
  cilium_values+=(--set ingressController.service.insecureNodePort="${NODEPORT_INGRESS}")
fi
helm upgrade --install cilium \
  --server-side=false \
  "${SCRIPT_DIR}/manifests/cilium-${CILIUM_VERSION}.tgz" \
  --namespace kube-system \
  "${cilium_values[@]}"
```
- [ ] **Step 4: Publish `80:30880` on the docker backend.** In `scripts/substrate/docker.sh`, extend the `--exposed-ports` value (moved from `create-cluster.sh:189`) by appending `,80:${NODEPORT_INGRESS}/tcp` so it reads:
```sh
  --exposed-ports "${NODEPORT_GITEA}:${NODEPORT_GITEA}/tcp,${NODEPORT_ARGOCD}:${NODEPORT_ARGOCD}/tcp,${NODEPORT_ZOT}:${NODEPORT_ZOT}/tcp,${NODEPORT_PORTAL}:${NODEPORT_PORTAL}/tcp,${NODEPORT_BACKSTAGE}:${NODEPORT_BACKSTAGE}/tcp,${NODEPORT_RUSTFS_S3}:${NODEPORT_RUSTFS_S3}/tcp,${NODEPORT_GRAFANA}:${NODEPORT_GRAFANA}/tcp,${NODEPORT_KOURIER}:${NODEPORT_KOURIER}/tcp,${NODEPORT_NATS}:${NODEPORT_NATS}/tcp,80:${NODEPORT_INGRESS}/tcp" \
```
  The existing NodePorts stay published: lab 07 and the portal pull images through `localhost:30500` from the NODE side, and keeping the rest published means a hosts-block failure degrades to "use the port URL", not "nothing works".
- [ ] **Step 5: Add the port-80 preflight to `scripts/install.sh`.** In the loop at `install.sh:111-113`, add `80` to the port list only on the docker substrate — the check is what tells someone their local nginx owns the port before the cluster fails to start:
```sh
  ports=("${NODEPORT_GITEA}" "${NODEPORT_ARGOCD}" "${NODEPORT_ZOT}" \
         "${NODEPORT_PORTAL}" "${NODEPORT_BACKSTAGE}" "${NODEPORT_RUSTFS_S3}" \
         "${NODEPORT_GRAFANA}" "${NODEPORT_KOURIER}" "${NODEPORT_NATS}")
  [[ "${SUBSTRATE}" == "docker" ]] && ports+=(80)
  for port in "${ports[@]}"; do
```
- [ ] **Step 6: Extend check 10 in `check-consistency.sh` with the CNI-patch identity assertion.** The two backends carry byte-identical `cni: none` heredocs; drift between them is a silent one-substrate-only bug:
```sh
# The cni:none / proxy:disabled / node-label / local-path-mount patch is
# duplicated in both backends so each reads standalone. Duplication is fine;
# DRIFT is not — a node label that exists on one substrate and not the other
# makes lab/01 pass on one laptop and fail on the next.
before_fail=${FAILURES}
patch_of() { awk '/^cluster:$/,/^EOF$/' "$1" | sed '$d'; }
if ! diff -q <(patch_of scripts/substrate/docker.sh) <(patch_of scripts/substrate/tbx.sh) >/dev/null; then
  bad "the cni:none machine-config patch has drifted between scripts/substrate/docker.sh and scripts/substrate/tbx.sh — both substrates must produce the same cluster (diff them)"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] \
  && ok "both substrate backends carry the same cni:none machine-config patch"
```
- [ ] **Step 7: Run the render test, expect pass.** `bash /tmp/t6.sh` → `ok`.
- [ ] **Step 8: Docker end-to-end.** `CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh` then:
```sh
kubectl -n kube-system get svc cilium-ingress -o wide
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/
```
  Expected: the Service is `NodePort` with `80:30880/TCP`, and the curl answers `404` — Cilium's shared ingress is listening and has no Ingress object yet, which is exactly the state before Task 7. `000` means port 80 is not published; re-check Step 4.
- [ ] **Step 9: `./scripts/check-consistency.sh`** → both new lines green, exit 0.
- [ ] **Step 10: Commit.**
```
feat(cilium): turn on the shared ingress controller and L2 announcements

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 7: The tbx-only LB-IPAM pool and L2 announcement policy

These objects exist **only** on tbx: a docker cluster has no L2 segment to announce onto, and creating a pool there would leave the shared ingress Service `<pending>` forever.

**Files:**
- Create: `scripts/substrate/lb-objects.tbx.yaml.tmpl`
- Modify: `scripts/substrate/tbx.sh` (add `substrate_post_cni()`)
- Modify: `scripts/create-cluster.sh` (call `substrate_post_cni` after the Cilium install, before the node-Ready wait)
- Modify: `scripts/substrate/docker.sh` (a no-op `substrate_post_cni()`)
- Test: `kubectl apply --dry-run=client`, then a live VIP check

**Interfaces:**
- Consumes: `CLOUDBOX_HOST_GATEWAY` (`172.30.<n>.1`, exported by `substrate_create`), `CLUSTER_NAME`
- Produces: `CiliumLoadBalancerIPPool/cloudbox-pool`, `CiliumL2AnnouncementPolicy/cloudbox-l2`

- [ ] **Step 1: Write the failing dry-run test.** Create `/tmp/t7.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
T="$R/scripts/substrate/lb-objects.tbx.yaml.tmpl"
[[ -f "$T" ]] || { echo "FAIL: no lb-objects.tbx.yaml.tmpl"; exit 1; }
out="$(sed -e 's|__CLUSTER_NAME__|cloudbox|g' -e 's|__SUBNET_INDEX__|0|g' "$T")"
grep -q 'kind: CiliumLoadBalancerIPPool' <<<"$out" || { echo "FAIL: no pool"; exit 1; }
grep -q 'kind: CiliumL2AnnouncementPolicy' <<<"$out" || { echo "FAIL: no L2 policy"; exit 1; }
grep -q 'start: 172.30.0.200' <<<"$out" || { echo "FAIL: pool does not start at .200"; exit 1; }
grep -q 'stop: 172.30.0.239'  <<<"$out" || { echo "FAIL: pool does not stop at .239"; exit 1; }
grep -q 'apiVersion: cilium.io/v2$'       <<<"$out" || { echo "FAIL: pool apiVersion"; exit 1; }
grep -q 'apiVersion: cilium.io/v2alpha1$' <<<"$out" || { echo "FAIL: policy apiVersion"; exit 1; }
python3 -c 'import sys,yaml; list(yaml.safe_load_all(sys.stdin.read()))' <<<"$out" || { echo "FAIL: not valid YAML"; exit 1; }
echo ok
```
- [ ] **Step 2: Run it, expect fail.** `bash /tmp/t7.sh` → `FAIL: no lb-objects.tbx.yaml.tmpl`.
- [ ] **Step 3: Create `scripts/substrate/lb-objects.tbx.yaml.tmpl`.** The shape and the `.200-.239` range are copied from upstream `internal/manifests/manifests.go:61-89` (`LBPool` and `L2Policy`); the `talosbox.dev/announcement-owned` annotation is deliberately **dropped** — these are ours, and marking them talos-box-owned would invite `tbx` to reconcile objects it did not create:
```yaml
# GENERATED — do not edit. Rendered by substrate_post_cni() in
# scripts/substrate/tbx.sh from the cluster's own subnet index.
#
# tbx SUBSTRATE ONLY. Shape and address range from talos-box's own renderers
# (internal/manifests/manifests.go:61-89) so a cluster we bootstrap by hand gets
# the same LB reachability a curated `--cni cilium` one would: .200-.239, with
# .200 the ingress VIP by convention. Since our shared cilium-ingress Service is
# the first LoadBalancer in the cluster, it takes .200 — which is exactly the
# address talos-box's resolver already answers for every *.cloudbox.k8s.test
# name (docs/SPEC.md:213-216). That is why this workshop needs no DNS work.
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: __CLUSTER_NAME__-pool
spec:
  blocks:
    - start: 172.30.__SUBNET_INDEX__.200
      stop: 172.30.__SUBNET_INDEX__.239
---
# The default (non-BGP) reachability mechanism: a node ARP-replies for the VIP.
# nodeSelector {} = every node, so either node can hold it. macOS/vmnet failover
# is slow (40-50s — docs/HAZARDS.md); on a 2-node lab cluster that only matters
# if a node is stopped mid-workshop.
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: __CLUSTER_NAME__-l2
spec:
  loadBalancerIPs: true
  nodeSelector: {}
```
- [ ] **Step 4: Add `substrate_post_cni()` to `scripts/substrate/tbx.sh`:**
```sh
# substrate_post_cni — run after Cilium is installed and its CRDs are
# Established. Applies the LB-IPAM pool and the L2 announcement policy, then
# waits for the shared ingress Service to actually get its VIP: an ingress
# Service stuck <pending> is the single failure that makes every hostname in
# the workshop dead, so it is worth failing loudly here rather than in module 02.
substrate_post_cni() {
  step "Applying the LoadBalancer pool and L2 announcement policy"
  kubectl wait --for=condition=Established --timeout=120s \
    crd/ciliumloadbalancerippools.cilium.io \
    crd/ciliuml2announcementpolicies.cilium.io
  local idx="${CLOUDBOX_HOST_GATEWAY}"
  idx="${idx#172.30.}"; idx="${idx%.1}"
  sed -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
      -e "s|__SUBNET_INDEX__|${idx}|g" \
      "${SCRIPT_DIR}/substrate/lb-objects.tbx.yaml.tmpl" \
    | kubectl apply -f -

  step "Waiting for the shared ingress VIP"
  local waited=0 vip=""
  while [[ "${waited}" -lt 180 ]]; do
    vip="$(kubectl -n kube-system get svc cilium-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${vip}" ]] && break
    sleep 5; waited=$((waited + 5))
  done
  [[ -n "${vip}" ]] \
    || die "cilium-ingress never got a LoadBalancer address after ${waited}s — kubectl -n kube-system describe svc cilium-ingress; kubectl get ciliumloadbalancerippools"
  ok "Ingress VIP: ${vip} — every *.${CLOUDBOX_DOMAIN} name resolves here"
  [[ "${vip}" == "172.30.${idx}.200" ]] \
    || warn "VIP is ${vip}, not the conventional .200 — talos-box's resolver answers .200 for *.${CLOUDBOX_DOMAIN}, so the hostnames will NOT reach this Service. Delete the other LoadBalancer Service holding .200 and re-run."
}
```
- [ ] **Step 5: Add the docker no-op** to `scripts/substrate/docker.sh`:
```sh
# substrate_post_cni — nothing to do on docker. There is no L2 segment to
# announce a VIP onto, so the shared ingress Service is a NodePort (see the
# Cilium values in create-cluster.sh) and the hostnames arrive via the marked
# /etc/hosts block install.sh maintains. Defined so the dispatcher can call it
# unconditionally.
substrate_post_cni() { :; }
```
- [ ] **Step 6: Call it from the dispatcher.** In `scripts/create-cluster.sh`, immediately after the `helm upgrade --install cilium` block and before the `wait_rollout kube-system daemonset/cilium` line:
```sh
substrate_post_cni
```
- [ ] **Step 7: Run the test, expect pass.** `bash /tmp/t7.sh` → `ok`.
- [ ] **Step 8: Schema-validate against a live cluster.**
```sh
sed -e 's|__CLUSTER_NAME__|cloudbox|g' -e 's|__SUBNET_INDEX__|0|g' \
  scripts/substrate/lb-objects.tbx.yaml.tmpl | kubectl apply --dry-run=server -f -
```
  Expected on a tbx cluster with Cilium installed: `ciliumloadbalancerippool.cilium.io/cloudbox-pool created (server dry run)` and the same for the policy. On a docker cluster this same command must **not** be run — the CRDs exist but the pool would be live.
- [ ] **Step 9: Prove the VIP answers on tbx.**
```sh
kubectl -n kube-system get svc cilium-ingress
ping -c1 172.30.0.200
```
  Expected: `EXTERNAL-IP 172.30.0.200`, and the ping replies from the host — that is the L2 announcement working through vmnet/the bridge.
- [ ] **Step 10: Lint and commit.** `shellcheck -x --source-path=scripts scripts/substrate/*.sh`, then:
```
feat(substrate): give the tbx path a real LoadBalancer VIP for ingress

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 8: One hostname scheme in `versions.env`

**Files:**
- Modify: `scripts/versions.env:77` (`GITEA_HOST_URL`), `:82` (`ARGOCD_HOST_URL`), and a new `--- Browser-facing hostnames ---` block after the `NODEPORT_*` block (ends line 115)
- Test: `./scripts/check-consistency.sh`, `bash -n`

**Interfaces:**
- Consumes: `CLOUDBOX_DOMAIN` (Task 4)
- Produces: `GITEA_HOST_URL`, `ARGOCD_HOST_URL`, `PORTAL_HOST_URL`, `GRAFANA_HOST_URL`, `RUSTFS_S3_HOST`, `RUSTFS_S3_HOST_URL`, `RUSTFS_CONSOLE_HOST_URL`, `BACKSTAGE_HOST_URL`, `ZOT_HOST_URL`, `NATS_HOST_URL`, `KNATIVE_DOMAIN`

- [ ] **Step 1: Rewrite `GITEA_HOST_URL` and `ARGOCD_HOST_URL` in place.** `versions.env:77` becomes `GITEA_HOST_URL="http://gitea.${CLOUDBOX_DOMAIN}"` and `:82` becomes `ARGOCD_HOST_URL="http://argocd.${CLOUDBOX_DOMAIN}"`. **`CLOUDBOX_DOMAIN` must be assigned above them** — move the Task-4 `--- Substrate ---` block above the `--- GitOps ---` block if it is not already, since `versions.env` is read top to bottom. `GITEA_CLUSTER_URL` (line 78) does **not** change: it is what ArgoCD polls, in-cluster, and pointing ArgoCD at a host URL would break the offline write path.
- [ ] **Step 2: Append the hostname block** after `NODEPORT_NATS="30422"` (line 115):
```sh
# --- Browser-facing hostnames -------------------------------------------------
# One scheme, both substrates. On tbx these resolve through talos-box's own
# resolver to the cluster's .200 ingress VIP; on docker through the marked
# block install.sh maintains in /etc/hosts, to 127.0.0.1:80 -> NODEPORT_INGRESS.
# Each has a matching gitops/components/<x>/ingress.yaml with
# ingressClassName: cilium. The NodePorts above stay published as a fallback
# and for the node-side pulls (Zot) that must NOT go through ingress.
PORTAL_HOST_URL="http://portal.${CLOUDBOX_DOMAIN}"
GRAFANA_HOST_URL="http://grafana.${CLOUDBOX_DOMAIN}"
BACKSTAGE_HOST_URL="http://backstage.${CLOUDBOX_DOMAIN}"
ZOT_HOST_URL="http://zot.${CLOUDBOX_DOMAIN}"
NATS_HOST_URL="http://nats.${CLOUDBOX_DOMAIN}"          # HTTP monitoring (:8222) only;
                                                        # the client port stays NODEPORT_NATS
RUSTFS_CONSOLE_HOST_URL="http://rustfs.${CLOUDBOX_DOMAIN}"
# The S3 API host is needed WITHOUT a scheme too: the portal signs presigned
# URLs for it (apps/portal/internal/store/s3.go trims the scheme and builds the
# signing client with Secure:false), so this must stay plain http.
RUSTFS_S3_HOST="s3.${CLOUDBOX_DOMAIN}"
RUSTFS_S3_HOST_URL="http://${RUSTFS_S3_HOST}"
# Knative's config-domain. Every ksvc becomes <name>.<ns>.kn.cloudbox.k8s.test,
# which the *.kn.<domain> Ingress routes to the Kourier gateway.
KNATIVE_DOMAIN="kn.${CLOUDBOX_DOMAIN}"
```
- [ ] **Step 3: Verify the expansion order actually works.**
```sh
bash -c 'source scripts/versions.env; printf "%s\n" "$GITEA_HOST_URL" "$ARGOCD_HOST_URL" "$RUSTFS_S3_HOST" "$KNATIVE_DOMAIN"'
```
  Expected exactly:
```
http://gitea.cloudbox.k8s.test
http://argocd.cloudbox.k8s.test
s3.cloudbox.k8s.test
kn.cloudbox.k8s.test
```
  A literal `http://gitea.` with an empty domain means `CLOUDBOX_DOMAIN` is assigned below its first use — move the block.
- [ ] **Step 4: `shellcheck -x --source-path=scripts scripts/lib.sh`** (which sources `versions.env`) → exit 0.
- [ ] **Step 5: `./scripts/check-consistency.sh`** → exit 0, no new failures.
- [ ] **Step 6: Commit.**
```
feat(versions): one *.cloudbox.k8s.test hostname per browser-facing service

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 9: Ingress manifests for the eight ArgoCD-delivered components

Every backend Service name and port below was read out of the manifests in this repo, cited inline. Each `ingress.yaml` goes into the component directory the component's Application already points at (`spec.source.path: gitops/components/<x>`, e.g. `gitops/catalog/portal.yaml:25`), so it is picked up with no Application change and inherits the component's existing sync wave.

**Files:**
- Create: `gitops/components/portal/ingress.yaml`, `gitops/components/grafana/ingress.yaml`, `gitops/components/rustfs/ingress.yaml` (two hosts, one file), `gitops/components/backstage/ingress.yaml`, `gitops/components/zot/ingress.yaml`, `gitops/components/nats/ingress.yaml`, `gitops/components/knative-serving/ingress.yaml`
- Test: `kubeconform`, `kubectl apply --dry-run=server`, `curl` against a live cluster

**Interfaces:**
- Consumes: `ingressClassName: cilium` (from Task 6's `ingressController.enabled=true`)
- Produces: `Ingress/portal`, `Ingress/grafana`, `Ingress/rustfs`, `Ingress/backstage`, `Ingress/zot`, `Ingress/nats`, `Ingress/kourier`

- [ ] **Step 1: Write the failing coverage test.** Create `/tmp/t9.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
rc=0
for c in portal grafana rustfs backstage zot nats knative-serving; do
  [[ -f "$R/gitops/components/$c/ingress.yaml" ]] || { echo "FAIL: no gitops/components/$c/ingress.yaml"; rc=1; }
done
for c in gitea argocd; do
  [[ -f "$R/gitops/components/$c/ingress.yaml" ]] || { echo "FAIL: no gitops/components/$c/ingress.yaml (Task 10)"; rc=1; }
done
n=$(grep -rl 'kind: Ingress' "$R/gitops/components" | wc -l | tr -d ' ')
[[ "$n" -ge 9 ]] || { echo "FAIL: only $n ingress files, want 9 (rustfs carries two hosts)"; rc=1; }
[[ $rc -eq 0 ]] && echo ok
exit $rc
```
- [ ] **Step 2: Run it, expect fail.** `bash /tmp/t9.sh` → seven `FAIL: no gitops/components/…` lines.
- [ ] **Step 3: `gitops/components/portal/ingress.yaml`.** Backend read from `gitops/components/portal/portal.yaml:143-156` — Service `portal`, ns `portal`, port name `http`, port 8080:
```yaml
# The Cloudbox Console at http://portal.cloudbox.k8s.test — the same URL on both
# substrates. NodePort 30600 stays as the fallback if the hosts block is missing.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: portal
spec:
  ingressClassName: cilium
  rules:
    - host: portal.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: portal
                port:
                  number: 8080
```
- [ ] **Step 4: `gitops/components/grafana/ingress.yaml`.** Backend from `gitops/components/grafana/grafana.yaml:61-77` — Service `grafana`, ns `observability`, port 3000. Note this is the ClusterIP Service, **not** `grafana-nodeport`:
```yaml
# Grafana at http://grafana.cloudbox.k8s.test. Backend is the chart's ClusterIP
# Service (grafana.yaml), not the workshop's grafana-nodeport addition — the
# NodePort keeps existing for the port-URL fallback.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: observability
spec:
  ingressClassName: cilium
  rules:
    - host: grafana.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 3000
```
- [ ] **Step 5: `gitops/components/rustfs/ingress.yaml`** — two hosts, one file. Backend from `gitops/components/rustfs/rustfs.yaml:76-101`: Service `rustfs-svc`, ns `rustfs`, ports `endpoint` 9000 and `console` 9001. The console has had **no** host exposure before this:
```yaml
# Two hostnames onto one Service:
#   s3.cloudbox.k8s.test      the S3 API (:9000). The portal SIGNS presigned
#                             URLs for this host, so it must stay plain http —
#                             apps/portal/internal/store/s3.go builds its
#                             signing client with Secure:false.
#   rustfs.cloudbox.k8s.test  the RustFS console (:9001), which had no host
#                             exposure at all before the ingress scheme.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rustfs
  namespace: rustfs
spec:
  ingressClassName: cilium
  rules:
    - host: s3.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rustfs-svc
                port:
                  number: 9000
    - host: rustfs.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rustfs-svc
                port:
                  number: 9001
```
- [ ] **Step 6: `gitops/components/backstage/ingress.yaml`.** Backend from `gitops/components/backstage/backstage.yaml:230-243` — Service `backstage`, ns `backstage`, port 7007:
```yaml
# Backstage at http://backstage.cloudbox.k8s.test. app.baseUrl, backend.baseUrl
# and backend.cors.origin move with this host — see backstage.yaml:125,129,135;
# all three must agree or the SPA loads and every API call is CORS-blocked.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: backstage
  namespace: backstage
spec:
  ingressClassName: cilium
  rules:
    - host: backstage.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: backstage
                port:
                  number: 7007
```
- [ ] **Step 7: `gitops/components/zot/ingress.yaml`.** Backend from `gitops/components/zot/zot.yaml:50-68` — Service `zot`, ns `zot`, port 5000. Browser/`crane` use only:
```yaml
# Zot's UI and OCI API at http://zot.cloudbox.k8s.test — for the BROWSER and for
# host-side `crane`. The in-cluster and node-side paths do NOT move here:
#   * pushes from Argo Workflows go to zot.zot.svc.cluster.local:5000
#   * kubelet PULLS use localhost:30500 — the node's own NodePort, which is
#     valid on both substrates and is in Knative's
#     registries-skipping-tag-resolving list (serving-core.yaml:7648).
# Do not "tidy" those into this hostname; a node cannot resolve it.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: zot
  namespace: zot
spec:
  ingressClassName: cilium
  rules:
    - host: zot.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: zot
                port:
                  number: 5000
```
- [ ] **Step 8: `gitops/components/nats/ingress.yaml`.** Backend from `gitops/components/nats/nats.yaml:46-64` — Service `nats`, ns `nats`, port `monitor` **8222** (the `nats-client-nodeport` Service carries only `client`/4222, so it is the wrong backend):
```yaml
# NATS's HTTP monitoring endpoints at http://nats.cloudbox.k8s.test (/varz,
# /jsz, /connz). The CLIENT protocol is not HTTP and cannot go through an
# Ingress: nats:// stays on NodePort 30422 (nats/service-nodeport.yaml) or a
# port-forward. Backend is the main `nats` Service's `monitor` port — the
# nodeport Service does not carry 8222.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nats
  namespace: nats
spec:
  ingressClassName: cilium
  rules:
    - host: nats.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nats
                port:
                  number: 8222
```
- [ ] **Step 9: `gitops/components/knative-serving/ingress.yaml`.** Backend from `gitops/components/knative-serving/kourier.yaml:652-680` — Service `kourier`, ns **`kourier-system`**, port 80 (targetPort 8080). Not `kourier-internal` (ns `kourier-system`, port 80 → targetPort **8081**, the cluster-local variant):
```yaml
# One wildcard in front of Knative. Knative programs every ksvc's host as
# <name>.<ns>.kn.cloudbox.k8s.test (config-domain, serving-core.yaml:7805), and
# Kourier routes on that Host header — so ONE Ingress covers every function
# anyone creates for the rest of the workshop.
#
# Backend is the EXTERNAL kourier gateway (kourier.yaml:652-680, port 80 ->
# targetPort 8080), not kourier-internal (-> 8081), which is cluster-local.
#
# On tbx the wildcard resolves through talos-box's own resolver to the .200 VIP,
# so this works for names nobody has created yet. On docker /etc/hosts has no
# wildcards, so install.sh's block lists the three fixed ksvc names the labs
# create (hello.demo, uploader.pipeline, resizer.pipeline); anything else needs
# a manual hosts line or the Host-header curl the lab still documents.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kourier
  namespace: kourier-system
spec:
  ingressClassName: cilium
  rules:
    - host: "*.kn.cloudbox.k8s.test"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kourier
                port:
                  number: 80
```
- [ ] **Step 10: Check the wildcard actually matches two labels deep.** A `*.kn.cloudbox.k8s.test` wildcard matches exactly **one** label, so it covers `hello.kn.…` but **not** `hello.demo.kn.…`. Verify against the live cluster:
```sh
kubectl -n demo get ksvc hello -o jsonpath='{.status.url}{"\n"}'
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: hello.demo.kn.cloudbox.k8s.test' http://localhost/
```
  If this returns `404`, replace the host in Step 9 with `"*.demo.kn.cloudbox.k8s.test"` **plus** a second rule for `"*.pipeline.kn.cloudbox.k8s.test"` (the two namespaces the labs use), and record the reason in the file's comment. Do not skip this step — it is the one assumption in this task that the manifests cannot answer.
- [ ] **Step 11: Run the coverage test.** `bash /tmp/t9.sh` → still fails on `gitea`/`argocd` (Task 10). That is expected; the seven files above must all be present.
- [ ] **Step 12: Schema-validate.** `kubeconform -strict -summary -ignore-missing-schemas -skip Application,AppProject,ApplicationSet gitops/` → `0 errors`.
- [ ] **Step 13: Live check on docker.** With the cluster up, the hosts block from Task 12 in place, and the components enabled:
```sh
for h in portal grafana s3 rustfs backstage zot nats; do
  printf '%-10s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://$h.cloudbox.k8s.test/")"
done
```
  Expected: `portal 200`, `grafana 302` (Grafana redirects to `/login`), `s3 403` (RustFS answers S3 without credentials), `rustfs 200`, `backstage 200`, `zot 200`, `nats 404` (the monitoring endpoints live at `/varz`, not `/`) — confirm `nats` with `curl -sS http://nats.cloudbox.k8s.test/varz | jq .server_name`.
- [ ] **Step 14: Commit.**
```
feat(gitops): give every browser-facing component a cilium Ingress

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 10: Ingress for Gitea and ArgoCD (the two bootstrap-installed services)

Gitea and ArgoCD have **no** ArgoCD Application and no `gitops/components/` directory — `bootstrap-gitops.sh` installs both imperatively (`bootstrap-gitops.sh:71-122` and `:124-196`). Their Ingress objects therefore need a new home and an explicit `kubectl apply`, not a sync wave.

**Files:**
- Create: `gitops/components/gitea/ingress.yaml`, `gitops/components/argocd/ingress.yaml`
- Modify: `scripts/bootstrap-gitops.sh` (apply both; update the closing banner at `:206-214`)
- Test: `kubeconform`, `curl`, `git clone` through the ingress

**Interfaces:**
- Consumes: `REPO_ROOT` (exported by `lib.sh:23`), `GITEA_HOST_URL`, `ARGOCD_HOST_URL`
- Produces: `Ingress/gitea` in ns `gitea`, `Ingress/argocd-server` in ns `argocd`

- [ ] **Step 1: `gitops/components/gitea/ingress.yaml`.** Backend read from the vendored chart: release `gitea` + chart `gitea` ⇒ fullname `gitea`, and `gitea.service.http.name` is `<fullname>-http` ⇒ Service **`gitea-http`**, ns `gitea`, port 3000 (matching `versions.env` `GITEA_CLUSTER_URL="http://gitea-http.gitea.svc.cluster.local:3000"`):
```yaml
# Gitea at http://gitea.cloudbox.k8s.test — the workshop's only git remote, so
# this URL is what attendees clone and push through all day.
#
# NOT applied by ArgoCD: Gitea is installed imperatively by
# scripts/bootstrap-gitops.sh (it has to exist before GitOps does), so that
# script applies this file directly. It lives here anyway so every component's
# ingress is in one place.
#
# gitea.config.server.ROOT_URL deliberately stays the in-CLUSTER URL
# (GITEA_CLUSTER_URL): that is the address ArgoCD polls, and repointing it at a
# host name would make the platform's write path depend on host DNS.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea
  namespace: gitea
spec:
  ingressClassName: cilium
  rules:
    - host: gitea.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitea-http
                port:
                  number: 3000
```
- [ ] **Step 2: `gitops/components/argocd/ingress.yaml`.** Backend from the vendored manifest `scripts/manifests/argocd-install-v3.5.1.yaml:31804-31823` — Service `argocd-server`, ns `argocd`, port `http` 80 → targetPort 8080. `server.insecure: "true"` is already set (`bootstrap-gitops.sh:191-192`), so plain HTTP to :80 is correct and no TLS backend annotation is needed:
```yaml
# ArgoCD at http://argocd.cloudbox.k8s.test.
#
# Plain http on purpose: bootstrap-gitops.sh sets server.insecure=true in
# argocd-cmd-params-cm, so argocd-server speaks HTTP on 8080 and the Service's
# :80 reaches it. Without that, Cilium's ingress would speak http to a TLS
# listener and every request would fail.
#
# NOT applied by ArgoCD (it would be applying its own front door before it can
# sync anything): scripts/bootstrap-gitops.sh applies this file directly.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
spec:
  ingressClassName: cilium
  rules:
    - host: argocd.cloudbox.k8s.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```
- [ ] **Step 3: Apply both from `bootstrap-gitops.sh`.** Insert after the `kubectl -n argocd rollout restart …` line (`:196`) and before the `--- 4. Wait for everything ---` step:
```sh
info "Publishing Gitea and ArgoCD on ${GITEA_HOST_URL} / ${ARGOCD_HOST_URL}"
# These two are installed imperatively, so nothing else will ever apply their
# Ingress objects. The manifests live in gitops/components/{gitea,argocd}/ so
# all ten ingresses read as one set; only these two are applied by hand.
kubectl apply -f "${REPO_ROOT}/gitops/components/gitea/ingress.yaml"
kubectl apply -f "${REPO_ROOT}/gitops/components/argocd/ingress.yaml"
```
- [ ] **Step 4: Update the closing banner** at `bootstrap-gitops.sh:206-214` so the printed URLs are the hostnames (they already interpolate `GITEA_HOST_URL` / `ARGOCD_HOST_URL`, which Task 8 changed — verify the output rather than editing blindly), and add the fallback line:
```sh
echo "  Gitea:   ${GITEA_HOST_URL}  (${GITEA_ADMIN_USER} / ${GITEA_ADMIN_PASSWORD})"
echo "  ArgoCD:  ${ARGOCD_HOST_URL}  (user: admin)"
echo
info "Name not resolving? On the docker substrate these need the /etc/hosts block:"
echo "   ./scripts/install.sh --print-hosts        # shows the exact lines"
echo "   The NodePort URLs still work: http://localhost:${NODEPORT_GITEA} and http://localhost:${NODEPORT_ARGOCD}"
```
- [ ] **Step 5: Run the Task-9 coverage test, now expect pass.** `bash /tmp/t9.sh` → `ok` (nine files, ten hostnames — `rustfs/ingress.yaml` carries two).
- [ ] **Step 6: `kubeconform -strict -summary -ignore-missing-schemas -skip Application,AppProject,ApplicationSet gitops/`** → `0 errors`.
- [ ] **Step 7: Live proof that the git write path works through the hostname.** On a bootstrapped cluster with the hosts block in place:
```sh
curl -fsS http://gitea.cloudbox.k8s.test/api/healthz
curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.cloudbox.k8s.test/
git clone http://gitea_admin:cloudbox123@gitea.cloudbox.k8s.test/cloudbox/platform.git /tmp/pf && rm -rf /tmp/pf
```
  Expected: healthz `pass`, ArgoCD `200`, and the clone succeeds. A `403` or a redirect loop from Gitea means the ingress reached it but `ROOT_URL` confusion is in play — re-check that Step 1 did **not** change `ROOT_URL`.
- [ ] **Step 8: `shellcheck -x --source-path=scripts scripts/bootstrap-gitops.sh`** → exit 0.
- [ ] **Step 9: Commit.**
```
feat(gitops): publish Gitea and ArgoCD on the cloudbox.k8s.test scheme

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 11: Backstage base URLs, the portal's presigned host, and Knative's `config-domain`

Three application-level settings that must move **with** the hostnames or the ingress will serve a broken app. All three sit in vendored files with a `VENDOR.md` curation list that `check-vendor-drift.sh --offline` enforces on every push.

**Files:**
- Modify: `gitops/components/backstage/backstage.yaml:125,129,135`; `gitops/components/backstage/VENDOR.md:39,120`
- Modify: `gitops/components/portal/portal.yaml:103-114`; `gitops/components/portal/VENDOR.md:62-73`
- Modify: `gitops/components/knative-serving/serving-core.yaml:7799-7805`; `gitops/components/knative-serving/VENDOR.md:38-46,150`
- Modify: `apps/portal/config.go:45,52`; `apps/portal/internal/store/s3.go:9` (comment only)
- Test: `./scripts/check-vendor-drift.sh --offline`, `go test ./...` in `apps/portal`, live `curl`

**Interfaces:**
- Consumes: `BACKSTAGE_HOST_URL`, `RUSTFS_S3_HOST`, `GRAFANA_HOST_URL`, `KNATIVE_DOMAIN` (Task 8) — as literal values, since these are YAML/Go, not shell
- Produces: Backstage serving on its own host; presigned URLs pointing at `s3.cloudbox.k8s.test`; ksvc URLs under `kn.cloudbox.k8s.test`

- [ ] **Step 1: Write the failing literal test.** Create `/tmp/t11.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
rc=0
grep -q 'baseUrl: http://backstage.cloudbox.k8s.test' "$R/gitops/components/backstage/backstage.yaml" || { echo "FAIL: backstage baseUrl"; rc=1; }
grep -q 'origin: http://backstage.cloudbox.k8s.test'  "$R/gitops/components/backstage/backstage.yaml" || { echo "FAIL: backstage cors"; rc=1; }
grep -q 'value: s3.cloudbox.k8s.test'                 "$R/gitops/components/portal/portal.yaml"       || { echo "FAIL: S3_PUBLIC_ENDPOINT"; rc=1; }
grep -q 'value: http://grafana.cloudbox.k8s.test'     "$R/gitops/components/portal/portal.yaml"       || { echo "FAIL: GRAFANA_URL"; rc=1; }
grep -q '^  kn.cloudbox.k8s.test: ""'                 "$R/gitops/components/knative-serving/serving-core.yaml" || { echo "FAIL: config-domain"; rc=1; }
grep -q '127.0.0.1.sslip.io' "$R/gitops/components/knative-serving/serving-core.yaml" && { echo "FAIL: sslip.io still in config-domain"; rc=1; }
grep -q '"s3.cloudbox.k8s.test"' "$R/apps/portal/config.go" || { echo "FAIL: portal S3PublicEndpoint default"; rc=1; }
[[ $rc -eq 0 ]] && echo ok
exit $rc
```
- [ ] **Step 2: Run it, expect fail.** `bash /tmp/t11.sh` → six `FAIL:` lines.
- [ ] **Step 3: Backstage.** In `gitops/components/backstage/backstage.yaml`, change line 125 `baseUrl: http://localhost:30700` → `baseUrl: http://backstage.cloudbox.k8s.test`, line 129 the same, and line 135 `origin: http://localhost:30700` → `origin: http://backstage.cloudbox.k8s.test`. All three move together: the SPA loads from `app.baseUrl`, calls `backend.baseUrl`, and the browser's Origin must match `backend.cors.origin` or every call is blocked with the page still rendering. `backend.csp.connect-src` (line 133) is already `['self', 'http:', 'https:']` and needs no change. Do **not** touch the `integrations.gitea` block (`:147-152`) — that is the in-cluster URL Backstage's backend uses.
- [ ] **Step 4: Update `gitops/components/backstage/VENDOR.md`** lines 39 and 120, replacing `http://localhost:30700` with `http://backstage.cloudbox.k8s.test` and adding after line 39: `They move with the hostname scheme (docs/superpowers/plans/2026-08-24-talos-box-substrate.md); the NodePort 30700 Service stays for the port-URL fallback.`
- [ ] **Step 5: Portal manifest.** In `gitops/components/portal/portal.yaml`, replace the `S3_PUBLIC_ENDPOINT` value (line 110) `localhost:30900` → `s3.cloudbox.k8s.test`, and `GRAFANA_URL` (line 114) `http://localhost:30030` → `http://grafana.cloudbox.k8s.test`. Update the comment at `:103-104` to:
```yaml
            # Host the BROWSER uses for presigned URLs. Signed with Secure:false
            # (apps/portal/internal/store/s3.go), so this must stay plain http —
            # an https host here produces signatures the browser cannot use.
```
  `S3_ENDPOINT` (line 98, `http://rustfs-svc.rustfs.svc.cluster.local:9000`) does **not** change — that is the pod's own path to RustFS and must not depend on ingress.
- [ ] **Step 6: Portal Go defaults.** In `apps/portal/config.go`, line 45 becomes `S3PublicEndpoint: envOr("S3_PUBLIC_ENDPOINT", "s3.cloudbox.k8s.test"), // RustFS via the cilium ingress` and line 52 becomes `GrafanaURL: envOr("GRAFANA_URL", "http://grafana.cloudbox.k8s.test"),`. Update the comment at `apps/portal/internal/store/s3.go:9` from `(localhost:30900)` to `(s3.cloudbox.k8s.test)`.
- [ ] **Step 7: Update `gitops/components/portal/VENDOR.md:62-73`** — `NodePort 30600` line gains `, published at http://portal.cloudbox.k8s.test (ingress.yaml)`; `S3_PUBLIC_ENDPOINT=localhost:30900` → `S3_PUBLIC_ENDPOINT=s3.cloudbox.k8s.test`; `GRAFANA_URL=http://localhost:30030` → `GRAFANA_URL=http://grafana.cloudbox.k8s.test`.
- [ ] **Step 8: Knative `config-domain`.** In `gitops/components/knative-serving/serving-core.yaml`, replace the data key at line 7805 `127.0.0.1.sslip.io: ""` with `kn.cloudbox.k8s.test: ""` and rewrite the comment block at `:7799-7804`:
```yaml
  # Externally-routable default domain. Every ksvc becomes
  # http://<name>.<ns>.kn.cloudbox.k8s.test, which the wildcard Ingress in
  # ingress.yaml routes to the Kourier gateway — so a ksvc URL is browsable
  # with no Host header and no port, on BOTH substrates. WITHOUT this key,
  # config-domain holds only _example and Knative defaults to
  # svc.cluster.local, which is cluster-local-only and 404s from outside.
  # (The old value was 127.0.0.1.sslip.io, which only ever worked on a laptop
  # whose loopback WAS the cluster — i.e. the docker substrate.)
```
- [ ] **Step 9: Re-derive the VENDOR.md curation hunk id.** Editing a vendored file changes the diff hunk `check-vendor-drift.sh` allow-lists. Run `./scripts/check-vendor-drift.sh --only knative-serving`, read the new id it reports for the config-domain hunk, and update `gitops/components/knative-serving/VENDOR.md:150` from `allow serving-core.yaml 3cb2e735 curation 3 — config-domain gains 127.0.0.1.sslip.io; without it every ksvc URL 404s` to `allow serving-core.yaml <new-id> curation 3 — config-domain gains kn.cloudbox.k8s.test; without it every ksvc URL 404s`. Also update the prose at `VENDOR.md:38-46`, `:90`, `:115-116` and `:166` to the new domain and to `curl http://hello.demo.kn.cloudbox.k8s.test/` (no Host header, no port). **Do not guess the id** — it is a content hash.
- [ ] **Step 10: Run the literal test, expect pass.** `bash /tmp/t11.sh` → `ok`.
- [ ] **Step 11: Run the Go tests.** `cd apps/portal && go test ./...`. Expect failures in `internal/web/*_test.go` and `internal/kube/*_test.go` that assert the old literals (`grafana_test.go:9-20`, `templates_test.go:30,195`, `buckets_test.go:40,90`, `component_detail_test.go`, `eggs_test.go:21`, `agent_ask_test.go:585`, `functions_test.go:15`). Update each fixture to the new hostnames. **Leave `applications_test.go:111,120` and `functions_test.go:101-104` alone** — they assert `localhost:30500`, the node-side pull host, which does not move (Task 13 covers why).
- [ ] **Step 12: `./scripts/check-vendor-drift.sh --offline`** → exit 0, no "undocumented curation" or "curation lost in a re-vendor" findings.
- [ ] **Step 13: Live proof of all three.** On a bootstrapped cluster with knative-serving and portal enabled:
```sh
kubectl -n demo get ksvc hello -o jsonpath='{.status.url}{"\n"}'      # http://hello.demo.kn.cloudbox.k8s.test
curl -fsS http://hello.demo.kn.cloudbox.k8s.test/                      # Hello your own cloud!
curl -sS http://backstage.cloudbox.k8s.test/ -o /dev/null -w '%{http_code}\n'   # 200
curl -sS http://portal.cloudbox.k8s.test/gallery | grep -o 's3\.cloudbox\.k8s\.test' | head -1
```
- [ ] **Step 14: Commit.**
```
feat(gitops): move Backstage, the portal and Knative onto the hostname scheme

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 12: The marked `/etc/hosts` block, `--print-hosts`, and its removal

Docker-substrate only. `install.sh --check` must **verify** and never write; the write happens on the create path and asks for sudo once.

**Files:**
- Modify: `scripts/install.sh` (argument parsing at `:32-37`; new hosts functions; a new `--check` section)
- Modify: `scripts/create-cluster.sh` (call the writer after `substrate_post_cni`, docker only)
- Modify: `scripts/destroy-cluster.sh` (remove the block under `--purge-mirror`)
- Test: a dry-run render, a real write on a throwaway file, `install.sh --check`

**Interfaces:**
- Consumes: `CLOUDBOX_DOMAIN`, `SUBSTRATE`
- Produces: `cloudbox_hostnames()`, `cloudbox_hosts_block()`, `hosts_block_present()`, `write_hosts_block()`, `remove_hosts_block()` in `scripts/lib.sh`; `install.sh --print-hosts`

- [ ] **Step 1: Write the failing test.** Create `/tmp/t12.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
source "$R/scripts/lib.sh"
for fn in cloudbox_hostnames cloudbox_hosts_block hosts_block_present write_hosts_block remove_hosts_block; do
  declare -F "$fn" >/dev/null || { echo "FAIL: missing $fn"; exit 1; }
done
b="$(cloudbox_hosts_block)"
grep -q '^# cloudbox-begin$' <<<"$b" || { echo "FAIL: no begin marker"; exit 1; }
grep -q '^# cloudbox-end$'   <<<"$b" || { echo "FAIL: no end marker";   exit 1; }
for h in gitea argocd portal grafana s3 rustfs backstage zot nats; do
  grep -q "127.0.0.1 ${h}.cloudbox.k8s.test$" <<<"$b" || { echo "FAIL: missing $h"; exit 1; }
done
for h in hello.demo uploader.pipeline resizer.pipeline; do
  grep -q "127.0.0.1 ${h}.kn.cloudbox.k8s.test$" <<<"$b" || { echo "FAIL: missing ksvc $h"; exit 1; }
done
[[ "$(grep -c '^127.0.0.1 ' <<<"$b")" == "12" ]] || { echo "FAIL: want 12 host lines, got $(grep -c '^127.0.0.1 ' <<<"$b")"; exit 1; }
"$R/scripts/install.sh" --print-hosts >/dev/null || { echo "FAIL: --print-hosts"; exit 1; }
echo ok
```
- [ ] **Step 2: Run it, expect fail.** `bash /tmp/t12.sh` → `FAIL: missing cloudbox_hostnames`.
- [ ] **Step 3: Add the hosts helpers to `scripts/lib.sh`,** after the substrate block from Task 1:
```sh
# --- The /etc/hosts block (docker substrate only) -------------------------------
# On tbx, talos-box's own resolver answers *.${CLOUDBOX_DOMAIN} with the
# cluster's ingress VIP and there is nothing to write. On docker there is no
# resolver and no wildcard, so the hostnames are listed one by one, in a MARKED
# block we own end-to-end: idempotent to write, exactly removable, and never
# touching a line we did not put there.
CLOUDBOX_HOSTS_BEGIN="# cloudbox-begin"
CLOUDBOX_HOSTS_END="# cloudbox-end"
CLOUDBOX_HOSTS_FILE="${CLOUDBOX_HOSTS_FILE:-/etc/hosts}"

# cloudbox_hostnames — every name the workshop serves, one per line.
# The nine service names, plus the three Knative names the labs create:
# /etc/hosts has no wildcards, so `*.kn.` cannot be expressed. Anything else an
# attendee creates needs a manual line — lab/06 says so, and its verify.sh
# accepts the Host-header form for exactly that reason.
cloudbox_hostnames() {
  local h
  for h in gitea argocd portal grafana s3 rustfs backstage zot nats; do
    echo "${h}.${CLOUDBOX_DOMAIN}"
  done
  for h in hello.demo uploader.pipeline resizer.pipeline; do
    echo "${h}.${KNATIVE_DOMAIN}"
  done
}

cloudbox_hosts_block() {
  echo "${CLOUDBOX_HOSTS_BEGIN}"
  echo "# CloudBox workshop — the docker substrate has no resolver, so every"
  echo "# hostname is listed here. Written by ./scripts/create-cluster.sh,"
  echo "# removed by ./scripts/destroy-cluster.sh --purge-mirror. Safe to delete"
  echo "# by hand: nothing outside these two markers is ever touched."
  local n
  while IFS= read -r n; do echo "127.0.0.1 ${n}"; done < <(cloudbox_hostnames)
  echo "${CLOUDBOX_HOSTS_END}"
}

# hosts_block_present — 0 when the block exists AND lists every current name.
# A block that is merely present is not enough: adding a hostname to
# cloudbox_hostnames must make this fail so the block gets rewritten.
hosts_block_present() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 1
  grep -qxF "${CLOUDBOX_HOSTS_BEGIN}" "${CLOUDBOX_HOSTS_FILE}" || return 1
  local n
  while IFS= read -r n; do
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${n//./\\.}([[:space:]]|$)" \
      "${CLOUDBOX_HOSTS_FILE}" || return 1
  done < <(cloudbox_hostnames)
  return 0
}

# hosts_missing_names — the names NOT currently resolvable from the file, so a
# FAIL message can name them instead of saying "the block is wrong".
hosts_missing_names() {
  local n
  while IFS= read -r n; do
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${n//./\\.}([[:space:]]|$)" \
      "${CLOUDBOX_HOSTS_FILE}" 2>/dev/null || echo "${n}"
  done < <(cloudbox_hostnames)
}

# write_hosts_block — replace the marked block (or append it). Needs sudo, once.
# Written via a temp file and `sudo tee`, never an in-place sudo sed: a
# half-written /etc/hosts breaks name resolution for the whole machine.
write_hosts_block() {
  hosts_block_present && { ok "/etc/hosts block already correct"; return 0; }
  local tmp; tmp="$(mktemp)"
  if [[ -r "${CLOUDBOX_HOSTS_FILE}" ]]; then
    awk -v b="${CLOUDBOX_HOSTS_BEGIN}" -v e="${CLOUDBOX_HOSTS_END}" \
      '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
      "${CLOUDBOX_HOSTS_FILE}" > "${tmp}"
  fi
  cloudbox_hosts_block >> "${tmp}"
  warn "Adding the CloudBox hostnames to ${CLOUDBOX_HOSTS_FILE} — this needs sudo, once."
  info "See exactly what goes in with: ./scripts/install.sh --print-hosts"
  sudo tee "${CLOUDBOX_HOSTS_FILE}" < "${tmp}" >/dev/null
  rm -f "${tmp}"
  hosts_block_present || die "Wrote ${CLOUDBOX_HOSTS_FILE} but the names still do not resolve — check it by hand"
  ok "${CLOUDBOX_HOSTS_FILE} updated ($(cloudbox_hostnames | wc -l | tr -d ' ') names)"
}

remove_hosts_block() {
  [[ -r "${CLOUDBOX_HOSTS_FILE}" ]] || return 0
  grep -qxF "${CLOUDBOX_HOSTS_BEGIN}" "${CLOUDBOX_HOSTS_FILE}" || return 0
  local tmp; tmp="$(mktemp)"
  awk -v b="${CLOUDBOX_HOSTS_BEGIN}" -v e="${CLOUDBOX_HOSTS_END}" \
    '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
    "${CLOUDBOX_HOSTS_FILE}" > "${tmp}"
  warn "Removing the CloudBox block from ${CLOUDBOX_HOSTS_FILE} — this needs sudo."
  sudo tee "${CLOUDBOX_HOSTS_FILE}" < "${tmp}" >/dev/null
  rm -f "${tmp}"
  ok "${CLOUDBOX_HOSTS_FILE} block removed"
}
```
- [ ] **Step 4: Add `--print-hosts` to `install.sh`.** Replace the `case` at `:32-37`:
```sh
case "${1:-}" in
  --check) ;;
  # Read-only, and the ONE thing a Windows attendee needs: these lines also have
  # to go into C:\Windows\System32\drivers\etc\hosts for the Windows browser to
  # reach a cluster running in WSL2 (lab/00-setup covers it).
  --print-hosts) cloudbox_hosts_block; exit 0 ;;
  "") usage; echo ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "Unknown argument: $1 (this script only checks and prints; it installs nothing)" ;;
esac
```
  and add `#   ./scripts/install.sh --print-hosts   # the /etc/hosts lines the docker substrate needs` to the header's Usage block (`:8-11`), which `usage()` reprints.
- [ ] **Step 5: Add the hosts check to `install.sh --check`.** After the "Workshop NodePorts free" section (ends `:120`):
```sh
# --- Hostname resolution --------------------------------------------------------
step "Workshop hostnames (*.${CLOUDBOX_DOMAIN})"
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  ok "tbx substrate — talos-box's resolver answers *.${CLOUDBOX_DOMAIN}; no /etc/hosts entries needed"
  info "  (verify after the cluster exists: tbx status ${CLUSTER_NAME})"
elif hosts_block_present; then
  ok "/etc/hosts has the CloudBox block ($(cloudbox_hostnames | wc -l | tr -d ' ') names)"
elif [[ -z "$(substrate_current)" ]]; then
  info "No cluster yet — ./scripts/create-cluster.sh writes the /etc/hosts block (asks for sudo once)"
  info "  Preview the lines: ./scripts/install.sh --print-hosts"
else
  check_fail "/etc/hosts is missing $(hosts_missing_names | wc -l | tr -d ' ') CloudBox name(s): $(hosts_missing_names | tr '\n' ' ')"
  echo "     Fix: ./scripts/install.sh --print-hosts   # then add them, or re-run create-cluster.sh"
fi
```
  and resolve the substrate once near the top of `--check`, after the platform section: `SUBSTRATE="$(substrate_resolve)"` with an `info "Substrate: ${SUBSTRATE}"` and, when it fell back, `info "  (tbx not used: $(substrate_doctor_reason))"` — this is the spec's requirement that `--check` prints which substrate will be used and the failing `tbx doctor` line.
- [ ] **Step 6: Call the writer from `create-cluster.sh`,** right after `substrate_post_cni`:
```sh
# docker has no resolver: the hostnames come from a marked /etc/hosts block.
# This is the one sudo prompt in the whole workshop, and it is on the create
# path only — install.sh --check verifies, never writes.
[[ "${SUBSTRATE}" == "docker" ]] && write_hosts_block
```
- [ ] **Step 7: Remove it on purge.** In `scripts/destroy-cluster.sh`, inside the `if [[ "${PURGE_MIRROR}" == "true" ]]` branch (`:170-174`), before the mirror removal, add `remove_hosts_block`, and update the script header's Usage block (`:9-12`) to `#   ./scripts/destroy-cluster.sh --purge-mirror  # also remove mirror + volume + the /etc/hosts block`. (The spec calls this flag `--purge`; the flag in this repo is `--purge-mirror` and is not renamed — renaming the documented recovery flag eight days out is a worse trade than the naming mismatch.)
- [ ] **Step 8: Test the block logic against a throwaway file, no sudo.**
```sh
cp /etc/hosts /tmp/hosts.test
bash -c 'source scripts/lib.sh; CLOUDBOX_HOSTS_FILE=/tmp/hosts.test; hosts_block_present && echo present || echo absent'
bash -c 'source scripts/lib.sh; cloudbox_hosts_block' >> /tmp/hosts.test
bash -c 'source scripts/lib.sh; CLOUDBOX_HOSTS_FILE=/tmp/hosts.test; hosts_block_present && echo present || echo absent'
bash -c 'source scripts/lib.sh; CLOUDBOX_HOSTS_FILE=/tmp/hosts.test; remove_hosts_block' 2>/dev/null || true
diff /etc/hosts /tmp/hosts.test
```
  Expected: `absent`, then `present`, then `diff` reports no differences after removal — the block is exactly reversible.
- [ ] **Step 9: Run the test, expect pass.** `bash /tmp/t12.sh` → `ok`, and `./scripts/install.sh --print-hosts` prints 12 `127.0.0.1 …` lines between the two markers.
- [ ] **Step 10: `shellcheck -x --source-path=scripts scripts/*.sh scripts/substrate/*.sh`** → exit 0.
- [ ] **Step 11: Commit.**
```
feat(install): maintain a marked /etc/hosts block for the docker substrate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 13: The URL sweep, and the consistency check that keeps it swept

235 `localhost:3…` literals, 42 `sslip.io` and 112 bare NodePort references exist across the tree. Three categories must **not** be swept, and getting that wrong is worse than not sweeping at all:

1. **`localhost:30500` as a node-side pull host.** `serving-core.yaml:7648` (`registries-skipping-tag-resolving`), `apps/portal/internal/kube/functions.go:33` (`fnPullHost`), `lab/07-ci/hello-site.yaml:25`, `solutions/module-0{7,8,9,10}/components/demo/hello-site.yaml:25` and their tests. That address is the NODE's own NodePort — with kube-proxy replacement it answers on every node on **both** substrates, and a VM cannot resolve `zot.cloudbox.k8s.test`. It stays.
2. **`localhost:5001`** — the crane mirror on the HOST, addressed from the host by `cloudbox-init.sh` and `install.sh`. It stays (nodes reach it via `CLOUDBOX_HOST_GATEWAY`).
3. **`slides/README.md:13`** — `localhost:3030` is the Slidev dev server, not a NodePort.

**Files:**
- Modify: `lab/common.sh:30-31`; `lab/0{2,3,4,6,7,8,9}` and `lab/10` READMEs, `solve.sh`, `verify.sh`; `lab/04-self-service/examples/my-application.yaml`
- Modify: `solutions/module-*/README.md`, `solutions/module-07/post.sh`
- Modify: `gitops/catalog/{backstage,grafana,nats,portal,rustfs,zot}.yaml` header comments; `gitops/components/application-xr/composition.yaml:50` + `VENDOR.md:20`
- Modify: `apps/README.md`, `apps/portal/internal/web/{applications.go:46-71,application_detail.go:79}`
- Modify: `slides/pages/module-0{2,3,6,7,8,9}.md`, `slides/pages/how.md:97`, `slides/pages/stack.md:122`
- Modify: `scripts/README.md:83-86`, `scripts/seed-gitea.sh:7`
- Modify: `scripts/check-consistency.sh` (new check 11)
- Test: `./scripts/check-consistency.sh`, `go test ./...`, `bash lab/*/verify.sh`

**Interfaces:**
- Consumes: `GITEA_HOST_URL`, `PORTAL_HOST_URL`, `GRAFANA_HOST_URL`, `RUSTFS_S3_HOST_URL`, `ZOT_HOST_URL`, `ARGOCD_HOST_URL`, `KNATIVE_DOMAIN`
- Produces: a tree with no browser-facing `localhost:3xxxx` literal outside the allowlist

- [ ] **Step 1: Write the failing guard as check 11 in `check-consistency.sh`,** after check 10:
```sh
# --- 11. no browser-facing localhost:3xxxx literals ---------------------------
# The workshop serves one hostname scheme on both substrates. A leftover
# localhost:30xxx URL works on exactly one of them, so it reads as a working
# instruction and fails on half the room — the worst kind of stale text.
#
# Three allowlisted exceptions, each for a reason a rewrite would break:
#   * scripts/substrate/docker.sh — the docker backend's own port publishing.
#   * localhost:30500 — Zot's NodePort as the NODE sees it. Node-side image
#     pulls and Knative's registries-skipping-tag-resolving must use it: with
#     kube-proxy replacement it answers on every node on both substrates, and a
#     tbx VM cannot resolve zot.cloudbox.k8s.test.
#   * localhost:3030 — the Slidev dev server (slides/README.md), not a NodePort.
before_fail=${FAILURES}
stale="$(grep -rnE 'localhost:3[0-9]{4}' \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' --include='*.go' \
  lab solutions gitops scripts slides apps .devcontainer .github README.md PLAN.md 2>/dev/null \
  | grep -v '^scripts/substrate/docker.sh:' \
  | grep -v 'localhost:30500' \
  | grep -v '^docs/' || true)"
if [[ -n "${stale}" ]]; then
  bad "browser-facing localhost:3xxxx literals remain — they only work on the docker substrate:"
  printf '   %s\n' "${stale}" | head -30
else
  ok "no stale localhost:3xxxx literals (the hostname scheme is the only browser URL)"
fi
stale_sslip="$(grep -rn 'sslip\.io' \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' --include='*.go' \
  lab solutions gitops scripts slides apps 2>/dev/null || true)"
if [[ -n "${stale_sslip}" ]]; then
  bad "127.0.0.1.sslip.io references remain — Knative's config-domain is now ${CLOUDBOX_DOMAIN}-based:"
  printf '   %s\n' "${stale_sslip}" | head -30
else
  ok "no sslip.io references outside docs/"
fi
[[ "${FAILURES}" -eq "${before_fail}" ]] || true
```
- [ ] **Step 2: Run it, expect a large failure.** `./scripts/check-consistency.sh` → both new `❌ FAIL:` blocks with dozens of lines, exit 1. This is the worklist.
- [ ] **Step 3: `lab/common.sh` first — it is the one every lab script passes through.** Replace lines 30-31:
```sh
# The platform's git remote, as the HOST sees it. One hostname on both
# substrates (tbx resolves it to the ingress VIP; docker via /etc/hosts).
# Overridable so someone whose hosts block is missing can still work:
#   GITEA_HOST=localhost:30300 ./verify.sh
GITEA_HOST="${GITEA_HOST:-gitea.${CLOUDBOX_DOMAIN}}"
GITEA_REPO_URL="${GITEA_REPO_URL:-http://gitea_admin:cloudbox123@${GITEA_HOST}/cloudbox/platform.git}"
```
  `CLOUDBOX_DOMAIN` is already in scope — `common.sh:17` sources `scripts/versions.env`.
- [ ] **Step 4: Sweep `lab/`** — 84 hits. Mechanical map, applied with review (never a blind `sed`, because of the exceptions above):
  `http://localhost:30300` → `http://gitea.cloudbox.k8s.test` · `:30080` → `http://argocd.cloudbox.k8s.test` · `:30030` → `http://grafana.cloudbox.k8s.test` · `:30600` → `http://portal.cloudbox.k8s.test` · `:30700` → `http://backstage.cloudbox.k8s.test` · `:30900` → `http://s3.cloudbox.k8s.test` · `:31080` + Host header → the plain ksvc URL. Bare `:30300`/`:30080`/`:30600`/`:30900`/`:31080` prose in READMEs becomes the hostname. **Skip** every `localhost:30500` and `localhost:5001`.
- [ ] **Step 5: Rewrite the `lab/06-serverless` curl instructions** — this is the one place the change is pedagogical, not cosmetic. `README.md:27,61,92,122` and `solve.sh:27` lose the Host header:
```sh
curl "$(kubectl -n demo get ksvc hello -o jsonpath='{.status.url}')/"
```
  and the README gains, under the existing hints: "On the docker substrate `/etc/hosts` cannot hold a wildcard, so only the ksvc names `install.sh --print-hosts` lists resolve. For a ksvc you invent yourself, either add a line for it or use the Host-header form: `curl -H \"Host: <the ksvc host>\" http://localhost/`."
- [ ] **Step 6: Sweep `solutions/`** (31 hits — all header comments in `apps/*.yaml` copied from `gitops/catalog/`) **by re-copying, not editing.** These files are byte-compared by check 1 of `check-consistency.sh`, so edit `gitops/catalog/*.yaml` and then `cp gitops/catalog/<x>.yaml solutions/module-NN/apps/<x>.yaml` for every existing copy. `solutions/module-07/post.sh:24,49` keeps its `localhost:30500` lines.
- [ ] **Step 7: Sweep `apps/`.** `apps/README.md:79-80,101,104,126`; `apps/portal/internal/web/applications.go:46,70-71` and `application_detail.go:79` — the composed-app URL becomes `fmt.Sprintf("http://%s.%s.%s", name, ns, knativeDomain)` with `knativeDomain` a new field on `Server` defaulting to `kn.cloudbox.k8s.test` from a `KNATIVE_DOMAIN` env var (add it to `apps/portal/config.go` next to `GrafanaURL`, and to `gitops/components/portal/portal.yaml`'s env list). The `:31080` suffix disappears — the ingress serves it on 80.
- [ ] **Step 8: Sweep `slides/`, `scripts/README.md`, `scripts/seed-gitea.sh:7`, `gitops/catalog/*.yaml`, `gitops/components/application-xr/`.** For `application-xr`, `composition.yaml:50` and `VENDOR.md:20` become `http://<name>.<namespace>.kn.cloudbox.k8s.test`; run `./scripts/check-vendor-drift.sh --only application-xr` afterwards and update its allow-hunk id the same way as Task 11 Step 9.
- [ ] **Step 9: `cd apps/portal && go test ./...`** → green. Update the remaining fixtures (`component_detail_test.go:250,272,302,352-356`, `templates_test.go:158,174`) to the `kn.cloudbox.k8s.test` form; leave the `localhost:30500` assertions alone.
- [ ] **Step 10: `./scripts/check-consistency.sh`** → both check-11 lines green, `✅ no drift detected`, exit 0.
- [ ] **Step 11: Prove the guard bites.** `echo '# see http://localhost:30600' >> lab/README.md && ./scripts/check-consistency.sh; git checkout lab/README.md` → expect the FAIL block naming `lab/README.md`, exit 1.
- [ ] **Step 12: Re-run every lab verifier against a live docker cluster.** `for m in 02 03 04 06 07 08 09; do bash "lab/${m}-"*/verify.sh || echo "MODULE ${m} FAILED"; done` → no `MODULE … FAILED` lines.
- [ ] **Step 13: Commit** (two commits, so the guard is reviewable apart from the sweep):
```
docs: sweep every browser URL onto the cloudbox.k8s.test scheme

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```
```
feat(check-consistency): fail on stale localhost:3xxxx and sslip.io literals

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 14: Offline — `tbx cache pull`, the `install.sh` cache assertion, and Cilium's ingress images

**Files:**
- Modify: `scripts/cloudbox-init.sh` (new section 5, after the Ollama block at `:260-274`)
- Modify: `scripts/install.sh` (a tbx branch in the pre-pulled-images section, `:180-331`)
- Modify: `scripts/images.txt` (only if the Cilium ingress images are genuinely absent)
- Test: `bash -n`, `shellcheck`, a real offline create

**Interfaces:**
- Consumes: `TALOS_VERSION`, `TBX_CLUSTER_FILE`, `SUBSTRATE`
- Produces: `~/.talosbox/cache/` populated with the Talos raw disk image; `install.sh --check` asserting it

- [ ] **Step 1: Check whether Cilium's ingress needs a new image at all.** The spec says to verify rather than assume:
```sh
source scripts/versions.env
helm template cilium "scripts/manifests/cilium-${CILIUM_VERSION}.tgz" -n kube-system \
  --set ingressController.enabled=true --set ingressController.loadbalancerMode=shared \
  --set l2announcements.enabled=true --set ingressController.service.type=NodePort \
  | grep -oE 'image: "?[^" ]+' | sed 's/image: "\?//' | sort -u
```
  Compare each ref against `scripts/images.txt`. Expectation from `images.txt:46-49`: `cilium`, `operator-generic` and `cilium-envoy` are already pinned by digest, and 1.20.0 runs Envoy as a DaemonSet regardless of the ingress controller — so **no new image**. If a ref is missing, add it to `images.txt` in the `[mirror]` section in the Cilium block, digest-pinned, and re-run `./scripts/check-consistency.sh` (check 2 covers deployed-image coverage).
- [ ] **Step 2: Write the failing test.** Create `/tmp/t14.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
grep -q 'tbx cache pull' "$R/scripts/cloudbox-init.sh" || { echo "FAIL: cloudbox-init does not warm the tbx cache"; exit 1; }
grep -q 'talosbox/cache' "$R/scripts/install.sh"       || { echo "FAIL: install.sh does not check the tbx cache"; exit 1; }
grep -q 'tbx doctor' "$R/scripts/cloudbox-init.sh"     || { echo "FAIL: cloudbox-init does not run tbx doctor"; exit 1; }
echo ok
```
- [ ] **Step 3: Run it, expect fail.** `bash /tmp/t14.sh` → `FAIL: cloudbox-init does not warm the tbx cache`.
- [ ] **Step 4: Add section 5 to `scripts/cloudbox-init.sh`,** after the Ollama block and before the closing `info "Next: …"`:
```sh
# --- 5. Talos disk image for the tbx substrate ---------------------------------
# The crane mirror above covers CONTAINER images. The tbx substrate also needs
# the Talos RAW DISK IMAGE, which talos-box downloads from the Image Factory and
# decompresses into ~/.talosbox/cache/ — 95 MB on arm64, 204 MB on amd64
# (measured). That download is Factory-side and cannot go through our mirror, so
# it must happen at home like everything else.
#
# --talos-version pins one ad-hoc combination (cmd/tbx/cache_pull.go:23,39-44):
# naming it deliberately skips the file-driven mode that would ALSO warm tbx's
# own registry mirror. Adopting that mirror is a spec non-goal — the crane
# mirror on localhost:${MIRROR_PORT} stays the single container-image store.
SUBSTRATE="$(substrate_resolve)"
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  step "Pre-pulling the Talos ${TALOS_VERSION} disk image for tbx"
  if tbx cache pull --talos-version "${TALOS_VERSION}"; then
    ok "Talos disk image cached in ~/.talosbox/cache"
    tbx_cached="yes"
  else
    warn "'tbx cache pull --talos-version ${TALOS_VERSION}' failed — the first"
    warn "create will download it, which needs the Image Factory. Retry at home."
    tbx_cached="no"
  fi
  step "Checking the tbx host setup"
  if tbx doctor; then
    ok "tbx doctor passes"
    tbx_doctor="pass"
  else
    warn "tbx doctor reports problems (above). Fix them, or use the docker"
    warn "substrate: CLOUDBOX_SUBSTRATE=docker ./scripts/create-cluster.sh"
    tbx_doctor="fail"
  fi
  info "Prework summary: images=${total} mirrored · talos-disk=${tbx_cached} · tbx-doctor=${tbx_doctor}"
else
  info "Prework summary: images=${total} mirrored · substrate=docker (no Talos disk image needed)"
fi
```
- [ ] **Step 5: Assert the cache from `install.sh --check`.** In the pre-pulled-images section, before the `images.txt` loop:
```sh
if [[ "${SUBSTRATE}" == "tbx" ]]; then
  # The raw disk image every VM boots from. Nested by schematic/version/arch
  # (upstream docs/SPEC.md:110-113), so match on the version directory rather
  # than guessing the schematic id — ours is talos-box's own default.
  if find "${HOME}/.talosbox/cache" -type d -name "${TALOS_VERSION}" 2>/dev/null | grep -q .; then
    ok "Talos ${TALOS_VERSION} disk image is cached for tbx"
  else
    check_fail "no Talos ${TALOS_VERSION} disk image in ~/.talosbox/cache — run ./scripts/cloudbox-init.sh (needs the Image Factory, so do it at home)"
  fi
fi
```
- [ ] **Step 6: Run the test, expect pass.** `bash /tmp/t14.sh` → `ok`.
- [ ] **Step 7: `bash -n scripts/cloudbox-init.sh scripts/install.sh && shellcheck -x --source-path=scripts scripts/*.sh`** → exit 0.
- [ ] **Step 8: Prove it offline.** With `~/.talosbox/cache` populated and the crane mirror running, disable networking (macOS: `networksetup -setairportpower en0 off`), then `CLOUDBOX_SUBSTRATE=tbx ./scripts/create-cluster.sh`. Expected: the cluster comes up with no network access. Re-enable afterwards. Record the wall-clock in `docs/REHEARSALS.md` in Task 18.
- [ ] **Step 9: Commit.**
```
feat(cloudbox-init): warm the tbx Talos disk cache during prework

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 15: Template Kagent's Ollama endpoint from `CLOUDBOX_HOST_GATEWAY`

`gitops/components/kagent/kagent.yaml:1457` hardcodes `host: host.docker.internal:11434`, which is a docker-substrate address. On tbx the host is the cluster gateway `172.30.<n>.1`; on native Linux docker it is `10.5.0.1`. `lab/10-day2-ops/README.md:338-350` currently makes native-Linux attendees hand-edit it. One templating removes all three cases.

**Files:**
- Modify: `scripts/bootstrap-gitops.sh` (a new patch step)
- Modify: `gitops/components/kagent/kagent.yaml:1457` (comment only — the value stays as the in-git default)
- Modify: `gitops/components/kagent/VENDOR.md:39,162-170`
- Modify: `lab/10-day2-ops/README.md:338-365`
- Test: `kubectl get modelconfig -o yaml`, the lab-10 inference check

**Interfaces:**
- Consumes: `CLOUDBOX_HOST_GATEWAY` (exported by `substrate_create`; re-derived here because `bootstrap-gitops.sh` runs in its own shell)
- Produces: a ConfigMap `kagent-ollama-host` in ns `kagent` and a post-sync patch, or a direct patch of the `ModelConfig`

- [ ] **Step 1: Confirm `cloudbox_host_gateway()` is available.** It was added to `scripts/lib.sh` in Task 1 and already answers for both substrates — this task **consumes** it and must not redefine it. Verify: `bash -c 'source scripts/lib.sh; CLOUDBOX_SUBSTRATE=docker; unset CLOUDBOX_HOST_GATEWAY; cloudbox_host_gateway'` → `host.docker.internal` on macOS, `10.5.0.1` on native Linux; with `CLOUDBOX_SUBSTRATE=tbx` against a running tbx cluster → `172.30.0.1`.
- [ ] **Step 2: Write the failing test.** Create `/tmp/t15.sh`:
```sh
#!/usr/bin/env bash
set -euo pipefail
R=/Users/oyr/projects/Platform-Engineering-Workshop
source "$R/scripts/lib.sh"
declare -F cloudbox_host_gateway >/dev/null || { echo "FAIL: no cloudbox_host_gateway"; exit 1; }
CLOUDBOX_SUBSTRATE=docker; [[ -n "$(cloudbox_host_gateway)" ]] || { echo "FAIL: empty gateway"; exit 1; }
grep -q 'kagent-ollama-host\|patch modelconfig\|OLLAMA_HOST' "$R/scripts/bootstrap-gitops.sh" \
  || { echo "FAIL: bootstrap-gitops does not template the kagent Ollama host"; exit 1; }
echo ok
```
- [ ] **Step 3: Run it, expect fail.** `bash /tmp/t15.sh` → `FAIL: no cloudbox_host_gateway`.
- [ ] **Step 4: Add the patch step to `scripts/bootstrap-gitops.sh`,** after the ingress applies from Task 10:
```sh
# --- Kagent's host-side Ollama ---------------------------------------------------
# kagent's default ModelConfig points at a host-side Ollama (module 10). The
# address of "the host" is substrate- and OS-specific, and it used to be
# hardcoded to host.docker.internal — which native-Linux attendees had to
# hand-edit (lab/10-day2-ops/README.md) and which no tbx VM can resolve at all.
# Record the right answer once, here, where the substrate is known. The
# ModelConfig may not exist yet (kagent is a stretch catalog item enabled later),
# so this writes a ConfigMap the module-10 lab reads and applies the patch
# opportunistically — never failing the bootstrap over an optional component.
gateway="$(cloudbox_host_gateway)"
info "Host gateway for in-cluster workloads: ${gateway}"
kubectl create namespace kagent --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n kagent create configmap cloudbox-host \
  --from-literal=gateway="${gateway}" \
  --from-literal=ollama="${gateway}:11434" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if kubectl -n kagent get modelconfig default-model-config >/dev/null 2>&1; then
  kubectl -n kagent patch modelconfig default-model-config --type merge \
    -p "{\"spec\":{\"ollama\":{\"host\":\"${gateway}:11434\"}}}"
  ok "kagent ModelConfig points at ${gateway}:11434"
else
  info "kagent is not enabled yet — its Ollama host (${gateway}:11434) is recorded in configmap kagent/cloudbox-host"
fi
```
- [ ] **Step 5: Make the patch survive ArgoCD self-heal.** `gitops/catalog/kagent.yaml` has `syncPolicy.automated.selfHeal: true`, so ArgoCD will revert the patch to the git value. Add to the kagent Application's `spec.syncPolicy.syncOptions` in `gitops/catalog/kagent.yaml`: `- RespectIgnoreDifferences=true`, and add to the same Application:
```yaml
  ignoreDifferences:
    # The Ollama host is a MACHINE fact (which substrate, which OS), decided by
    # bootstrap-gitops.sh from cloudbox_host_gateway(). Git carries a default
    # that is right for exactly one of the three cases; letting selfHeal fight
    # the patch would break kagent on the other two.
    - group: kagent.dev
      kind: ModelConfig
      name: default-model-config
      namespace: kagent
      jsonPointers:
        - /spec/ollama/host
```
  Then `cp gitops/catalog/kagent.yaml solutions/module-10/apps/kagent.yaml` if that copy exists, so check 1 stays green.
- [ ] **Step 6: Update the vendored comment and VENDOR.md.** `kagent.yaml:1457` keeps `host: host.docker.internal:11434` as the git default but gains, above it, a comment: `# Patched at bootstrap to cloudbox_host_gateway() — 172.30.<n>.1 on tbx, host.docker.internal or 10.5.0.1 on docker. See scripts/bootstrap-gitops.sh; the kagent Application ignoreDifferences this field.` Rewrite `VENDOR.md:39` and `:162-170` to say the same, deleting the "Native Linux users must replace" instruction.
- [ ] **Step 7: Rewrite `lab/10-day2-ops/README.md:338-365`,** replacing the hand-edit instructions with a short "how to check it" block:
```sh
kubectl -n kagent get modelconfig default-model-config -o jsonpath='{.spec.ollama.host}{"\n"}'
kubectl -n kagent get configmap cloudbox-host -o jsonpath='{.data.ollama}{"\n"}'
# Ollama must listen on that address, not only on loopback:
OLLAMA_HOST=0.0.0.0 ollama serve
kubectl -n gitea exec deploy/gitea -c gitea -- wget -qO- "http://$(kubectl -n kagent get cm cloudbox-host -o jsonpath='{.data.gateway}'):11434/api/version"
```
- [ ] **Step 8: Run the test, expect pass.** `bash /tmp/t15.sh` → `ok`.
- [ ] **Step 9: Live check.** After `bootstrap-gitops.sh` on each substrate: `kubectl -n kagent get cm cloudbox-host -o jsonpath='{.data.ollama}{"\n"}'` → `host.docker.internal:11434` on macOS docker, `172.30.0.1:11434` on tbx. Then enable kagent and run `bash lab/10-day2-ops/verify.sh`.
- [ ] **Step 10: `shellcheck -x --source-path=scripts scripts/*.sh` and `./scripts/check-consistency.sh`** → exit 0 both.
- [ ] **Step 11: Commit.**
```
fix(kagent): template the Ollama host from the substrate's gateway

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 16: Substrate-aware `lab/00`, `lab/01` and `lab/06` verifiers

Verifiers stay substrate-blind everywhere they can. Only three checks genuinely cannot be: the resource check (Docker's limits vs the host's), the node-identity check (containers vs VMs), and lab 06's ingress path.

**Files:**
- Modify: `lab/00-setup/verify.sh:14-46,64-75`
- Modify: `lab/01-cluster/verify.sh:9-17,42`
- Modify: `lab/06-serverless/verify.sh:72-85`
- Modify: `lab/00-setup/README.md` (the task list and the hardware block)
- Test: run each verifier on both substrates

**Interfaces:**
- Consumes: `substrate_resolve()`, `substrate_current()`, `CLOUDBOX_DOMAIN`, `KNATIVE_DOMAIN`
- Produces: verifiers that exit 0 on a healthy cluster of either kind

- [ ] **Step 1: `lab/00-setup/verify.sh` — branch the resource checks.** It sources `versions.env` at `:8` but not `lib.sh`; add `source "$REPO_ROOT/scripts/lib.sh"` is **wrong** here (lib.sh defines `ok`/`fail` and would clobber this file's counting versions — the same trap `lab/01-cluster/verify.sh:19-31` documents). Instead inline the resolution:
```sh
# Which substrate this laptop will use. Read the persisted answer if a cluster
# already exists, else ask tbx. Inlined rather than sourced: scripts/lib.sh
# defines its own non-counting ok()/fail() and would silently clobber the
# counting ones above — the trap lab/01-cluster/verify.sh:19-31 records.
SUBSTRATE="${CLOUDBOX_SUBSTRATE:-}"
if [ -z "$SUBSTRATE" ] && [ -r "$HOME/.cloudbox/substrate" ]; then
  SUBSTRATE="$(tr -d '[:space:]' < "$HOME/.cloudbox/substrate")"
fi
if [ -z "$SUBSTRATE" ]; then
  if command -v tbx >/dev/null 2>&1 && tbx doctor >/dev/null 2>&1; then SUBSTRATE=tbx; else SUBSTRATE=docker; fi
fi
ok "substrate: $SUBSTRATE"
```
  Then wrap the Docker memory/CPU checks (`:23-38`) in `if [ "$SUBSTRATE" = docker ]; then … fi` and add the tbx branch:
```sh
else
  # tbx runs real VMs, so what matters is HOST memory, not Docker's slice.
  # The published floor is 16 GB (upstream requires it too, docs/SPEC.md:27).
  if [ "$(uname -s)" = Darwin ]; then
    HOST_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  else
    HOST_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  fi
  if [ "$HOST_GB" -ge 16 ]; then
    ok "host memory: ${HOST_GB} GB (need >= 16 for the VM substrate)"
  else
    fail "host memory: ${HOST_GB} GB — the tbx substrate needs >= 16 GB. Use the docker substrate instead: CLOUDBOX_SUBSTRATE=docker"
  fi
  if tbx doctor >/dev/null 2>&1; then
    ok "tbx doctor passes"
  else
    fail "tbx doctor reports problems — run 'tbx doctor' to see them, or use CLOUDBOX_SUBSTRATE=docker"
  fi
fi
```
  The Docker-daemon check at `:14-21` stays unconditional for both — the crane mirror is a Docker container on every substrate.
- [ ] **Step 2: `lab/00-setup/verify.sh` — add `tbx` to the tool loop** at `:49`, docker-substrate-exempt: change the loop to iterate `talosctl kubectl helm cilium jq git curl` and then, when `SUBSTRATE=tbx`, additionally check `tbx`.
- [ ] **Step 3: `lab/01-cluster/verify.sh` — branch the node-identity check** at `:9-17`:
```sh
# --- Nodes exist at the substrate level -------------------------------------
# The one check in this file that cannot be substrate-blind: on docker the nodes
# are containers Talos labels talos.cluster.name=cloudbox; on tbx they are VMs
# only `tbx status` can see. Everything below this is plain kubectl and is
# identical on both — which is the whole point of the substrate contract.
SUBSTRATE="${CLOUDBOX_SUBSTRATE:-}"
if [ -z "$SUBSTRATE" ] && [ -r "$HOME/.cloudbox/substrate" ]; then
  SUBSTRATE="$(tr -d '[:space:]' < "$HOME/.cloudbox/substrate")"
fi
[ -n "$SUBSTRATE" ] || SUBSTRATE=docker
if [ "$SUBSTRATE" = tbx ]; then
  NODES="$(tbx status cloudbox -o json 2>/dev/null | jq -r '[.nodes[] | select(.phase == "configured")] | length' 2>/dev/null || echo 0)"
  if [ "${NODES:-0}" -ge 2 ]; then
    ok "cloudbox Talos VMs are running and configured (${NODES})"
  else
    fail "expected 2 configured Talos VMs, found ${NODES:-0} — 'tbx status cloudbox', then ./scripts/create-cluster.sh"
  fi
else
  # Filter on the talosctl-applied label — a name prefix would also match the
  # cloudbox-mirror registry container.
  CONTAINERS="$(docker ps -q --filter "label=talos.cluster.name=cloudbox" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${CONTAINERS:-0}" -ge 2 ]; then
    ok "cloudbox Talos node containers are running (${CONTAINERS})"
  else
    fail "expected 2 running Talos node containers, found ${CONTAINERS:-0} — run ./scripts/create-cluster.sh"
  fi
fi
```
- [ ] **Step 4: Fix the `kubectl` failure hint** at `lab/01-cluster/verify.sh:42`, which names a docker-only recovery:
```sh
  fail "kubectl cannot reach the cluster — did create-cluster.sh finish? Re-run ./scripts/create-cluster.sh (it points the kubeconfig at the API server your substrate publishes: https://127.0.0.1:\$(docker port cloudbox-controlplane-1 6443/tcp) on docker, the control-plane VM's own https://172.30.<n>.2:6443 on tbx)"
```
  The Ready-count check (`:47-53`), Cilium DaemonSet, operator, kube-proxy-absent, `KubeProxyReplacement` and CoreDNS checks all stay exactly as they are — they are the substrate contract and must not branch.
- [ ] **Step 5: Add a shared-ingress check to `lab/01-cluster/verify.sh`,** after the CoreDNS check, because "the ingress endpoint exists" is now part of what module 01 delivers:
```sh
# --- Shared ingress ---------------------------------------------------------
ING_TYPE="$(kubectl -n kube-system get svc cilium-ingress -o jsonpath='{.spec.type}' 2>/dev/null || true)"
if [ "$SUBSTRATE" = tbx ]; then
  VIP="$(kubectl -n kube-system get svc cilium-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -n "$VIP" ]; then
    ok "shared ingress has the LoadBalancer VIP ${VIP} (every *.cloudbox.k8s.test name lands here)"
  else
    fail "cilium-ingress has no LoadBalancer address (type ${ING_TYPE:-missing}) — kubectl get ciliumloadbalancerippools; kubectl -n kube-system describe svc cilium-ingress"
  fi
else
  if [ "$ING_TYPE" = NodePort ]; then
    ok "shared ingress is a NodePort, published on host port 80"
  else
    fail "cilium-ingress is '${ING_TYPE:-missing}', want NodePort on the docker substrate — was the cluster made by ./scripts/create-cluster.sh?"
  fi
fi
```
- [ ] **Step 6: `lab/06-serverless/verify.sh` — accept either path.** Replace `:72-85`:
```sh
# --- Cold start / serving through the ingress -----------------------------------
# Two accepted paths, because /etc/hosts has no wildcards. Preferred: the ksvc's
# own URL, browsable with no Host header and no port — that works on tbx for
# every name, and on docker for the names install.sh --print-hosts lists.
# Fallback: the Host-header form against the shared ingress on port 80, which
# works for any ksvc on either substrate. Both prove the same thing.
URL="$(kubectl -n demo get ksvc hello -o jsonpath='{.status.url}' 2>/dev/null || true)"
HOST="${URL#http://}"; HOST="${HOST#https://}"
if [ -n "$HOST" ]; then
  BODY="$(curl -fsS --max-time 30 "http://${HOST}/" 2>/dev/null || true)"
  VIA="its own URL (http://${HOST}/)"
  if ! echo "$BODY" | grep -qi hello; then
    BODY="$(curl -fsS --max-time 30 -H "Host: ${HOST}" http://localhost/ 2>/dev/null || true)"
    VIA="the shared ingress with a Host header"
  fi
  if echo "$BODY" | grep -qi hello; then
    ok "curl via ${VIA} answered: $(echo "$BODY" | head -1)"
  else
    fail "no answer for ${HOST} — try: curl -v -H 'Host: ${HOST}' http://localhost/ ; if that works, the name is missing from /etc/hosts (./scripts/install.sh --print-hosts). If neither works: kubectl -n kourier-system get svc kourier; kubectl get ingress -A"
  fi
else
  fail "cannot determine ksvc URL — fix the ksvc checks above first"
fi
```
- [ ] **Step 7: Update `lab/00-setup/README.md`.** In the task list (`:24-38`) insert a new step 0 for tbx users and rewrite the hardware block (`:40-44`):
```md
0. **Pick your substrate.** On an Apple Silicon Mac (or Linux with KVM) install
   [talos-box](https://github.com/randax/talos-box) and you get real Talos VMs with real
   LoadBalancer addresses: `brew install randax/tap/tbx && sudo tbx system install && tbx doctor`.
   Everyone else — Windows/WSL2, Codespaces, or any machine `tbx doctor` is unhappy with —
   runs the identical workshop on Talos-in-Docker. The scripts decide for you; force it with
   `CLOUDBOX_SUBSTRATE=docker` (or `=tbx`) if you want to.

**Hardware reality check:** 16 GB RAM is the absolute minimum on both substrates, 32 GB is
comfortable. On Docker you also need ≥10 GB and ≥4 CPUs *allocatable to Docker*. macOS and
Linux are fully supported; Windows works via WSL2 (Docker substrate only) but is our
least-tested platform.

**Windows/WSL2 and the hostname block:** the workshop serves everything on
`*.cloudbox.k8s.test`. `create-cluster.sh` adds those names to WSL's `/etc/hosts` for you, but
your *Windows* browser reads `C:\Windows\System32\drivers\etc\hosts` — paste the same lines
there, as Administrator. Print them with `./scripts/install.sh --print-hosts`.
```
- [ ] **Step 8: Run both verifiers on a docker cluster.** `bash lab/00-setup/verify.sh && bash lab/01-cluster/verify.sh` → both exit 0, with `✅ substrate: docker` and `✅ shared ingress is a NodePort, published on host port 80`.
- [ ] **Step 9: Run both on a tbx cluster.** Same commands → `✅ substrate: tbx`, `✅ cloudbox Talos VMs are running and configured (2)`, `✅ shared ingress has the LoadBalancer VIP 172.30.0.200`.
- [ ] **Step 10: Prove lab 06 both ways.** With knative-serving enabled and `hello` deployed: `bash lab/06-serverless/verify.sh` → exit 0. Then remove the `hello.demo.kn.cloudbox.k8s.test` line from `/etc/hosts` and re-run → still exit 0, reporting `via the shared ingress with a Host header`. Restore the line.
- [ ] **Step 11: `bash -n lab/*/verify.sh && shellcheck lab/00-setup/verify.sh lab/01-cluster/verify.sh lab/06-serverless/verify.sh`** → exit 0.
- [ ] **Step 12: Commit.**
```
feat(lab): make 00, 01 and 06 verify either substrate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 17: CI and the devcontainer pin themselves to docker

**Files:**
- Modify: `.devcontainer/devcontainer.json:38-52`
- Modify: `.github/workflows/bootstrap-test.yaml` (job-level `env`, the smoke tests at `:125-131`)
- Modify: `.github/workflows/ci.yaml:55` (shellcheck must reach `scripts/substrate/`)
- Test: `./scripts/check-consistency.sh` (check 4 reads devcontainer.json), a CI run

**Interfaces:**
- Consumes: `CLOUDBOX_SUBSTRATE`
- Produces: a CI and Codespaces path that never attempts tbx

- [ ] **Step 1: Pin the devcontainer.** Add to `.devcontainer/devcontainer.json` after `hostRequirements`:
```json
  // Codespaces and dev containers are Docker-in-Docker: there is no hypervisor
  // and no KVM, so the tbx substrate cannot run here. Pinning it explicitly
  // means the dispatcher never even probes for tbx — and the lifeboat behaves
  // identically to every CI run, which is what makes it a tested path.
  "containerEnv": {
    "CLOUDBOX_SUBSTRATE": "docker"
  },
```
  and add port 80 to `forwardPorts` with a label, since the ingress now serves there:
```json
  "forwardPorts": [80, 30300, 30080, 30500, 30600, 30700, 30900, 30030, 31080, 30422],
  "portsAttributes": {
    "80": { "label": "Platform ingress (*.cloudbox.k8s.test)" },
```
  Add to the `postCreateCommand` comment block a note: `// The /etc/hosts block create-cluster.sh writes lands inside the container, which is where the browser preview resolves from — nothing to do on the Codespaces host.`
- [ ] **Step 2: Pin CI.** In `.github/workflows/bootstrap-test.yaml`, add to **both** jobs (`full-bootstrap` and `recovery-path`), at job level next to `timeout-minutes`:
```yaml
    env:
      # GitHub runners have no nested-virt: the tbx substrate is impossible here.
      # This is also the point — the docker substrate is the CI-PROVEN fallback,
      # and it must be exercised on every weekly run, not just when tbx fails.
      CLOUDBOX_SUBSTRATE: docker
```
- [ ] **Step 3: Give CI the hosts block.** Insert a step after `Create cluster (Talos + Cilium, wired to the mirror)`:
```yaml
      - name: Show the /etc/hosts block create-cluster.sh wrote
        run: |
          set -euo pipefail
          ./scripts/install.sh --print-hosts
          getent hosts gitea.cloudbox.k8s.test
          getent hosts hello.demo.kn.cloudbox.k8s.test
```
  `create-cluster.sh` writes the block itself; the runner is root-equivalent so its `sudo tee` needs no prompt. `getent` failing here is the earliest possible signal that the whole hostname scheme is broken.
- [ ] **Step 4: Move CI's smoke tests onto the hostnames.** `bootstrap-test.yaml:125-131` becomes:
```yaml
      - name: Smoke tests
        run: |
          set -euo pipefail
          kubectl get nodes -o wide
          kubectl -n kube-system get svc cilium-ingress -o wide
          curl -fsS http://gitea.cloudbox.k8s.test/api/healthz
          curl -fsS -o /dev/null http://argocd.cloudbox.k8s.test
          kubectl get application platform -n argocd -o wide
```
  The rest of the workflow's ~31 `localhost:3xxxx` URLs are covered by Task 13's sweep; re-run that sweep's grep over `.github/` before this step and fix what it finds, keeping every `localhost:30500` (`:851,890,891,1036` — the Zot node-side pull host) unchanged.
- [ ] **Step 5: Extend CI's shellcheck.** `.github/workflows/ci.yaml:55` becomes:
```yaml
          shellcheck -x --source-path=SCRIPTDIR scripts/*.sh scripts/substrate/*.sh
```
  Without this the entire substrate layer is unlinted — `scripts/*.sh` does not glob into subdirectories.
- [ ] **Step 6: Run the consistency check.** `./scripts/check-consistency.sh` → check 4 (devcontainer `MISE_VERSION`) still green; the JSON edit must not have broken it.
- [ ] **Step 7: Validate the JSON.** `python3 -c 'import json,re,sys; s=open(".devcontainer/devcontainer.json").read(); json.loads(re.sub(r"^\s*//.*$","",s,flags=re.M))'` → no output, exit 0.
- [ ] **Step 8: Run the workflow.** `gh workflow run bootstrap-test.yaml` and watch it to green (~60-90 min), or at minimum through the `Smoke tests` step. A `curl (6) Could not resolve host` there means the hosts block did not land — check `install.sh --print-hosts` output in the previous step.
- [ ] **Step 9: Commit.**
```
ci: pin CI and the devcontainer to the docker substrate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 18: Documentation — HAZARDS, README, PLAN, scripts/README, and the decision note

**Files:**
- Modify: `docs/HAZARDS.md` (five new entries)
- Modify: `README.md:85-160` (prerequisites, hardware, platform matrix, "At the venue")
- Modify: `PLAN.md:66-99` (target architecture), `:143-157` (risks)
- Modify: `scripts/README.md:52,83-86` (the URL table and the bootstrap description)
- Modify: `docs/talos-box-vs-docker.md` (a decision note at the top)
- Modify: `docs/MAINTENANCE.md` (the tbx pin's bump procedure)
- Test: `./scripts/check-consistency.sh`, a read-through

**Interfaces:**
- Consumes: everything above
- Produces: the written record a reader needs before changing any of it

- [ ] **Step 1: Add the decision note to `docs/talos-box-vs-docker.md`,** immediately after the "Short answer" paragraph (which currently ends `Detail and a work list below.`):
```md
> **Decision, 2026-08-24 (Øyvind Randa):** proceed anyway, with the risks stated in this
> document accepted rather than retired. talos-box becomes the primary substrate where
> `tbx doctor` passes; Talos-in-Docker stays a first-class, CI-proven fallback with its own
> users (Windows/WSL2, Codespaces, CI). The how is
> [docs/superpowers/specs/2026-08-24-talos-box-substrate-design.md](superpowers/specs/2026-08-24-talos-box-substrate-design.md);
> the work is
> [docs/superpowers/plans/2026-08-24-talos-box-substrate.md](superpowers/plans/2026-08-24-talos-box-substrate.md).
> **The gate stands:** if the full 00→10 rehearsal on tbx does not pass by Aug 31, the
> dispatcher default flips to `docker` (one line: `CLOUDBOX_SUBSTRATE_DEFAULT` in
> `scripts/versions.env`) and tbx remains available via `CLOUDBOX_SUBSTRATE=tbx`.
> The analysis below is unedited; it is what the decision was made against.
```
- [ ] **Step 2: Add the five HAZARDS entries,** in the file's existing `## <STATUS> — <headline>` style, each with what it is, how it shows up, and what retires it:
  - `## LIVE — tbx VM memory is a hard ceiling, and it is unrehearsed` — a Docker container's memory limit is soft against the host page cache; a VM's is not. `TBX_CP_MEMORY=4GiB` / `TBX_WORKER_MEMORY=8GiB` are guesses until Task 19 measures peak RSS at the module-10 end state. Symptom: pods OOMKilled or the kubelet evicting under a load the docker substrate survives. Retired by: the rehearsal's numbers landing in `versions.env`.
  - `## LIVE — L2 failover on macOS takes 40-50 s` — macOS ignores gratuitous ARP through vmnet and converges only on its own ARP revalidation (upstream `docs/SPEC.md` §5, "the slow-L2 failover caveat is macOS/vmnet-specific"). Symptom: stopping a node makes every `*.cloudbox.k8s.test` URL hang for the better part of a minute before the other node answers. Not a bug; do not "fix" it with BGP eight days out. Retired by: nothing in 2026.
  - `## TRAP — a full-tunnel VPN blackholes 172.30.0.0/16 while tbx doctor stays green` — `tbx doctor` checks host routes and forwarding, not whether a corporate VPN client has claimed the RFC1918 space above them. Symptom: the cluster is healthy, `tbx status` is green, and every host→VIP request times out. Diagnosis: `route get 172.30.0.200` naming a `utun*` interface. Fix: disconnect the VPN, or run `CLOUDBOX_SUBSTRATE=docker`.
  - `## TRAP — /etc/hosts needs sudo, and it is the only sudo in the workshop` — the docker substrate has no resolver, so `create-cluster.sh` writes a marked block and asks for a password once. Symptom on refusal: every hostname fails while the cluster is perfectly healthy. `install.sh --check` names the missing lines; `install.sh --print-hosts` prints them for hand-application (and for `C:\Windows\System32\drivers\etc\hosts`, which WSL2 users need separately).
  - `## TRAP — .200 resolves before anything owns it` — talos-box's resolver answers `*.<domain>` with the cluster's `.200` for the cluster's whole lifetime, "tied to the cluster's existence, not its run-state" (upstream `docs/SPEC.md` §5). Symptom: between `tbx up` and the Cilium ingress getting its VIP, every hostname resolves and every connection is refused — which reads like a broken ingress rather than one that does not exist yet. `substrate_post_cni()` waits for the VIP for exactly this reason.
- [ ] **Step 3: Rewrite `README.md:124-144`** (hardware + platform matrix) to lead with the substrate choice:
```md
### Hardware — honest numbers

| | tbx (real Talos VMs) | Docker (Talos-in-Docker) |
|---|---|---|
| Minimum | 16 GB RAM, 4 cores, 40 GB free | 16 GB RAM with **≥10 GB and ≥4 CPUs to Docker**, 40 GB free |
| Comfortable | 32 GB | 32 GB |
| What you get | real `LoadBalancer` VIPs, a real L2 segment | the same labs, the same URLs, via published ports |

### Platform support matrix

| Platform | Substrate | Support |
|---|---|---|
| macOS, Apple Silicon | tbx (Docker if `tbx doctor` fails) | fully supported |
| Linux, amd64/arm64 with KVM | tbx (Docker otherwise) | fully supported |
| macOS, Intel | Docker | fully supported |
| Windows via WSL2 | Docker | best-effort — pair up if it fights you |
| GitHub Codespaces / devcontainer | Docker | the lifeboat, tested weekly in CI |

Both substrates run **the same labs, the same `verify.sh` scripts and the same URLs**. The
scripts pick for you and remember the choice in `~/.cloudbox/substrate`; override with
`CLOUDBOX_SUBSTRATE=docker` or `=tbx`.
```
- [ ] **Step 4: Update `README.md:85-103` (prerequisites)** to add the optional tbx install (`brew install randax/tap/tbx && sudo tbx system install && tbx doctor`) as step 0, and `:145-162` ("At the venue") to mention the one sudo prompt on the docker path.
- [ ] **Step 5: Update `scripts/README.md`.** The URL table at `:83-86` becomes the hostname scheme (all nine names plus `*.kn.`), with a footnote: "On the Docker substrate these come from a marked `/etc/hosts` block; `./scripts/install.sh --print-hosts` prints it. The NodePort URLs (`http://localhost:30300` and friends) still work as a fallback." Add `substrate/docker.sh` and `substrate/tbx.sh` to the script inventory, and update `:52`'s bootstrap description to mention the two Ingress applies.
- [ ] **Step 6: Update `PLAN.md`.** In `## 3. Target architecture` add a substrate bullet naming both backends, `~/.cloudbox/substrate`, and the ingress scheme. In `## 5. Risks` add: "**Substrate swap eight days out (accepted, gated).** The analysis in `docs/talos-box-vs-docker.md` recommended against it; the owner proceeded. Mitigation is the fallback being first-class and CI-proven, plus a hard go-live gate on Aug 31 that flips the default back with a one-line change."
- [ ] **Step 7: Update `docs/MAINTENANCE.md`** with the tbx row in the pin table: bumping `TBX_VERSION` means (a) bump `mise.toml` in the same commit or check 10 fails, (b) re-read upstream `internal/config/config.go` for cluster-yaml schema changes and `internal/provision/inspection.go` for `tbx manifests` section renames, since `scripts/substrate/tbx.sh` calls `tbx up -f`, `tbx status -o json`, `tbx manifests <c> mirrors` and `tbx cluster destroy --force`, (c) re-run a full tbx rehearsal — there is no CI for this substrate.
- [ ] **Step 8: Add `tbx` to `scripts/upstream.list`** so `check-upstream.sh` tracks it, following the format of the rows already there, then `./scripts/check-consistency.sh` → check 6 (every upstream.list row resolves to a real pin) stays green.
- [ ] **Step 9: `./scripts/check-consistency.sh` and `./scripts/check-vendor-drift.sh --offline`** → exit 0 both.
- [ ] **Step 10: Commit.**
```
docs: record the substrate decision, its hazards and the go-live gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Task 19: The two rehearsals, the measurements, and the go-live gate

This task is the gate. It produces numbers, not code — except for the one line it may flip.

**Files:**
- Modify: `docs/REHEARSALS.md` (a new `## Rehearsal 5 — the substrate split` section)
- Modify: `scripts/versions.env` (`TBX_CP_MEMORY`, `TBX_WORKER_MEMORY` corrected from measurement; `CLOUDBOX_SUBSTRATE_DEFAULT` if the gate fails)
- Modify: `docs/HAZARDS.md` (retire or confirm the "unrehearsed sizing" entry from Task 18)
- Test: the rehearsals themselves

**Interfaces:**
- Consumes: everything
- Produces: a go/no-go, and `TBX_*` sizing backed by measurement

- [ ] **Step 1: tbx rehearsal, offline, on Apple Silicon.** Prework at home with WiFi (`./scripts/dev-setup.sh`, `./scripts/cloudbox-init.sh`, `./scripts/install.sh --check`), then **turn WiFi off** and run the whole workshop:
```sh
CLOUDBOX_SUBSTRATE=tbx ./scripts/create-cluster.sh
./scripts/bootstrap-gitops.sh && ./scripts/seed-gitea.sh
for m in 00 01 02 03 04 05 06 07 08 09 10; do
  d=$(echo lab/${m}-*)
  [ -x "$d/solve.sh" ] && bash "$d/solve.sh"
  /usr/bin/time -p bash "$d/verify.sh"; echo "MODULE ${m} rc=$?"
done
```
  Record each module's wall-clock and its rc. **Pass = every module rc 0, offline throughout.**
- [ ] **Step 2: Measure peak memory at the module-10 end state.** With every stretch capability enabled and the cluster idle for 5 minutes:
```sh
# Host-side: what the VMs actually consume, per node.
ps -o rss=,comm=,command= -p "$(pgrep -d, -f 'tbxd|qemu')" | awk '{ s += $1; print } END { printf "TOTAL RSS: %.1f GiB\n", s/1024/1024 }'
# macOS: the same figure the way Activity Monitor computes it.
sudo footprint -a 2>/dev/null | grep -Ei 'tbxd|qemu' || true
# Guest-side: what each node thinks it is using.
kubectl top nodes 2>/dev/null || \
  for n in $(kubectl get nodes -o name); do
    echo "== $n"; kubectl describe "$n" | sed -n '/Allocated resources/,/^Events/p'
  done
# The number that decides the pins: peak working set per node.
tbx status cloudbox -o json | jq -r '.nodes[] | "\(.name) \(.role)"'
```
  Also capture `/proc/pressure/memory` inside each node (`talosctl -n <ip> read /proc/pressure/memory`) and the host's swap usage (`sysctl vm.swapusage` on macOS).
- [ ] **Step 3: Correct the sizing pins.** Set `TBX_CP_MEMORY` and `TBX_WORKER_MEMORY` in `scripts/versions.env` to the measured peak plus ~25% headroom, rounded to a whole GiB. Record the raw measurements in the `versions.env` comment above them, the way `TALOS_CPU_FLOOR`'s comment records the CPU-pressure finding. Then re-run Step 1 with the corrected pins and confirm module 10 still passes.
- [ ] **Step 4: Docker rehearsal of the same content, same machine.** `./scripts/destroy-cluster.sh --purge-mirror` (which also removes the hosts block), re-run `cloudbox-init.sh`, then the same loop with `CLOUDBOX_SUBSTRATE=docker`. This is what proves the fallback is a real path and not a claim — pay particular attention to the `/etc/hosts` write (does it prompt exactly once?), the port-80 publish, and lab 06 both ways.
- [ ] **Step 5: Measure the substrate delta.** For both runs record: `create-cluster.sh` wall-clock, `bootstrap-gitops.sh` wall-clock, total scripted minutes (today's baseline is 16-32 min of the 240 — `docs/REHEARSALS.md`), and the module-10 end-state pod count (`kubectl get pods -A --no-headers | wc -l`). A tbx create materially slower than docker's is a room-time problem and belongs in the gate decision.
- [ ] **Step 6: Write `## Rehearsal 5 — the substrate split` into `docs/REHEARSALS.md`,** matching the file's existing style: what was run, on what hardware, the per-module timing table for both substrates, the memory measurements, what broke, and what each finding retires. Add any new lesson under `## What testing this taught us`.
- [ ] **Step 7: The gate decision, by Aug 31.**
  - **tbx rehearsal passed** → leave `CLOUDBOX_SUBSTRATE_DEFAULT="tbx"`. Update the Task-18 HAZARDS entry on VM sizing from `LIVE` to `PROVEN ONCE`, naming the machine and the numbers.
  - **tbx rehearsal did not pass** → one line in `scripts/versions.env`: `CLOUDBOX_SUBSTRATE_DEFAULT="docker"`. tbx stays fully available via `CLOUDBOX_SUBSTRATE=tbx`. Nothing else changes: no revert, no deleted code, no changed lab text — which is the whole reason the dispatcher exists. Record the failing evidence in `docs/REHEARSALS.md` and flip the `README.md` matrix's "Substrate" column to name Docker as the default everywhere.
- [ ] **Step 8: Prove the flip works before you need it.** Regardless of the outcome:
```sh
sed -i.bak 's/^CLOUDBOX_SUBSTRATE_DEFAULT=.*/CLOUDBOX_SUBSTRATE_DEFAULT="docker"/' scripts/versions.env
rm -f ~/.cloudbox/substrate
bash -c 'source scripts/lib.sh; echo "resolve=$(substrate_resolve)"'   # expect resolve=docker, even with tbx healthy
bash -c 'source scripts/lib.sh; CLOUDBOX_SUBSTRATE=tbx; echo "override=$(substrate_resolve)"'  # expect override=tbx
mv scripts/versions.env.bak scripts/versions.env
```
- [ ] **Step 9: Final full check.** `./scripts/check-consistency.sh && ./scripts/check-vendor-drift.sh --offline && bash -n $(find . -path ./slides -prune -o -name '*.sh' -print) && shellcheck -x --source-path=scripts scripts/*.sh scripts/substrate/*.sh` → all exit 0. Then trigger `gh workflow run bootstrap-test.yaml` and confirm green.
- [ ] **Step 10: Commit.**
```
docs(rehearsals): rehearsal 5 — both substrates, and the go-live gate decision

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

## Appendix A — spec coverage

| Spec section | Tasks |
|---|---|
| §1 Substrate layer — dispatcher, `substrate/{docker,tbx}.sh`, `lib.sh` helpers | 1, 2, 5 |
| §1 Resolution, `~/.cloudbox/substrate`, `--check` prints the substrate + failing doctor line | 1, 2, 12 |
| §1 Contract both backends satisfy (context, 2 nodes, cni:none, mirrors, Cilium, exports) | 2, 5, 6, 16 |
| §1 tbx backend: substrate-only yaml, gen config, apply, bootstrap, merged mirrors, destroy | 4, 5 |
| §1 Docker backend: unchanged + `80:30880` publish | 2, 6 |
| §1 Windows/WSL2, Codespaces, CI = docker | 17 |
| §1 `context-guard.sh` accepts `172.30.x.x:6443` | 3 |
| §2 Cilium values (ingressController shared, l2announcements, LB vs NodePort 30880) | 6 |
| §2 tbx-only `CiliumLoadBalancerIPPool` .200-.239 + `CiliumL2AnnouncementPolicy` | 7 |
| §2 docker `/etc/hosts` marked block, sudo, `--print-hosts`, `--check` verifies, purge removes | 12 |
| §2 Hostname table, `CLOUDBOX_DOMAIN`, per-service `*_HOST_URL` | 8 |
| §2 Ten `ingress.yaml` files, `ingressClassName: cilium`, existing sync waves | 9, 10 |
| §2 Backstage baseUrl/CORS, portal presigned host, Knative `config-domain` | 11 |
| §2 URL sweep + `check-consistency.sh` `localhost:3` guard | 13 |
| §2 Knative on docker: fixed names in the hosts block, verifier accepts either | 12, 16 |
| §3 `cloudbox-init.sh` `tbx cache pull` + `tbx doctor` + summary line | 14 |
| §3 `install.sh --check` asserts the raw image in `~/.talosbox/cache` | 14 |
| §3 `images.txt` gains Cilium ingress/envoy images *if absent* (verify, don't assume) | 14 |
| §3 Kagent Ollama endpoint templated from `CLOUDBOX_HOST_GATEWAY` | 15 |
| §4 Sizing: `TBX_CP_MEMORY`/`TBX_WORKER_MEMORY` pins, yaml generated from them | 4, 19 |
| §5 verify/solve stay substrate-blind; lab 00/01 branch on the persisted substrate | 16 |
| §5 CI on docker, gains the hosts block and the ingress path | 17 |
| §5 `check-consistency.sh` new checks (`localhost:3xxxx`, tbx pin) | 4, 13 |
| §5 Go-live gate by Aug 31, one line in the dispatcher default | 19 |
| §5 `docs/HAZARDS.md` five entries | 18 |
| §6.8 README/PLAN/`talos-box-vs-docker.md` decision note, MAINTENANCE | 18 |
| §6.9 Rehearsals (tbx then docker) and the gate decision | 19 |

## Appendix B — ambiguities resolved, with the evidence

1. **`tbx down cloudbox --delete` does not exist.** `tbx down` stops clusters (`cmd/tbx/updown.go:371-384`, action wording `stopped %s`) and its only flag is `-f` (`:429-430`). **Resolution:** destroy is `tbx cluster destroy "${CLUSTER_NAME}" --force` (`cmd/tbx/main.go:461-469`). Task 5.
2. **`tbx up cloudbox` takes no cluster name.** `tbx up` is file-driven (`cmd/tbx/updown.go:412-425`). **Resolution:** `tbx up -f "${TBX_CLUSTER_FILE}"`, with the file rendered from `versions.env`. Tasks 4, 5.
3. **What "merge `tbx manifests cloudbox mirrors`" means when the crane mirror is the single store.** That section renders only Talos's catch-all `"*"` pointing at tbx's own pull-through mirror with `skipFallback: true` (`internal/manifests/manifests.go:218-230`; `inspection.go:96`). **Resolution:** apply both patches. Our eight explicit registry entries → the crane mirror at `http://${CLOUDBOX_HOST_GATEWAY}:5001` (explicit entries win over `"*"` in containerd), tbx's `"*"` catches only what our list does not name. The spec's non-goal ("the crane mirror stays the single store") and its §1 instruction are both honoured. Task 5.
4. **`tbx manifests <c> balloon` is deprecated and errors** (`internal/provision/inspection.go:99-100`); `machine` would drag in Longhorn's kubelet mount we do not use. **Resolution:** the two-line `virtio_balloon` patch is written by us, copied from `internal/manifests/manifests.go:271-278`. Task 5.
5. **The spec says `destroy-cluster.sh --purge`; the repo's flag is `--purge-mirror`.** **Resolution:** keep `--purge-mirror` and hang the hosts-block removal on it. Renaming a documented recovery flag eight days before delivery is the worse trade. Task 12.
6. **"Ten ingress.yaml files" vs. Gitea and ArgoCD having no ArgoCD Application.** Both are installed imperatively by `bootstrap-gitops.sh` and have no `gitops/components/` directory. **Resolution:** nine files (rustfs carries two hosts, so ten hostnames), with `gitops/components/{gitea,argocd}/ingress.yaml` created as new directories and applied directly by `bootstrap-gitops.sh`. Tasks 9, 10.
7. **`localhost:30500` must survive the sweep.** Node-side image pulls (`fnPullHost`, `hello-site.yaml`, Knative's `registries-skipping-tag-resolving`) address Zot through the node's own NodePort, which answers on every node on **both** substrates and which a tbx VM cannot replace with `zot.cloudbox.k8s.test`. **Resolution:** allowlisted in check 11 alongside `scripts/substrate/docker.sh` and Slidev's `localhost:3030`. Task 13.
8. **`*.kn.<domain>` matches one label, ksvc hosts have two** (`hello.demo.kn.…`). **Resolution:** Task 9 Step 10 tests it live and falls back to two explicit per-namespace wildcard rules (`*.demo.kn.` and `*.pipeline.kn.`) if the single wildcard 404s. This is the one assumption the manifests cannot settle on paper.
9. **ArgoCD `selfHeal` would revert the Kagent Ollama patch.** **Resolution:** `ignoreDifferences` on `/spec/ollama/host` plus `RespectIgnoreDifferences=true` on the kagent Application, and the machine fact recorded in a ConfigMap the lab reads. Task 15.
10. **Gitea's `ROOT_URL` was not moved to the hostname.** ArgoCD polls `GITEA_CLUSTER_URL`; repointing `ROOT_URL` at a host name would make the platform's own write path depend on host DNS. **Resolution:** `ROOT_URL` and `DOMAIN` stay in-cluster; only the browser/clone URL moves. Task 10.
11. **Presigned S3 URLs cannot become HTTPS.** `apps/portal/internal/store/s3.go` builds both minio clients with `Secure: false` and trims the scheme. **Resolution:** `RUSTFS_S3_HOST` is a bare host and the ingress stays plain HTTP; noted in the manifest comment so a future TLS change knows what it breaks. Tasks 8, 11.
12. **`mise` may not be able to install `tbx`.** No published apt/dnf/AUR/Nix channel yet (upstream README, issues #95/#96/#101). **Resolution:** Task 4 Step 3 tests `ubi:randax/talos-box` and, if it cannot resolve, falls back to a commented pin that check 10 reads either way — so `TBX_VERSION` is never the only copy.
13. **tbx clusters enforce PodSecurity `baseline` cluster-wide.** This is Talos's own default admission config, so it applies equally to the docker substrate today and is **not** a substrate difference. No task; flagged here so it is not "discovered" mid-rehearsal.
