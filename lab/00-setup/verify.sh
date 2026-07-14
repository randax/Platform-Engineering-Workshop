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

# --- Docker daemon ---------------------------------------------------------
if docker info >/dev/null 2>&1; then
  ok "Docker daemon is running"
else
  fail "Docker daemon not reachable — start Docker Desktop / the docker service, then re-run"
  echo "Cannot continue without Docker."
  exit 1
fi

# --- Docker memory ---------------------------------------------------------
MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
MEM_GB=$((MEM_BYTES / 1024 / 1024 / 1024))
if [ "$MEM_GB" -ge 10 ]; then
  ok "Docker can use ${MEM_GB} GB memory (need >= 10)"
else
  fail "Docker only has ${MEM_GB} GB memory — raise it to >= 10 GB (Docker Desktop: Settings > Resources; WSL2: .wslconfig)"
fi

# --- Docker CPUs -----------------------------------------------------------
CPUS="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
if [ "$CPUS" -ge 4 ]; then
  ok "Docker can use ${CPUS} CPUs (need >= 4)"
else
  fail "Docker only has ${CPUS} CPUs — give it at least 4"
fi

# --- Free disk -------------------------------------------------------------
FREE_GB="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print int($4/1024/1024)}')"
if [ "${FREE_GB:-0}" -ge "$MIN_DISK_FREE_GB" ]; then
  ok "${FREE_GB} GB free disk (need >= ${MIN_DISK_FREE_GB})"
else
  fail "Only ${FREE_GB:-0} GB free disk — need >= ${MIN_DISK_FREE_GB} GB (the image cache alone needs ~15 GB)"
fi

# --- Required CLIs ---------------------------------------------------------
for tool in talosctl kubectl helm cilium jq git curl; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found ($(command -v "$tool"))"
  else
    fail "$tool not found in PATH — run ./scripts/dev-setup.sh, then restart your shell (mise activation)"
  fi
done

# --- Repo pre-flight script ------------------------------------------------
if "$REPO_ROOT/scripts/install.sh" --check >/dev/null 2>&1; then
  ok "./scripts/install.sh --check passes"
else
  fail "./scripts/install.sh --check reports problems — run it directly to see them"
fi

# --- Image mirror ----------------------------------------------------------
if curl -fsS --max-time 5 http://localhost:5001/v2/ >/dev/null 2>&1; then
  ok "cloudbox-mirror registry answers on localhost:5001"
  IMAGES="$(curl -fsS --max-time 5 http://localhost:5001/v2/_catalog 2>/dev/null | jq -r '.repositories | length' 2>/dev/null || echo 0)"
  if [ "${IMAGES:-0}" -gt 0 ]; then
    ok "mirror holds ${IMAGES} repositories (pre-pull has run)"
  else
    fail "mirror is empty — run ./scripts/cloudbox-init.sh (needs good WiFi, resumable)"
  fi
else
  fail "no registry on localhost:5001 — run ./scripts/cloudbox-init.sh to start and fill the cloudbox-mirror"
fi

# --- Summary ---------------------------------------------------------------
echo
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED check(s) failed — you are not ready yet. Fix the FAIL lines above (pair up or use the devcontainer lifeboat if the hardware says no)."
  exit 1
fi
echo "✅ All pre-flight checks passed. You are ready for module 01."
