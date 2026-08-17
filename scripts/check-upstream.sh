#!/usr/bin/env bash
# =============================================================================
# check-upstream.sh — MAINTAINER TOOL. NEEDS INTERNET. Never part of the
# attendee flow (everything attendees run must work offline, principle 2).
#
# check-consistency.sh answers "do our files agree with each other?".
# This script answers the other half: "has any pin fallen BEHIND upstream?" —
# the job that is otherwise done by hand ("verified 2026-07-13, re-verify late
# August") once per rehearsal.
#
# For every row in scripts/upstream.list it:
#   1. resolves the CURRENTLY pinned version from wherever it really lives
#      (versions.env, mise.toml, images.txt, a rendered chart label, a file)
#      — this script never stores a version number of its own;
#   2. resolves the latest upstream version (GitHub releases/tags, a Helm
#      repo index, or registry tags via crane);
#   3. prints  name / pinned / latest / status  where status is
#      ok · pre · patch · minor · major · error · SKIP.
#
# Exit codes:
#   0  everything resolved (pins may be behind — that is a report, not a fail)
#   1  a row errored (network, rate limit, moved repo, dead pin-source), or
#      --strict was given and at least one pin is behind
#
# Usage:
#   ./scripts/check-upstream.sh [--strict] [--json] [--only <name>[,<name>…]]
#   ./scripts/check-upstream.sh --help
#
# Bumping is a deliberate, separate decision: this script never edits a pin.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"

LIST_FILE="${SCRIPT_DIR}/upstream.list"
GH_API="https://api.github.com"
MAX_PAGES=3            # /releases and /tags listings: pages of 100
STRICT=0
JSON=0
PINS_ONLY=0
ONLY=""                # " name1 name2 " when filtering

ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1"; }
bad()  { printf '❌ %s\n' "$1"; }

usage() {
  cat <<'EOF'
check-upstream.sh — MAINTAINER TOOL. NEEDS INTERNET. Never part of the attendee
flow (everything attendees run must work offline, principle 2).

check-consistency.sh asks "do our files agree with each other?"; this script
asks "has any pin fallen BEHIND upstream?" — the job otherwise done by hand
once per rehearsal. It reads scripts/upstream.list, resolves each pin from
wherever it really lives (versions.env, mise.toml, images.txt, a rendered chart
label) and compares it with the latest upstream version.

Usage:
  ./scripts/check-upstream.sh [--strict] [--json] [--only <name>[,<name>…]]

Status column:  ok · pre · patch · minor · major · error · SKIP

Exit codes:
  0  everything resolved — pins that are behind are a REPORT, not a failure
  1  a row errored (network, rate limit, moved repo, dead pin-source), or
     --strict was given and at least one pin is behind

Flags:
  --strict            exit 1 when any pin is behind upstream
                      (default: only hard errors fail the run)
  --json              machine-readable array on stdout instead of the table
  --only <name>       check a subset; repeatable and/or comma-separated
  --pins-only         resolve the PINNED versions only and print
                      "<name><TAB><pinned>" — offline, no network. Used by
                      check-consistency.sh to catch a rotted upstream.list.
  --help              this text

Environment:
  GITHUB_TOKEN / GH_TOKEN   optional; raises the GitHub API rate limit. Falls
                            back to `gh auth token` when the gh CLI is logged
                            in, so a local run normally needs no setup
                            (unauthenticated is 60 requests/hour and this
                            script makes roughly 30).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)    STRICT=1 ;;
    --json)      JSON=1 ;;
    --pins-only) PINS_ONLY=1 ;;
    --only)
      [[ $# -ge 2 ]] || { bad "--only needs a value"; exit 1; }
      ONLY="${ONLY} ${2//,/ }"; shift ;;
    --only=*)    ONLY="${ONLY} ${1#--only=}"; ONLY="${ONLY//,/ }" ;;
    -h|--help)   usage; exit 0 ;;
    *) bad "unknown flag: $1 (try --help)"; exit 1 ;;
  esac
  shift
