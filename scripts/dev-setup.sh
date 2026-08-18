#!/usr/bin/env bash
# =============================================================================
# dev-setup.sh — install the workshop tools (step 1 of the at-home setup)
#
# What it does:
#   1. Ensures mise (https://mise.jdx.dev) is installed — asks before installing
#   2. Runs `mise install` to install the pinned tools from mise.toml
#      (talosctl, kubectl, helm, kind, crane, cilium, jq, node)
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
  else
    die "Cannot continue without mise. Install it and re-run."
  fi
fi

# --- 1b. Trust this repo's mise.toml -----------------------------------------
# mise refuses to read an UNTRUSTED config at all — `mise install`, `mise run`
# and every shim hard-error with "Config files ... are not trusted". Trust is
# per checkout, so a fresh clone (every attendee, and the devcontainer's
# non-interactive postCreateCommand) starts untrusted and the next step would
# simply fail. Trusting it here is also what makes mise.toml's [env] KUBECONFIG
# pin take effect at all.
(cd "${REPO_ROOT}" && mise trust >/dev/null)
ok "mise.toml trusted for this checkout"

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
verify_tool "cilium"   cilium version --client
verify_tool "jq"       jq --version
verify_tool "node"     node --version

echo
if [[ ${failures} -gt 0 ]]; then
  die "${failures} tool(s) failed to verify. Try 'mise doctor' or re-run this script."
fi

ok "All tools installed and verified."

# --- 4. Hook mise into your shell ---------------------------------------------
# Offered, not merely suggested, and it matters more than "tools on PATH".
#
# mise.toml pins KUBECONFIG to a workshop-only file for this repo. Whether that
# pin reaches you depends entirely on this step, and the two clean outcomes are:
#   * activated   — your shell AND the scripts both use ~/.kube/cloudbox.conf.
#   * not at all  — neither does; everything lands in ~/.kube/config, exactly as
#                   this workshop behaved before the pin. Supported.
# The bad outcome is HALF of it: `mise run cluster:create` (or `mise exec`)
# applies the pin to the script while a bare `kubectl` in the same terminal —
# one you installed yourself, from brew or Docker Desktop — reads
# ~/.kube/config and answers about a different cluster entirely. Since talosctl
# comes from mise and nothing else, "I never activated mise" pushes people
# toward exactly that half-and-half state. Activating closes it.
step "Shell activation (optional, strongly recommended)"

mise_bin="$(command -v mise)"
case "$(basename "${SHELL:-}")" in
  bash) rc="${HOME}/.bashrc";                  snippet="eval \"\$(${mise_bin} activate bash)\"" ;;
  zsh)  rc="${ZDOTDIR:-${HOME}}/.zshrc";       snippet="eval \"\$(${mise_bin} activate zsh)\"" ;;
  fish) rc="${HOME}/.config/fish/config.fish"; snippet="${mise_bin} activate fish | source" ;;
  *)    rc=""; snippet="" ;;
esac

if [[ -z "${rc}" ]]; then
  warn "Unrecognised shell (\$SHELL=${SHELL:-unset}) — hook mise in yourself:"
  echo "   https://mise.jdx.dev/getting-started.html"
elif [[ -f "${rc}" ]] && grep -q 'mise activate' "${rc}"; then
  ok "mise activation is already in ${rc/#${HOME}/\~}"
elif confirm "Add mise activation to ${rc/#${HOME}/\~}?"; then
  mkdir -p "$(dirname "${rc}")"
  printf '\n# mise (CloudBox workshop tools + KUBECONFIG)\n%s\n' "${snippet}" >> "${rc}"
  ok "Added to ${rc/#${HOME}/\~} — open a new terminal (or source it) to pick it up"
else
  warn "Skipped. Then run everything the same way, consistently:"
  echo "     mise exec -- kubectl get nodes     # tools AND kubeconfig from mise"
  echo "   or nothing through mise at all — do not mix the two in one terminal."
  echo "   ./scripts/install.sh --check tells you which side you are on."
fi
info "Next steps (still at home, on good internet):"
echo "   1. ./scripts/cloudbox-init.sh      # pre-pull all workshop images (~7.5 GB)"
echo "   2. ./scripts/install.sh --check    # full pre-flight check"
