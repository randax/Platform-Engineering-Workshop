#!/usr/bin/env bash
# =============================================================================
# dev-setup.sh — install the workshop tools (step 1 of the at-home setup)
#
# What it does:
#   1. Ensures mise (https://mise.jdx.dev) is installed — asks before installing
#   2. Runs `mise install` to install the pinned tools from mise.toml
#      (talosctl, kubectl, helm, kind, crane, node)
#   3. Verifies every tool and prints its version
#
# Usage:
#   ./scripts/dev-setup.sh
#
# Works on macOS, Linux and WSL2. Docker is checked later by
# `./scripts/install.sh --check` — this script is only about CLI tools.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

step "CloudBox tool setup"

# --- 1. Ensure mise ----------------------------------------------------------
if have mise; then
  ok "mise $(mise version 2>/dev/null | head -n1)"
else
  warn "mise is not installed. It manages the pinned CLI tools for this workshop."
  echo "   Installer: curl https://mise.run | sh   (installs to ~/.local/bin)"
  if confirm "Install mise now?"; then
    curl -fsSL https://mise.run | MISE_VERSION="${MISE_VERSION}" sh
    export PATH="${HOME}/.local/bin:${PATH}"
    have mise || die "mise installed but not on PATH — open a new shell and re-run this script."
    ok "mise installed"
    info "Add mise to your shell so tools are always on PATH, e.g. for bash:"
    # shellcheck disable=SC2016  # deliberately printing an unexpanded snippet
    echo '     echo '\''eval "$(~/.local/bin/mise activate bash)"'\'' >> ~/.bashrc'
    echo "   (see https://mise.jdx.dev/getting-started.html for zsh/fish)"
  else
    die "Cannot continue without mise. Install it and re-run."
  fi
fi

# --- 2. Install pinned tools --------------------------------------------------
step "Installing pinned tools from mise.toml (this can take a few minutes)"
(cd "${REPO_ROOT}" && mise install)

# --- 3. Verify ------------------------------------------------------------------
step "Verifying tools"

# Run tools via `mise exec` so verification works even before the attendee has
# added mise activation to their shell profile.
mise_exec() { (cd "${REPO_ROOT}" && mise exec -- "$@"); }

failures=0
verify_tool() {
  local name="$1"; shift
  local version
  # squash multi-line version output (talosctl/kubectl) onto one short line
  if version="$(mise_exec "$@" 2>/dev/null | tr -s '\n\t' '  ' | cut -c1-100)" \
     && [[ -n "${version// /}" ]]; then
    ok "${name}: ${version}"
  else
    fail "${name}: not working"
    failures=$((failures + 1))
  fi
}

verify_tool "talosctl" talosctl version --client --short
verify_tool "kubectl"  kubectl version --client
verify_tool "helm"     helm version --short
verify_tool "kind"     kind version
verify_tool "crane"    crane version
verify_tool "node"     node --version

echo
if [[ ${failures} -gt 0 ]]; then
  die "${failures} tool(s) failed to verify. Try 'mise doctor' or re-run this script."
fi

ok "All tools installed and verified."
info "Next steps (still at home, on good internet):"
echo "   1. ./scripts/cloudbox-init.sh      # pre-pull all workshop images (~15-20 GB)"
echo "   2. ./scripts/install.sh --check    # full pre-flight check"
