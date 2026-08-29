#!/usr/bin/env bash
# Module 00 — pre-flight verification. Safe to run any number of times.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Published minimums (MIN_DISK_FREE_GB, …) come from the single pin source.
# shellcheck source=../../scripts/versions.env
source "$REPO_ROOT/scripts/versions.env"
FAILED=0

ok()   { echo "✅ $1"; }
fail() { echo "❌ FAIL: $1"; FAILED=$((FAILED + 1)); }

# --- Substrate -------------------------------------------------------------
# Which substrate this laptop will use: real Talos VMs via talos-box (tbx) or
# Talos-in-Docker. This MUST agree with substrate_resolve() (scripts/lib.sh),
# which install.sh --check and create-cluster.sh use — a lab 00 that demanded
# tbx while create-cluster.sh built docker would fail an attendee who is
# perfectly ready.
#
# So it is not decided here at all: scripts/substrate-decide.sh is the ONE
# implementation of that precedence (override → persisted → the
# CLOUDBOX_SUBSTRATE_DEFAULT floor → `tbx doctor` detection), and both this file
# and lib.sh read it. It was inlined before, and the copy drifted exactly as
# copies do — it cased on `uname -m` (wrong in a Rosetta shell, where the VMs
# are still arm64) and applied no platform gate, so it graded a tbx laptop as
# docker. Every function in that file is pure: it prints answers and never
# narrates, so the COUNTING ok()/fail() above survive the source, which is what
# lib.sh itself (non-counting ok/fail, exiting need/die) could not promise.
# shellcheck source=../../scripts/substrate-decide.sh
. "$REPO_ROOT/scripts/substrate-decide.sh"

# tbx_doctor_run is memoised in that file, so the tbx branch below reuses the
# detection's answer instead of paying for a second probe of helper, DNS, routes
# and mirror.
tbx_doctor_ok() { command -v tbx >/dev/null 2>&1 && tbx_doctor_run; }

if ! substrate_decide_into SUBSTRATE; then
  # The one case substrate_decide refuses to answer: a typo in the attendee's
  # own override. lib.sh fails the same way; saying so here beats silently
  # grading the machine as something create-cluster.sh will not build.
  fail "CLOUDBOX_SUBSTRATE='${CLOUDBOX_SUBSTRATE}' is not 'tbx', 'docker' or 'kind' — unset it or fix the spelling; checking as docker meanwhile"
  SUBSTRATE=docker
fi
ok "substrate: $SUBSTRATE"
if [ "$SUBSTRATE" = kind ]; then
  # The lifeboat (scripts/kind-fallback.sh) records itself in
  # ~/.cloudbox/substrate. Everything this checklist asks is a DOCKER question
  # there — the nodes are containers on this daemon, the ports are published on
  # this host, the names come from the same /etc/hosts block — so the branches
  # below take the docker path and nothing asks for tbx. What you lose is
  # module 01's Talos content, and only that.
  ok "kind lifeboat — checked like the docker substrate (module 01 is the one thing it cannot give you)"
fi

# --- Docker daemon ---------------------------------------------------------
# docker and kind only. The tbx path is Docker-free (#206): the nodes are VMs
# and they pull through talos-box's own mirror, which `tbx cache warm` fills —
# so on tbx a sleeping Docker is not a finding at all.
if [ "$SUBSTRATE" = tbx ]; then
  ok "tbx substrate — Docker is not needed (the VMs pull through tbx's own mirror)"
elif docker info >/dev/null 2>&1; then
  ok "Docker daemon is running"
else
  fail "Docker daemon not reachable — start Docker Desktop / the docker service, then re-run"
  # On docker AND on the kind lifeboat the nodes themselves are containers, so
  # there is nothing further to check without a daemon.
  echo "Cannot continue without Docker."
  exit 1
fi