done
[[ -n "${ONLY}" ]] && ONLY=" ${ONLY} "

GH_AUTH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
# Unauthenticated is 60 requests/hour and one full run costs ~30, so running
# this twice in an afternoon rate-limits every row. Borrow the gh CLI's token
# when there is one — no setup, and CI passes GITHUB_TOKEN explicitly anyway.
if [[ -z "${GH_AUTH_TOKEN}" ]] && command -v gh >/dev/null 2>&1; then
  GH_AUTH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi

# --- small helpers -------------------------------------------------------------
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# crane is only needed for registry-tag rows; mise users may not have the shim
# on PATH, so ask mise before giving up.
CRANE=""
if have crane; then
  CRANE="crane"
elif have mise && mise which crane >/dev/null 2>&1; then
  CRANE="$(mise which crane)"
fi

have curl || { bad "curl is required"; exit 1; }
have jq   || { bad "jq is required (mise install)"; exit 1; }

# =============================================================================
# Semver: tolerant parse + compare
#
#   v1.13.6 · jq-1.8.2 · knative-v1.22.1 · 1.0.0-beta.8 · 2.12.12-alpine
#
# A suffix is a PRERELEASE only when it starts with a known prerelease word
# (alpha/beta/rc/pre/preview/dev/next/snapshot/nightly); anything else
# (-rootless, -alpine, -victorialogs, -system-trixie) is a build FLAVOR and is
# ignored for comparison. Prereleases sort below their release.
# =============================================================================

# A version may carry a name prefix ("jq-1.8.2", "knative-v1.22.1") and/or a
# leading v — but the digits must start right after it, so registry junk like
# "latest-ubuntu22.04" or "main-rockylinux9.3" is rejected instead of being
# read as version 22.04.
SEMVER_RE='^([A-Za-z][A-Za-z0-9_.-]*[-/])?[vV]?([0-9].*)$'

# semver_parse <raw> — echo "<major> <minor> <patch> [prerelease]", or fail.
semver_parse() {
  local raw="$1" core suffix pre lc maj min pat
  raw="${raw%%+*}"                       # drop build metadata
  [[ "${raw}" =~ ${SEMVER_RE} ]] || return 1
  raw="${BASH_REMATCH[2]}"
  core="${raw%%-*}"
  suffix=""
  [[ "${core}" != "${raw}" ]] && suffix="${raw#*-}"
  case "${core}" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  IFS='.' read -r maj min pat _ <<<"${core}"
  [[ -n "${maj}" ]] || return 1
  min="${min:-0}"; pat="${pat:-0}"
  pre=""
  if [[ -n "${suffix}" ]]; then
    lc="$(printf '%s' "${suffix}" | tr '[:upper:]' '[:lower:]')"
    case "${lc}" in
      alpha|alpha[.0-9-]*|beta|beta[.0-9-]*|rc|rc[.0-9-]*|pre|pre[.0-9-]*) pre="${lc}" ;;
      preview|preview[.0-9-]*|dev|dev[.0-9-]*|next|next[.0-9-]*)           pre="${lc}" ;;
      snapshot*|nightly*)                                                  pre="${lc}" ;;
      # Milestone/early-access spellings. Nothing here uses one today, but an
      # unrecognised prerelease word is read as release-grade and under-reports.
      m[0-9]*|milestone*|devel*|eap*|ea|ea[.0-9-]*|cr[0-9]*)              pre="${lc}" ;;
    esac
    # a flavor may still trail the prerelease ("1.0.0-rc.1-glibc") — drop it,
    # otherwise the flavored tag sorts ABOVE the plain one
    pre="${pre%%-*}"
  fi
  printf '%s %s %s %s' "${maj}" "${min}" "${pat}" "${pre}"
}

