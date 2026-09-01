#!/usr/bin/env bash
# =============================================================================
# collect-debug.sh — turn "it doesn't work" into a report someone can act on.
#
#   ./scripts/collect-debug.sh          # bundle everything we'd ask for anyway
#   ./scripts/collect-debug.sh 3        # ...plus module 3's verify.sh output
#
# Writes a single redacted markdown file and prints where it is, plus the two
# ways to file it: the prefilled issue form, or `gh issue create --body-file`.
# Read-only: it runs nothing that changes the cluster, and never prints the
# contents of a Kubernetes Secret.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

GITHUB_REPO="randax/Platform-Engineering-Workshop"
ISSUE_FORM="https://github.com/${GITHUB_REPO}/issues/new?template=workshop-help.yml"
MAX_LINES=60   # per command — a bundle nobody scrolls to the end of helps nobody

MODULE="${1:-}"
if [[ "${MODULE}" == "-h" || "${MODULE}" == "--help" ]]; then
  sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

OUT="${HOME}/.cloudbox/debug-$(date +%Y%m%d-%H%M%S).md"
mkdir -p "$(dirname "${OUT}")"

# --- Redaction ---------------------------------------------------------------
# Two jobs: don't leak this laptop's owner (the home directory carries a name),
# and don't leak anything that looks like a credential. Secrets are also simply
# never asked for below — this is the second line, not the first.
# -E (extended regex) is not optional: BSD sed, which is what every macOS
# attendee has, does not take \| alternation in a basic regex — it silently
# matched nothing, so the credential rule quietly did no redacting at all. -E
# plus the case-insensitive `I` flag behaves the same on BSD and GNU sed.
# An Authorization/Bearer line loses everything after the key — the value is two
# words ("Bearer eyJ..."), so a single-word rule would leave the token behind.
redact() {
  # The hostname goes too: "Hanss-MacBook-Pro" names a person as surely as the
  # home directory does, and nothing in a bundle needs it.
  local host; host="$(hostname -s 2>/dev/null || true)"
  sed -E -e "s|${HOME}|~|g" \
      -e "s|${host:-__no_hostname__}|<hostname>|gI" \
      -e 's/(authorization|bearer)([":= ]+).*/\1\2<redacted>/I' \
      -e 's/(token|password|passwd|secret|apikey|api_key)([":= ]+)[^ ,"}]*/\1\2<redacted>/gI' \
      -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/<redacted private key>/'
}

# section <title> -- <command...>: run it, cap it, redact it. A command that is
# missing or fails is itself a finding, so its error text goes in the bundle.
section() {
  local title="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  {
    echo
    echo "### ${title}"
    echo '```'
    bounded 30 "$@" 2>&1 | head -n "${MAX_LINES}" | redact || echo "(exited $? — that may be the whole problem)"
    echo '```'
  } >>"${OUT}"
}

note() { printf '%s\n' "$*" >>"${OUT}"; }

tool_versions() {
  # Not one flag: talosctl/kubectl/helm/cilium reject --version outright.
  local spec tool
  for spec in "mise:--version" "docker:--version" "talosctl:version --client" \
              "tbx:--version" "kubectl:version --client" "helm:version --short" \
              "cilium:version --client" "kind:--version" "jq:--version"; do
    tool="${spec%%:*}"
    if have "${tool}"; then
      # shellcheck disable=SC2086 # the flags are ours, and must word-split
      printf '%-10s %s\n' "${tool}" "$("${tool}" ${spec#*:} 2>&1 | tr '\n' ' ' | head -c 120)"
    else
      printf '%-10s MISSING\n' "${tool}"
    fi
  done
}

# The workshop-context guard, run NON-fatally — deliberately, and the only
# script that does. Everything else in scripts/ refuses outright when kubectl
# points somewhere else; here a wrong context is often the very thing being
# reported, and a bundle that stops at "refusing" helps nobody. So the guard
# still decides whether we ask a cluster anything (a bundle must never carry an
# employer cluster's namespaces into a public issue) — it just puts its refusal
# in the file instead of ending the collection. See check-consistency.sh check 8.
guard_says() { ( require_workshop_context ) 2>&1 || true; }
workshop_context_ok() { ( require_workshop_context ) >/dev/null 2>&1; }