# --- Machine resources -----------------------------------------------------
# The one resource question that cannot be substrate-blind: on docker what
# matters is the slice Docker itself was given, on tbx it is the HOST's memory,
# because the VMs take theirs from the host directly.
if [ "$SUBSTRATE" != tbx ]; then
  # --- Docker memory -------------------------------------------------------
  MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  MEM_GB=$((MEM_BYTES / 1024 / 1024 / 1024))
  if [ "$MEM_GB" -ge "$MIN_DOCKER_MEMORY_GB" ]; then
    ok "Docker can use ${MEM_GB} GB memory (need >= ${MIN_DOCKER_MEMORY_GB})"
  else
    fail "Docker only has ${MEM_GB} GB memory — raise it to >= ${MIN_DOCKER_MEMORY_GB} GB (Docker Desktop: Settings > Resources; WSL2: .wslconfig)"
  fi

  # --- Docker CPUs ---------------------------------------------------------
  CPUS="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  if [ "$CPUS" -ge "$MIN_CPUS" ]; then
    ok "Docker can use ${CPUS} CPUs (need >= ${MIN_CPUS})"
  else
    fail "Docker only has ${CPUS} CPUs — give it at least ${MIN_CPUS}"
  fi
else
  # tbx runs real VMs, so what matters is HOST memory, not Docker's slice. The
  # published floor is 16 GB (upstream talos-box asks for it too, docs/SPEC.md:27).
  if [ "$(uname -s)" = Darwin ]; then
    HOST_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
  else
    HOST_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 / 1024 ))
  fi
  if [ "${HOST_GB:-0}" -ge 16 ]; then
    ok "host memory: ${HOST_GB} GB (need >= 16 for the VM substrate)"
  else
    fail "host memory: ${HOST_GB:-0} GB — the tbx substrate needs >= 16 GB. Use the docker substrate instead: CLOUDBOX_SUBSTRATE=docker"
  fi
  # ...and the host's cores, for the same reason: the worker VM takes them from
  # the host, so Docker's NCPU (checked on the other branch) says nothing here.
  # MIN_CPUS is a published promise; before this it was enforced on the docker
  # substrate only.
  # Inlined for the same reason the substrate precedence above is: this file
  # deliberately does not source lib.sh. Keep it identical to host_cpu_count()
  # there — it is what sizes the worker VM.
  HOST_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || true)"
  case "$HOST_CPUS" in ''|*[!0-9]*) HOST_CPUS="" ;; esac
  if [ -z "$HOST_CPUS" ]; then
    fail "could not read this host's core count — the tbx substrate needs >= ${MIN_CPUS} CPUs"
  elif [ "$HOST_CPUS" -ge "$MIN_CPUS" ]; then
    ok "host CPUs: ${HOST_CPUS} (need >= ${MIN_CPUS} for the VM substrate)"
  else
    fail "host CPUs: ${HOST_CPUS} — the tbx substrate needs >= ${MIN_CPUS}. The node VMs take their cores from the host, so there is nothing to raise: use a bigger machine, or CLOUDBOX_SUBSTRATE=docker"
  fi
  # Memoised: on the detection path doctor has already run, and this reuses that
  # exit code instead of paying for a second probe.
  if tbx_doctor_ok; then
    ok "tbx doctor passes"
  else
    fail "tbx doctor reports problems — run 'tbx doctor' to see them (install with 'brew install randax/tap/tbx' + 'sudo tbx system install'), or use CLOUDBOX_SUBSTRATE=docker"
  fi
fi

# --- Free disk -------------------------------------------------------------
FREE_GB="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print int($4/1024/1024)}')"
if [ "${FREE_GB:-0}" -ge "$MIN_DISK_FREE_GB" ]; then
  ok "${FREE_GB} GB free disk (need >= ${MIN_DISK_FREE_GB})"
else
  fail "Only ${FREE_GB:-0} GB free disk — need >= ${MIN_DISK_FREE_GB} GB (the image cache alone needs ~15 GB)"