# pre_cmp <a> <b> — echo -1/0/1. Empty (a real release) outranks any prerelease.
pre_cmp() {
  local a="$1" b="$2" i n x y
  [[ "${a}" == "${b}" ]] && { echo 0; return; }
  [[ -z "${a}" ]] && { echo 1; return; }
  [[ -z "${b}" ]] && { echo -1; return; }
  local A B oldifs="${IFS}"
  IFS='.'
  # shellcheck disable=SC2206  # deliberate word split on '.' (bash 3.2: no readarray)
  A=(${a})
  # shellcheck disable=SC2206
  B=(${b})
  IFS="${oldifs}"
  n=${#A[@]}; [[ ${#B[@]} -gt ${n} ]] && n=${#B[@]}
  for ((i = 0; i < n; i++)); do
    x="${A[i]:-}"; y="${B[i]:-}"
    [[ -z "${x}" ]] && { echo -1; return; }
    [[ -z "${y}" ]] && { echo 1; return; }
    [[ "${x}" == "${y}" ]] && continue
    if [[ "${x}" =~ ^[0-9]+$ && "${y}" =~ ^[0-9]+$ ]]; then
      [[ "${x}" -gt "${y}" ]] && { echo 1; return; }
      echo -1; return
    fi
    [[ "${x}" > "${y}" ]] && { echo 1; return; }
    echo -1; return
  done
  echo 0
}

# semver_cmp <a> <b> — echo -1/0/1; returns 1 when either side does not parse.
semver_cmp() {
  local pa pb am an ap apre bm bn bp bpre
  pa="$(semver_parse "$1")" || return 1
  pb="$(semver_parse "$2")" || return 1
  read -r am an ap apre <<<"${pa}"
  read -r bm bn bp bpre <<<"${pb}"
  apre="${apre:-}"; bpre="${bpre:-}"
  local i
  for i in "${am}:${bm}" "${an}:${bn}" "${ap}:${bp}"; do
    [[ "${i%%:*}" -gt "${i##*:}" ]] && { echo 1; return 0; }
    [[ "${i%%:*}" -lt "${i##*:}" ]] && { echo -1; return 0; }
  done
  pre_cmp "${apre}" "${bpre}"
}

# version_status <pinned> <latest> — echo ok|pre|patch|minor|major.
version_status() {
  local cmp pa pb pm pn pp _x lm ln lp
  cmp="$(semver_cmp "$2" "$1")" || return 1   # is latest newer than pinned?
  [[ "${cmp}" == "1" ]] || { echo ok; return 0; }
  pa="$(semver_parse "$1")"; pb="$(semver_parse "$2")"
  read -r pm pn pp _x <<<"${pa}"
  read -r lm ln lp _x <<<"${pb}"
  [[ "${lm}" -gt "${pm}" ]] && { echo major; return 0; }
  [[ "${ln}" -gt "${pn}" ]] && { echo minor; return 0; }
  [[ "${lp}" -gt "${pp}" ]] && { echo patch; return 0; }
  # Same core, only the prerelease moved (1.0.0-beta.8 → 1.0.0-rc.1). Calling
  # that "patch" would undersell it — a beta→rc step can change everything.
  echo pre
}

# =============================================================================
# Resolving the CURRENT pin — one reader per pin-source kind, so no version
# number is ever duplicated into this tooling.
# =============================================================================

# Locator strings here (tool keys, chart names) are plain identifiers — no
# regex metacharacters and no "|" — so they interpolate into sed safely.
mise_pin() {
  sed -nE "s|^\"?$1\"?[[:space:]]*=[[:space:]]*\"([^\"]+)\".*|\1|p" mise.toml | head -1
}

# image_pin <repo> — the tag pinned for <repo> in images.txt, digest stripped.
image_pin() {
  local repo="$1" line ref tag
  while IFS= read -r line; do
    case "${line}" in ''|'#'*|'['*) continue ;; esac
    line="$(trim "${line}")"
    ref="${line%%@*}"
    case "${ref}" in *:*) ;; *) continue ;; esac   # digest-only ref, no tag
    tag="${ref##*:}"
    [[ "${ref%:*}" == "${repo}" ]] || continue
    printf '%s' "${tag}"
    return 0
  done < "${SCRIPT_DIR}/images.txt"
  return 1
}