unhappy_pods() { # every pod that is neither Running nor Succeeded
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>&1
}

# The same list as namespace+name pairs. NF>=5 drops kubectl's "No resources
# found", which is otherwise read as a pod called "resources" in namespace "No".
unhappy_pod_names() {
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
    --no-headers 2>/dev/null | awk 'NF>=5 {print $1, $2}'
}

warning_events() {
  kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -25
}

pod_logs() { # <namespace> <pod>
  kubectl logs -n "$1" "$2" --all-containers --tail=25 2>&1
}

# --- The bundle --------------------------------------------------------------
step "Collecting debug info"

{
  echo "## CloudBox debug bundle"
  echo
  echo "- Collected: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Repo commit: $(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown) on $(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "- Local changes: $(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s)"
  echo "- Recorded substrate: $(substrate_current 2>/dev/null || echo 'none recorded')"
  echo "- KUBECONFIG: ${KUBECONFIG:-(unset — ~/.kube/config)}"
  echo "- Module: ${MODULE:-not given}"
} | redact >"${OUT}"

section "Platform" -- uname -a
if have sw_vers; then section "macOS" -- sw_vers; fi
[[ -r /etc/os-release ]] && section "OS release" -- cat /etc/os-release

section "Tools" -- tool_versions

if docker_running 2>/dev/null; then
  section "Docker" -- docker info --format '{{.ServerVersion}} | {{.OperatingSystem}} | {{.Architecture}} | {{.NCPU}} CPU | {{.MemTotal}} bytes'
  section "Workshop containers" -- docker ps -a --filter name=cloudbox --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
else
  note $'\n### Docker\n```\nnot running / not reachable\n```'
fi

have tbx && section "tbx doctor" -- tbx doctor
have tbx && section "tbx status" -- tbx status

if ! have kubectl; then
  note $'\n### Cluster\n```\nkubectl not installed — run ./scripts/dev-setup.sh\n```'
elif ! workshop_context_ok; then
  section "Workshop context guard (no cluster data collected)" -- guard_says
else
  section "kubectl context" -- kubectl config current-context
  section "Nodes" -- kubectl get nodes -o wide
  section "Pods (not Running/Succeeded)" -- unhappy_pods
  section "ArgoCD applications" -- kubectl get applications -n argocd
  section "Recent warning events" -- warning_events

  # Logs for the pods that are actually unhappy — the single most useful thing
  # in the bundle, and the thing attendees most often forget to include.
  while read -r ns pod; do
    [[ -n "${pod}" ]] || continue
    section "Logs: ${ns}/${pod}" -- pod_logs "${ns}" "${pod}"
  done < <(unhappy_pod_names | head -5)
fi

if [[ -n "${MODULE}" ]]; then
  verify="$(printf '%s\n' "${REPO_ROOT}"/lab/"$(printf '%02d' "${MODULE}" 2>/dev/null || echo "${MODULE}")"-*/verify.sh | head -1)"
  if [[ -x "${verify}" ]]; then
    section "lab/$(basename "$(dirname "${verify}")")/verify.sh" -- "${verify}"
  else
    note $'\n### verify.sh\n```\nno lab found for module '"${MODULE}"$'\n```'
  fi
fi

section "Preflight (install.sh --check)" -- "${SCRIPT_DIR}/install.sh" --check

# --- What to do with it ------------------------------------------------------
ok "Debug bundle written: ${OUT}"
echo
info "Nothing has been sent anywhere. Look it over, then file it:"
echo
echo "  1. Open the help form:  ${ISSUE_FORM}"
echo "     and paste the file's contents into the 'Debug bundle' field."
if have gh; then
  echo
  echo "  2. Or, with the GitHub CLI you already have:"
  echo "       gh issue create --repo ${GITHUB_REPO} --label workshop-help \\"
  echo "         --title 'Module ${MODULE:-?}: <what went wrong>' --body-file '${OUT}'"
fi
echo
warn "It is redacted for home directory and credential-shaped strings, but it is your"
warn "machine's state — skim it before posting."