fi

# --- Required CLIs ---------------------------------------------------------
# tbx is only required on the substrate that uses it — dev-setup.sh does not
# install it (it needs a privileged one-time `sudo tbx system install`), so
# demanding it on the docker substrate would fail every Windows/WSL2 attendee.
TOOLS="talosctl kubectl helm cilium jq git curl"
if [ "$SUBSTRATE" = tbx ]; then TOOLS="$TOOLS tbx"; fi
# The lifeboat is created and deleted with kind, and only there — mise pins it
# (mise.toml), so it is one `./scripts/dev-setup.sh` away on any machine.
if [ "$SUBSTRATE" = kind ]; then TOOLS="$TOOLS kind"; fi
# Deliberately unquoted: TOOLS is a space-separated word list, not one word.
# shellcheck disable=SC2086
for tool in $TOOLS; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found ($(command -v "$tool"))"
  else
    if [ "$tool" = tbx ]; then
      fail "tbx not found in PATH — 'brew install randax/tap/tbx' (macOS) or the release tarball (Linux), then 'sudo tbx system install'; or use CLOUDBOX_SUBSTRATE=docker"
    else
      fail "$tool not found in PATH — run ./scripts/dev-setup.sh, then restart your shell (mise activation)"
    fi
  fi
done

# --- Repo pre-flight script ------------------------------------------------
if "$REPO_ROOT/scripts/install.sh" --check >/dev/null 2>&1; then
  ok "./scripts/install.sh --check passes"
else
  fail "./scripts/install.sh --check reports problems — run it directly to see them"
fi

# --- Image mirror ----------------------------------------------------------
# On tbx the images live in talos-box's own store, not in a container on
# :5001, and `install.sh --check` above graded them with `tbx cache warm
# --check` — there is no second registry to probe here.
if [ "$SUBSTRATE" = tbx ]; then
  ok "tbx substrate — cluster images are graded by install.sh --check (tbx cache warm --check), no cloudbox-mirror container"
elif curl -4 -fsS --max-time 5 http://localhost:5001/v2/ >/dev/null 2>&1; then
  ok "cloudbox-mirror registry answers on localhost:5001"
  IMAGES="$(curl -4 -fsS --max-time 5 http://localhost:5001/v2/_catalog 2>/dev/null | jq -r '.repositories | length' 2>/dev/null || echo 0)"
  if [ "${IMAGES:-0}" -gt 0 ]; then
    ok "mirror holds ${IMAGES} repositories (pre-pull has run)"
  else
    fail "mirror is empty — run ./scripts/cloudbox-init.sh (needs good WiFi, resumable)"
  fi
else
  fail "no registry on localhost:5001 — run ./scripts/cloudbox-init.sh to start and fill the cloudbox-mirror"
fi

# --- Talos disk image (tbx only) -------------------------------------------
# The VMs boot from a raw disk image, which the container mirror knows nothing
# about — it lives in tbx's own cache, keyed by version directory. Assert the
# FILE, not the directory: an interrupted pull leaves the directory behind
# empty (same reasoning as scripts/install.sh).
if [ "$SUBSTRATE" = tbx ]; then
  if find "${HOME}/.talosbox/cache" -type f -path "*/${TALOS_VERSION}/*disk.raw" -size +0c 2>/dev/null | grep -q .; then
    ok "Talos ${TALOS_VERSION} disk image is cached for tbx"
  else
    fail "no complete Talos ${TALOS_VERSION} disk.raw in ~/.talosbox/cache — run ./scripts/cloudbox-init.sh (needs the Image Factory, so do it at home)"
  fi
fi

# --- Summary ---------------------------------------------------------------
echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed — you are not ready yet. Fix the FAIL lines above (pair up or use the devcontainer lifeboat if the hardware says no)."
  exit 1
fi
echo "✅ All pre-flight checks passed. You are ready for module 01."