# chart_pin <path> <chart-name> — from a `helm.sh/chart: <name>-<version>` label.
chart_pin() {
  [[ -f "$1" ]] || return 1
  sed -nE "s|.*helm\.sh/chart:[[:space:]]*\"?$2-(v?[0-9][^\"[:space:]]*)\"?.*|\1|p" "$1" | head -1
}

# file_pin <path> <extended-regex-with-one-capture-group>
file_pin() {
  [[ -f "$1" ]] || return 1
  sed -nE "s|.*$2.*|\1|p" "$1" | head -1
}

# resolve_pin <pin-source> — echo the raw pinned string, or fail.
resolve_pin() {
  local src="$1" kind arg
  kind="${src%%:*}"
  arg="${src#*:}"
  case "${kind}" in
    env)   [[ -n "${!arg:-}" ]] || return 1; printf '%s' "${!arg}" ;;
    mise)  mise_pin "${arg}" ;;
    image) image_pin "${arg}" ;;
    chart) chart_pin "${arg%%#*}" "${arg##*#}" ;;
    file)  file_pin "${arg%%#*}" "${arg#*#}" ;;
    *)     return 1 ;;
  esac
}

# =============================================================================
# Resolving the LATEST upstream version
# =============================================================================
# The lookups run inside command substitutions (subshells), so the reason a row
# failed has to travel back through a file, not a variable.
ERR_FILE="$(mktemp)"
FETCH_ERR=""
set_err() { printf '%s' "$1" >"${ERR_FILE}"; }

# gh_get <api-path> — body on stdout; sets FETCH_ERR and fails on anything else.
gh_get() {
  local path="$1" tmp code
  tmp="$(mktemp)"
  local -a args
  args=(-sS -L --max-time 30 -H 'Accept: application/vnd.github+json')
  if [[ -n "${GH_AUTH_TOKEN}" ]]; then
    args+=(-H "Authorization: Bearer ${GH_AUTH_TOKEN}")
  fi
  code="$(curl "${args[@]}" -o "${tmp}" -w '%{http_code}' "${GH_API}/${path}" 2>/dev/null || echo 000)"
  case "${code}" in
    200) cat "${tmp}"; rm -f "${tmp}"; return 0 ;;
    403|429)
      if grep -qi 'rate limit' "${tmp}" 2>/dev/null; then
        set_err "GitHub rate limit — set GITHUB_TOKEN to raise it"
      else
        set_err "HTTP ${code} from ${path}"
      fi ;;
    404) set_err "HTTP 404 for ${path} — repo renamed or no releases?" ;;
    000) set_err "network error contacting ${GH_API}" ;;
    *)   set_err "HTTP ${code} from ${path}" ;;
  esac
  rm -f "${tmp}"
  return 1
}

# best_of <track> — read candidate versions on stdin, echo the highest one that
# parses as semver and matches <track> (matched with a leading v stripped).
best_of() {
  local track="$1" cand best="" bare cmp
  while IFS= read -r cand || [[ -n "${cand}" ]]; do   # last line may lack \n
    cand="$(trim "${cand}")"
    [[ -n "${cand}" ]] || continue
    bare="${cand#[vV]}"
    if [[ -n "${track}" && "${track}" != "*" ]]; then
      printf '%s' "${bare}" | grep -qE "${track}" || continue
    fi
    semver_parse "${cand}" >/dev/null 2>&1 || continue
    if [[ -z "${best}" ]]; then best="${cand}"; continue; fi
    cmp="$(semver_cmp "${cand}" "${best}" 2>/dev/null || echo 0)"
    if [[ "${cmp}" == "1" ]]; then
      best="${cand}"
    elif [[ "${cmp}" == "0" && "${#cand}" -lt "${#best}" ]]; then
      best="${cand}"   # same version, plainer tag (1.0.0-rc.1 over …-rc.1-glibc)
    fi
  done
  [[ -n "${best}" ]] || return 1
  printf '%s' "${best}"
}

# gh_list <repo> <releases|tags> <track> — paginated listing, highest match.
gh_list() {
  local repo="$1" what="$2" track="$3" page body names all=""
  for ((page = 1; page <= MAX_PAGES; page++)); do
    body="$(gh_get "repos/${repo}/${what}?per_page=100&page=${page}")" || return 1
    if [[ "${what}" == "releases" ]]; then
      names="$(printf '%s' "${body}" | jq -r '.[].tag_name // empty')"
    else
      names="$(printf '%s' "${body}" | jq -r '.[].name // empty')"
    fi
    [[ -n "${names}" ]] || break
    all="${all}${names}"$'\n'
    # stop as soon as this page yielded a usable candidate — keeps the run
    # inside the unauthenticated rate limit for the common case
    printf '%s' "${all}" | best_of "${track}" >/dev/null 2>&1 && break
  done
  printf '%s' "${all}" | best_of "${track}" || {
    set_err "no ${what} matching track '${track:-*}' in the first ${MAX_PAGES} page(s)"
    return 1
  }
}

# helm_latest <repo-url>#<chart> <track>
helm_latest() {
  local locator="$1" track="$2" url chart body
  url="${locator%%#*}"; chart="${locator##*#}"
  url="${url%/}/index.yaml"
  body="$(curl -sS -L --max-time 30 "${url}" 2>/dev/null)" || {
    set_err "could not fetch ${url}"; return 1; }
  [[ -n "${body}" ]] || { set_err "empty index at ${url}"; return 1; }
  # Only the entry's own `version:` (4-space indent) — `dependencies:` further
  # in carries subchart versions at 6 spaces and would win every comparison.
  printf '%s' "${body}" \
    | awk -v want="${chart}:" '
        /^entries:/ { inentries = 1; next }
        inentries && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { inchart = ($1 == want) }
        inchart && /^    version:[[:space:]]/ { print $2 }' \
    | tr -d '"' \
    | best_of "${track}" || {
        set_err "chart '${chart}' not found in ${url} (or no version matched track)"
        return 1
      }
}

# registry_latest <image-repo> <track>
registry_latest() {
  local repo="$1" track="$2" tags
  tags="$("${CRANE}" ls "${repo}" 2>/dev/null)" || {
    set_err "crane ls ${repo} failed"; return 1; }
  printf '%s' "${tags}" | best_of "${track}" || {
    set_err "no semver tag matching track '${track:-*}' on ${repo}"; return 1; }
}

# fetch_latest <kind> <locator> <track>
fetch_latest() {
  local kind="$1" locator="$2" track="$3" body tag
  set_err ""
  case "${kind}" in
    github-release)
      if [[ -n "${track}" && "${track}" != "*" ]]; then
        gh_list "${locator}" releases "${track}"
        return
      fi
      body="$(gh_get "repos/${locator}/releases/latest")" || return 1
      tag="$(printf '%s' "${body}" | jq -r '.tag_name // empty')"
      [[ -n "${tag}" ]] || { set_err "no tag_name in latest release of ${locator}"; return 1; }
      printf '%s' "${tag}" ;;
    github-tag)   gh_list "${locator}" tags "${track}" ;;
    helm-index)   helm_latest "${locator}" "${track}" ;;
    registry-tag) registry_latest "${locator}" "${track}" ;;
    *) set_err "unknown latest-kind '${kind}'"; return 1 ;;
  esac
}

# =============================================================================
# Main
# =============================================================================
[[ -f "${LIST_FILE}" ]] || { bad "${LIST_FILE} not found"; exit 1; }

ROWS=()
while IFS= read -r line || [[ -n "${line}" ]]; do
  case "$(trim "${line}")" in ''|'#'*) continue ;; esac
  ROWS+=("${line}")
done < "${LIST_FILE}"

RESULTS_FILE="$(mktemp)"
trap 'rm -f "${RESULTS_FILE}" "${ERR_FILE}"' EXIT

ERRORS=0
BEHIND=0
SKIPPED=0

for row in "${ROWS[@]}"; do
  IFS='|' read -r r_name r_kind r_loc r_pinsrc r_track <<<"${row}"
  name="$(trim "${r_name}")"
  kind="$(trim "${r_kind}")"
  locator="$(trim "${r_loc}")"
  pinsrc="$(trim "${r_pinsrc}")"
  track="$(trim "${r_track:-}")"
  [[ -n "${ONLY}" && "${ONLY}" != *" ${name} "* ]] && continue

  pin="$(resolve_pin "${pinsrc}" 2>/dev/null || true)"

  if [[ "${PINS_ONLY}" -eq 1 ]]; then
    printf '%s\t%s\n' "${name}" "${pin}"
    [[ -n "${pin}" ]] || ERRORS=$((ERRORS + 1))
    continue
  fi

  if [[ -z "${pin}" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "-" "-" "error" \
      "pin-source '${pinsrc}' resolved to nothing — did the file move?" >>"${RESULTS_FILE}"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [[ "${kind}" == "registry-tag" && -z "${CRANE}" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${pin}" "-" "SKIP" \
      "crane not installed (mise install crane)" >>"${RESULTS_FILE}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  : >"${ERR_FILE}"
  if ! latest="$(fetch_latest "${kind}" "${locator}" "${track}")"; then
    FETCH_ERR="$(cat "${ERR_FILE}")"
    printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${pin}" "-" "error" \
      "${FETCH_ERR:-lookup failed}" >>"${RESULTS_FILE}"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if ! status="$(version_status "${pin}" "${latest}")"; then
    printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${pin}" "${latest}" "error" \
      "cannot compare '${pin}' with '${latest}' as semver" >>"${RESULTS_FILE}"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  [[ "${status}" != "ok" ]] && BEHIND=$((BEHIND + 1))
  printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${pin}" "${latest}" "${status}" "" >>"${RESULTS_FILE}"
done

if [[ "${PINS_ONLY}" -eq 1 ]]; then
  [[ "${ERRORS}" -eq 0 ]] || exit 1
  exit 0
fi

if [[ "${JSON}" -eq 1 ]]; then
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t"))
               | map({name: .[0], pinned: .[1], latest: .[2],
                      status: .[3], error: (.[4] // "")})' "${RESULTS_FILE}"
else
  awk -F'\t' '
    { n[NR] = $1; p[NR] = $2; l[NR] = $3; s[NR] = $4; e[NR] = $5
      if (length($1) > wn) wn = length($1)
      if (length($2) > wp) wp = length($2)
      if (length($3) > wl) wl = length($3) }
    END {
      if (length("NAME")   > wn) wn = length("NAME")
      if (length("PINNED") > wp) wp = length("PINNED")
      if (length("LATEST") > wl) wl = length("LATEST")
      printf "%-*s  %-*s  %-*s  %s\n", wn, "NAME", wp, "PINNED", wl, "LATEST", "STATUS"
      for (i = 1; i <= NR; i++)
        printf "%-*s  %-*s  %-*s  %s\n", wn, n[i], wp, p[i], wl, l[i], s[i]
      print ""
      for (i = 1; i <= NR; i++)
        if (e[i] != "") printf "  %s: %s\n", n[i], e[i]
    }' "${RESULTS_FILE}"

  if [[ "${BEHIND}" -gt 0 ]]; then
    warn "${BEHIND} pin(s) behind upstream — bump deliberately (versions.env + mise.toml + images.txt together, then re-vendor)."
  fi
  [[ "${SKIPPED}" -gt 0 ]] && warn "${SKIPPED} row(s) skipped."
  if [[ ! -s "${RESULTS_FILE}" ]]; then
    warn "no rows checked — does --only name a row in scripts/upstream.list?"
  elif [[ "${ERRORS}" -gt 0 ]]; then
    bad "${ERRORS} row(s) could not be checked (see above)."
  elif [[ "${BEHIND}" -eq 0 && "${SKIPPED}" -eq 0 ]]; then
    ok "every tracked pin is current."
  fi
fi

[[ "${ERRORS}" -gt 0 ]] && exit 1
[[ "${STRICT}" -eq 1 && "${BEHIND}" -gt 0 ]] && exit 1
exit 0
