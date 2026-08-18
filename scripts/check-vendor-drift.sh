#!/usr/bin/env bash
# =============================================================================
# check-vendor-drift.sh — are the VENDOR.md files still TRUE?
#
# `gitops/components/*/VENDOR.md` is what docs/MAINTENANCE.md tells a
# maintainer to trust at bump time: where the file came from, how to reproduce
# it, and — the load-bearing part — the workshop curation to re-apply
# afterwards. Nothing ever compared those files to reality, so they rotted:
# 11 of 19 were found wrong, every one by accident. This script is the
# comparison.
#
# It runs two guards, deliberately different in strength:
#
#   GUARD 1 — re-render gate (strong, needs network + helm).
#     For every file a VENDOR.md says is reproducible (`fetch` a release asset
#     or `helm template` a pinned chart with documented values), re-produce the
#     PRISTINE upstream artifact and diff it against the vendored copy. Every
#     diff hunk must be accounted for by an `allow` line in that component's
#     machine-readable curation block. An unlisted hunk fails (undocumented
#     curation, or upstream moved); an `allow` line that matches no hunk fails
#     too (the curation it documents was LOST in a re-vendor).
#
#   GUARD 2 — token-coverage lint (weak but broad, offline and fast).
#     For every file NOT covered by guard 1 — the hand-written components
#     (Victoria stack, NATS, RustFS, Grafana) and the first-party ones (portal,
#     picture-pipeline, application-xr), plus the hand-written siblings of
#     rendered components — extract the load-bearing knobs and fail if a token
#     never appears anywhere in that component's VENDOR.md.
#
# WHAT THIS DOES *NOT* PROVE — read this before trusting a green run:
#   - Guard 1's allowlists were BOOTSTRAPPED from the tree as it stood, i.e.
#     that day's diff was accepted wholesale as "the curation". Green means
#     "nothing has changed since the bootstrap", NOT "someone audited it".
#   - Guard 2 proves the VENDOR.md *mentions* a knob. It does not prove the
#     prose next to it is correct, current, or even about that knob. A doc that
#     lists every port and explains none of them passes.
#   - The knob extraction is a heuristic sample (ports, env names, images,
#     resource quantities, slash-keys, probe/hostPaths, RBAC resources, volume
#     shapes, readiness checks), not an exhaustive read of the YAML. A knob
#     shape nobody thought of is not covered.
#   - Neither guard says anything about whether the manifest is *right*. That
#     is what bootstrap-test.yaml is for.
#
# Usage:
#   ./scripts/check-vendor-drift.sh                  # both guards
#   ./scripts/check-vendor-drift.sh --offline        # guard 2 only (no network)
#   ./scripts/check-vendor-drift.sh --render-only    # guard 1 only
#   ./scripts/check-vendor-drift.sh --only zot,crossplane
#   ./scripts/check-vendor-drift.sh --update         # rewrite the allowlists
#   ./scripts/check-vendor-drift.sh --help
#
# Exit codes: 0 clean · 1 drift or a guard could not run.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

COMPONENTS_DIR="gitops/components"
BLOCK_LANG="curation"          # the fenced-block info string in VENDOR.md
ALLOW_MARKER="# --- accepted curation: one line per diff hunk (id, then why) ---"

RUN_RENDER=1
RUN_TOKENS=1
UPDATE=0
KEEP=0
ONLY=""                        # " name1 name2 " when filtering

FAILURES=0
ok()   { printf '✅ %s\n' "$1"; }
bad()  { printf '❌ FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '⚠️  %s\n' "$1"; }
info() { printf 'ℹ️  %s\n' "$1"; }

# Components whose guard-2 coverage is deliberately deferred. Loud on every
# run on purpose: a silent hole here is exactly how the VENDOR.md files rotted
# in the first place. Format: "<name>:<why>". Empty this list, do not grow it.
#
# A deferred component with no `render` recipe is covered by NEITHER guard.
DEFERRED=(
)

usage() {
  cat <<'EOF'
check-vendor-drift.sh — are the gitops/components/*/VENDOR.md files still true?

Guard 1 (re-render gate, NEEDS INTERNET + helm): re-produces the pristine
upstream artifact for every file a VENDOR.md documents as reproducible and
diffs it against the vendored copy. Every hunk must be listed in that
component's `curation` block; an unlisted hunk, or a listed hunk that has
disappeared, fails.

Guard 2 (token-coverage lint, offline): every load-bearing knob in a
hand-written manifest must appear somewhere in its VENDOR.md. This proves the
doc MENTIONS the knob — not that it explains it.

Usage:
  ./scripts/check-vendor-drift.sh [--offline|--render-only] [--only <name>…]
  ./scripts/check-vendor-drift.sh --update

Flags:
  --offline       guard 2 only — no network, no helm (what CI runs on push)
  --render-only   guard 1 only
  --only <name>   restrict to a component; repeatable and/or comma-separated
  --update        re-render, then rewrite the `allow` lines in each VENDOR.md
                  curation block from the current diff. Labels of surviving
                  hunks are kept; new hunks get a TODO label to fill in.
                  This is the bump-time affordance — ALWAYS read the resulting
                  VENDOR.md diff, it is the whole point of the gate.
  --keep          keep the scratch work directory and print its path
  --help          this text

Exit codes: 0 clean · 1 drift, or a guard could not run.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline|--tokens-only) RUN_RENDER=0 ;;
    --render-only)           RUN_TOKENS=0 ;;
    --update)                UPDATE=1 ;;
    --keep)                  KEEP=1 ;;
    --only)
      [[ $# -ge 2 ]] || { bad "--only needs a value"; exit 1; }
      ONLY="${ONLY} ${2//,/ }"; shift ;;
    --only=*)  ONLY="${ONLY} ${1#--only=}"; ONLY="${ONLY//,/ }" ;;
    -h|--help) usage; exit 0 ;;
    *) bad "unknown flag: $1 (try --help)"; exit 1 ;;
  esac
  shift
done

[[ "${UPDATE}" -eq 1 ]] && RUN_RENDER=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cloudbox-vendor-drift.XXXXXX")"
cleanup() {
  if [[ "${KEEP}" -eq 1 ]]; then
    printf 'kept: %s\n' "${WORK}"
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT
# Never touch the maintainer's real helm config/cache from a check script.
export HELM_CACHE_HOME="${WORK}/helm-cache"
export HELM_CONFIG_HOME="${WORK}/helm-config"
export HELM_DATA_HOME="${WORK}/helm-data"

selected() {
  [[ -z "${ONLY}" ]] && return 0
  case " ${ONLY} " in *" $1 "*) return 0 ;; esac
  return 1
}

deferred_reason() {
  local entry
  for entry in "${DEFERRED[@]:+${DEFERRED[@]}}"; do
    [[ "${entry%%:*}" == "$1" ]] && { printf '%s' "${entry#*:}"; return 0; }
  done
  return 1
}

# --- the curation block -------------------------------------------------------
# One fenced ```curation block per VENDOR.md, sitting next to the prose that
# explains WHY each curation exists (a sibling file would rot away from it —
# the failure mode this whole script exists to fix). Directives:
#
#   render <file>            start a stanza: <file> is reproducible upstream
#   fetch  <url>             …by downloading <url>
#   chart/repo/version/release/namespace/flags/values
#                            …or by `helm template`
#   allow  <file> <id> <why> an accepted diff hunk (<id> = hunk content digest)
#   ignore <token> <why>     a guard-2 token that is genuinely not a knob
#
# parse_block <vendor.md> <comp> → TAB-separated directive stream on stdout;
# `values` blocks are written to files under ${WORK}.
parse_block() {
  awk -v work="${WORK}" -v comp="$2" -v lang="${BLOCK_LANG}" '
    BEGIN { inblk = 0; vmode = 0; vfile = ""; cur = "" }
    {
      line = $0; sub(/\r$/, "", line)
      if (!inblk) { if (line == "```" lang) inblk = 1; next }
      if (line ~ /^```/) { inblk = 0; vmode = 0; next }

      if (vmode) {
        # a values block runs until the first non-indented, non-blank line
        if (line ~ /^[[:space:]]*$/) { print "" > vfile; next }
        if (line ~ /^[[:space:]]/) { sub(/^  /, "", line); print line > vfile; next }
        vmode = 0
      }

      if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next

      n = split(line, f, /[[:space:]]+/)
      d = f[1]
      rest = line; sub(/^[[:space:]]*[^[:space:]]+[[:space:]]*/, "", rest)

      if (d == "render") { cur = f[2]; print "render\t" cur; next }
      if (d == "allow") {
        why = rest; sub(/^[^[:space:]]+[[:space:]]+/, "", why)   # drop <file>
        sub(/^[^[:space:]]+[[:space:]]*/, "", why)               # drop <id>
        print "allow\t" f[2] "\t" f[3] "\t" why; next
      }
      if (d == "ignore") { print "ignore\t" f[2] "\t" rest; next }
      if (d == "values") {
        if (cur == "") { print "err\t`values` before any `render` line"; next }
        vfile = work "/" comp "." cur ".values.yaml"
        vmode = 1; printf "" > vfile
        print "set\t" cur "\tvalues\t" vfile; next
      }
      if (d == "fetch" || d == "chart" || d == "repo" || d == "version" ||
          d == "release" || d == "namespace" || d == "flags") {
        if (cur == "") { print "err\t`" d "` before any `render` line"; next }
        print "set\t" cur "\t" d "\t" rest; next
      }
      print "err\tunknown directive: " d
    }
  ' "$1"
}

directive() {   # directive <stream-file> <out> <key> → value (empty if unset)
  awk -F'\t' -v o="$2" -v k="$3" '$1=="set" && $2==o && $3==k { print $4; exit }' "$1"
}

# --- guard 1: reproduce the pristine upstream artifact -------------------------
reproduce() {   # reproduce <stream> <out> <dest>
  local stream="$1" out="$2" dest="$3"
  local url chart repo version release namespace flags values
  url="$(directive "${stream}" "${out}" fetch)"

  if [[ -n "${url}" ]]; then
    # --retry-all-errors is load-bearing: raw.githubusercontent.com rate-limits
    # (HTTP 429) and plain --retry does not treat every such response as
    # retryable, so a busy afternoon looked exactly like upstream drift.
    local code auth=()
    # Authenticate to github.com when we can. Unauthenticated fetches share a
    # per-IP budget that this repo exhausts on a busy day — raw.githubusercontent
    # and release-asset downloads both start answering 429, and a guard that goes
    # red for reasons unrelated to drift is a guard people learn to ignore.
    if [[ "${url}" == https://github.com/* || "${url}" == https://raw.githubusercontent.com/* ]]; then
      local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
      if [[ -z "${tok}" ]] && command -v gh >/dev/null 2>&1; then
        tok="$(gh auth token 2>/dev/null || true)"
      fi
      if [[ -n "${tok}" ]]; then
        auth=(-H "Authorization: Bearer ${tok}")
      fi
    fi
    # raw.githubusercontent.com rate-limits by IP and ignores a Bearer token for
    # public content, so authenticating it changes nothing — but the API serves the
    # identical bytes under the token's 5000/hour budget. Rewrite rather than retry:
    #   raw.githubusercontent.com/O/R/<ref>/<path>
    #     -> api.github.com/repos/O/R/contents/<path>?ref=<ref>   (Accept: …raw)
    local fetch_url="${url}"
    if [[ "${url}" == https://raw.githubusercontent.com/* && ${#auth[@]} -gt 0 ]]; then
      local rest="${url#https://raw.githubusercontent.com/}"
      local o="${rest%%/*}"; rest="${rest#*/}"
      local r="${rest%%/*}"; rest="${rest#*/}"
      local ref="${rest%%/*}"; local path="${rest#*/}"
      if [[ -n "${o}" && -n "${r}" && -n "${ref}" && -n "${path}" ]]; then
        fetch_url="https://api.github.com/repos/${o}/${r}/contents/${path}?ref=${ref}"
        auth+=(-H "Accept: application/vnd.github.raw")
      fi
    fi
    code="$(curl -sSL --retry 5 --retry-delay 2 --retry-all-errors \
              "${auth[@]+"${auth[@]}"}" \
              --max-time 300 -w '%{http_code}' -o "${dest}" "${fetch_url}" 2>/dev/null || echo 000)"
    if [[ "${code}" != 2?? ]]; then
      FETCH_FAILED="${code}"
      return 1
    fi
    return 0
  fi

  chart="$(directive "${stream}" "${out}" chart)"
  [[ -n "${chart}" ]] || { bad "${out}: curation block has neither \`fetch\` nor \`chart\`"; return 1; }
  repo="$(directive "${stream}" "${out}" repo)"
  version="$(directive "${stream}" "${out}" version)"
  release="$(directive "${stream}" "${out}" release)"
  namespace="$(directive "${stream}" "${out}" namespace)"
  flags="$(directive "${stream}" "${out}" flags)"
  values="$(directive "${stream}" "${out}" values)"

  # OCI charts: pull first, then template the tarball. `helm template oci://…`
  # prints "Pulled:"/"Digest:" lines to STDOUT, straight into the render.
  if [[ "${chart}" == oci://* ]]; then
    local pulldir="${WORK}/pull.${out}"
    mkdir -p "${pulldir}"
    helm pull "${chart}" --version "${version}" -d "${pulldir}" >/dev/null
    chart="$(find "${pulldir}" -name '*.tgz' | head -1)"
    [[ -n "${chart}" ]] || { bad "${out}: helm pull produced no chart tarball"; return 1; }
    version=""   # already resolved by the pull
  fi

  local args
  args=()
  if [[ -n "${repo}" ]];      then args=("${args[@]:+${args[@]}}" --repo "${repo}"); fi
  if [[ -n "${version}" ]];   then args=("${args[@]:+${args[@]}}" --version "${version}"); fi
  if [[ -n "${namespace}" ]]; then args=("${args[@]:+${args[@]}}" --namespace "${namespace}"); fi
  if [[ -n "${values}" ]];    then args=("${args[@]:+${args[@]}}" -f "${values}"); fi
  if [[ -n "${flags}" ]]; then
    # deliberate word-split: `flags` is a documented argv fragment
    # shellcheck disable=SC2206
    local extra=(${flags})
    args=("${args[@]:+${args[@]}}" "${extra[@]}")
  fi
  helm template "${release:-${out%%.*}}" "${chart}" "${args[@]:+${args[@]}}" > "${dest}"
}

# split a unified diff into content-addressed hunks; prints
# "<id><TAB><@@ header><TAB><first changed line>" and writes each hunk body to
# ${hdir}/<id>. The id is a digest of the CHANGED LINES ONLY — not of line
# numbers or context — so a curation keeps its id when upstream shifts it
# around, and only changes when the curation itself changes. Two hunks with
# identical content share an id, and one `allow` line covers both (the halved
# resource requests repeat verbatim across Deployments).
split_hunks() {  # split_hunks <diff-file> <hunk-dir>
  local diff="$1" hdir="$2" n=0 hdr="" body=""
  mkdir -p "${hdir}"
  local line id first
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      @@*)
        if [[ -n "${hdr}" ]]; then
          id="$(printf '%s' "${body}" | git hash-object --stdin | cut -c1-8)"
          printf '%s' "${body}" > "${hdir}/${id}"
          first="$(printf '%s' "${body}" | head -1)"
          printf '%s\t%s\t%s\n' "${id}" "${hdr}" "${first}"
        fi
        hdr="${line%% @@*} @@"; body=""; n=$((n + 1)) ;;
      ---*|+++*|'diff --git'*|'index '*|'new file'*|'deleted file'*|'similarity'*|'rename '*)
        [[ -z "${hdr}" ]] || body="${body}${line}"$'\n' ;;
      -*|+*)
        body="${body}${line}"$'\n' ;;
      *) : ;;
    esac
  done < "${diff}"
  if [[ -n "${hdr}" ]]; then
    id="$(printf '%s' "${body}" | git hash-object --stdin | cut -c1-8)"
    printf '%s' "${body}" > "${hdir}/${id}"
    first="$(printf '%s' "${body}" | head -1)"
    printf '%s\t%s\t%s\n' "${id}" "${hdr}" "${first}"
  fi
}

guard1_component() {   # guard1_component <comp> <stream>
  local comp="$1" stream="$2"
  local dir="${COMPONENTS_DIR}/${comp}" vendor="${COMPONENTS_DIR}/${comp}/VENDOR.md"
  local out pristine vendored diff hdir before ids seen id hdr first label

  while IFS=$'\t' read -r _ out; do
    [[ -n "${out}" ]] || continue
    RENDERED_TOTAL=$((RENDERED_TOTAL + 1))
    vendored="${dir}/${out}"
    if [[ ! -f "${vendored}" ]]; then
      bad "${comp}: VENDOR.md renders '${out}' but ${vendored} does not exist — the curation block names a file that moved"
      continue
    fi
    pristine="${WORK}/${comp}.${out}.pristine"
    FETCH_FAILED=""
    if ! reproduce "${stream}" "${out}" "${pristine}"; then
      # A network failure is NOT drift, and saying so matters: an HTTP 429 from
      # raw.githubusercontent.com once read as "the vendored file no longer
      # matches upstream", which is the most alarming thing this script can say.
      if [[ -n "${FETCH_FAILED}" ]]; then
        bad "${comp}/${out}: could not FETCH the upstream artifact (HTTP ${FETCH_FAILED}) — this is a network failure, NOT drift. The vendored file was never compared. Re-run; if it persists check the \`fetch\` URL in ${vendor}."
      else
        bad "${comp}/${out}: could not reproduce the upstream artifact — see the \`render\` stanza in ${vendor}"
      fi
      continue
    fi

    diff="${WORK}/${comp}.${out}.diff"
    git --no-pager diff --no-index --no-color --no-ext-diff --unified=0 \
      -- "${pristine}" "${vendored}" > "${diff}" 2>/dev/null || true

    hdir="${WORK}/${comp}.${out}.hunks"
    split_hunks "${diff}" "${hdir}" > "${WORK}/${comp}.${out}.ids"

    before=${FAILURES}
    seen=""
    while IFS=$'\t' read -r id hdr first; do
      [[ -n "${id}" ]] || continue
      case " ${seen} " in *" ${id} "*) continue ;; esac
      seen="${seen} ${id}"
      if ! awk -F'\t' -v o="${out}" -v i="${id}" \
            '$1=="allow" && $2==o && $3==i { found=1 } END { exit !found }' "${stream}"; then
        bad "${comp}/${out}: unlisted diff hunk ${id} at ${hdr}
      ${first}
      This differs from the pristine upstream artifact and nothing says why.
      Re-apply the lost workshop curation, or — if the difference is intended —
      add it to the \`\`\`${BLOCK_LANG} block in ${vendor}:
        allow  ${out}  ${id}  <one line: why this differs from upstream>
      (\`./scripts/check-vendor-drift.sh --update --only ${comp}\` does the
      bookkeeping; you still write the why.)"
      fi
    done < "${WORK}/${comp}.${out}.ids"

    # An allow line that matches nothing is the OTHER failure: the curation it
    # documents is gone from the vendored file (a re-vendor that forgot to
    # re-apply it), or its content changed.
    while IFS=$'\t' read -r _ _ id label; do
      [[ -n "${id}" ]] || continue
      if [[ ! -f "${hdir}/${id}" ]]; then
        bad "${comp}/${out}: curation ${id} is documented but NO LONGER PRESENT — \"${label}\"
      The vendored file now matches upstream here, so the curation was lost
      (or changed). Re-apply it, or delete the \`allow\` line in ${vendor}
      if it was dropped on purpose."
      fi
    done < <(awk -F'\t' -v o="${out}" '$1=="allow" && $2==o' "${stream}")

    ids="$(wc -l < "${WORK}/${comp}.${out}.ids" | tr -d ' ')"
    if [[ "${FAILURES}" -eq "${before}" ]]; then
      ok "${comp}/${out}: reproduces upstream, ${ids} hunk(s) all accounted for"
    fi
  done < <(awk -F'\t' '$1=="render"' "${stream}")
}

# --- guard 1 --update: rewrite the allow lines from the current diff -----------
update_component() {   # update_component <comp> <stream>
  local comp="$1" stream="$2"
  local vendor="${COMPONENTS_DIR}/${comp}/VENDOR.md"
  local new="${WORK}/${comp}.allow"
  : > "${new}"
  local out id hdr first label
  while IFS=$'\t' read -r _ out; do
    [[ -n "${out}" ]] || continue
    [[ -f "${WORK}/${comp}.${out}.ids" ]] || continue
    local seen=""
    while IFS=$'\t' read -r id hdr first; do
      [[ -n "${id}" ]] || continue
      case " ${seen} " in *" ${id} "*) continue ;; esac
      seen="${seen} ${id}"
      label="$(awk -F'\t' -v o="${out}" -v i="${id}" \
                '$1=="allow" && $2==o && $3==i { print $4; exit }' "${stream}")"
      if [[ -z "${label}" ]]; then
        first="$(printf '%s' "${first}" | cut -c1-60)"
        label="TODO describe: ${first}"
      fi
      printf 'allow  %s  %s  %s\n' "${out}" "${id}" "${label}" >> "${new}"
    done < "${WORK}/${comp}.${out}.ids"
  done < <(awk -F'\t' '$1=="render"' "${stream}")

  awk -v lang="${BLOCK_LANG}" -v allow="${new}" -v marker="${ALLOW_MARKER}" '
    function emit(  l) {
      if (done) return
      print ""; print marker
      while ((getline l < allow) > 0) print l
      done = 1
    }
    BEGIN { inblk = 0; done = 0 }
    {
      if (!inblk) { print; if ($0 == "```" lang) inblk = 1; next }
      if ($0 ~ /^```/)                { emit(); print; inblk = 0; next }
      if ($0 ~ /^allow[[:space:]]/)   { emit(); next }
      if ($0 == marker)               { emit(); next }
      if ($0 ~ /^[[:space:]]*$/)      { blank = 1; next }
      if (blank) { print ""; blank = 0 }
      print
    }
  ' "${vendor}" > "${WORK}/${comp}.VENDOR.md"
  mv "${WORK}/${comp}.VENDOR.md" "${vendor}"
  ok "${comp}: curation allowlist rewritten in ${vendor} — READ THE DIFF"
}

# --- guard 2: token coverage --------------------------------------------------
# Extractors, one per load-bearing knob shape. Anchored at the start of the
# (list-item-stripped) line so a knob named in a YAML comment is never mistaken
# for a knob that is actually set.
extract_tokens() {   # extract_tokens <file…> → "<kind><TAB><token>" lines
  awk '
    BEGIN { blk = 0; blkind = 0; rbac = 0; rbacind = 0; ready = 0; readyind = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      ind = match(line, /[^ ]/) - 1
      if (blk  && ind <= blkind)  blk = 0
      if (rbac && ind <= rbacind) rbac = 0
      if (ready && ind <= readyind) ready = 0
      if (line ~ /^[[:space:]]*#/) next
      key = line; sub(/^[[:space:]]*-[[:space:]]*/, "", key); sub(/^[[:space:]]*/, "", key)

      # --- inside an embedded config block scalar (grafana datasources, the
      # collector config, backstage app-config): only camelCase keys and keys
      # with a slash. The snake_case section names of the vendored upstream
      # schemas (scrape_configs, retry_on_failure, …) are structure, not
      # workshop choices, and drown the signal.
      if (blk) {
        if (match(key, /^[A-Za-z][A-Za-z0-9_.\/-]*:/)) {
          v = key; sub(/:.*$/, "", v)
          if (v ~ /[a-z][A-Z]/ || v ~ /\//) print "cfg-key\t" v
        }
        next
      }
      if (match(key, /^[A-Za-z][A-Za-z0-9_.-]*:[[:space:]]*[|>]/)) { blk = 1; blkind = ind; next }

      # --- RBAC rule resources, flow or block list. What a ClusterRole grants
      # is a workshop decision (the console reads exactly five surfaces,
      # "deliberately NOT read-all"), so privilege creep should have to be
      # written down. A `resources:` block that is NOT a plain list is a
      # container resources block — fall through so its cpu/memory lines still
      # reach the quantity extractor below.
      if (rbac) {
        if (line ~ /^[[:space:]]*-[[:space:]]/ && key !~ /:/) {
          v = key; gsub(/["[:space:]]/, "", v); if (v != "") print "rbac\t" v
          next
        }
        rbac = 0
      }
      if (match(key, /^resources:[[:space:]]*$/)) { rbac = 1; rbacind = ind; next }
      if (match(key, /^resources:[[:space:]]*\[/)) {
        v = key; sub(/^resources:[[:space:]]*\[/, "", v); sub(/\].*$/, "", v)
        n = split(v, a, ",")
        for (i = 1; i <= n; i++) { t = a[i]; gsub(/["[:space:]]/, "", t); if (t != "") print "rbac\t" t }
        next
      }

      # --- Crossplane readinessChecks
      if (ready) {
        if (match(key, /^(type|status):[[:space:]]*"?[A-Za-z]/)) {
          v = key; sub(/^[a-z]+:[[:space:]]*/, "", v); gsub(/["[:space:]]/, "", v)
          print "readiness\t" v; next
        }
      }
      if (match(key, /^readinessChecks:[[:space:]]*$/)) { ready = 1; readyind = ind; next }

      # --- ports (nodePort, containerPort, service port/targetPort)
      if (match(key, /^(nodePort|containerPort|port|targetPort|hostPort):[[:space:]]*"?[0-9]+/)) {
        v = key; sub(/^[a-zA-Z]+:[[:space:]]*"?/, "", v); sub(/[^0-9].*$/, "", v)
        print "port\t" v; next
      }
      # --- env var names (SCREAMING_SNAKE is the convention everywhere here)
      if (match(key, /^name:[[:space:]]*"?[A-Z][A-Z0-9_]*"?[[:space:]]*$/)) {
        v = key; sub(/^name:[[:space:]]*/, "", v); gsub(/["[:space:]]/, "", v)
        print "env\t" v; next
      }
      # --- image refs (digest stripped: VENDOR.md pins repo:tag in prose and
      #     the digest separately, and images-gate.yaml owns the digest)
      if (match(key, /^image:[[:space:]]*/)) {
        v = key; sub(/^image:[[:space:]]*/, "", v); gsub(/["]/, "", v); gsub(/\047/, "", v)
        sub(/@sha256:.*$/, "", v); sub(/[[:space:]].*$/, "", v)
        if (v != "" && v !~ /\$/) print "image\t" v
        next
      }
      # --- resource requests/limits and PVC sizes
      if (match(key, /^(cpu|memory|storage|ephemeral-storage):[[:space:]]*"?[0-9]/)) {
        v = key; sub(/^[a-z-]+:[[:space:]]*/, "", v); gsub(/["[:space:]]/, "", v)
        print "qty\t" v; next
      }
      # --- keys carrying a slash: annotations, PSA labels, exporter names
      if (match(key, /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9._-]+:/)) {
        v = key; sub(/:.*$/, "", v)
        # app.kubernetes.io/* + helm.sh/chart + kubernetes.io/metadata.name are
        # standard identity labels, identical in every component — mentioning
        # them in prose would be noise, not documentation.
        if (v ~ /^app\.kubernetes\.io\// || v == "helm.sh/chart" || v == "kubernetes.io/metadata.name") next
        print "slash-key\t" v; next
      }
      # --- probe paths and hostPaths (both spelled `path:`)
      if (match(key, /^path:[[:space:]]*"?\//)) {
        v = key; sub(/^path:[[:space:]]*/, "", v); gsub(/["[:space:]]/, "", v)
        print "path\t" v; next
      }
      # --- distinctive volume shapes (configMap/secret are too common to mean
      #     anything; hostPath and projected are decisions)
      if (match(key, /^(hostPath|projected|emptyDir|downwardAPI|csi|nfs):[[:space:]]*$/)) {
        v = key; sub(/:.*$/, "", v); print "volume\t" v; next
      }
      # --- cross-references to other objects
      if (match(key, /^(claimName|secretName):[[:space:]]*"?[A-Za-z0-9]/)) {
        v = key; sub(/^[a-zA-Z]+:[[:space:]]*/, "", v); gsub(/["[:space:]]/, "", v)
        print "ref\t" v; next
      }
      if (match(key, /^kind:[[:space:]]*(ConfigMap|Secret)[[:space:]]*$/)) { pend = 1; next }
      if (pend && match(key, /^name:[[:space:]]*"?[a-z]/)) {
        v = key; sub(/^name:[[:space:]]*/, "", v); gsub(/["[:space:]]/, "", v)
        print "ref\t" v; pend = 0; next
      }
      pend = 0
    }
  ' "$@"
}

guard2_component() {   # guard2_component <comp> <stream>
  local comp="$1" stream="$2"
  local dir="${COMPONENTS_DIR}/${comp}" vendor="${COMPONENTS_DIR}/${comp}/VENDOR.md"
  local files=() f rel kind tok reason before checked=0

  while IFS= read -r f; do
    rel="${f#"${dir}"/}"
    # skip files guard 1 already owns (rendered upstream artifacts)
    if [[ -n "${stream}" ]] && awk -F'\t' -v o="${rel}" '$1=="render" && $2==o { found=1 } END { exit !found }' "${stream}"; then
      continue
    fi
    files=("${files[@]:+${files[@]}}" "${f}")
  done < <(find "${dir}" \( -name '*.yaml' -o -name '*.yml' \) | sort)

  [[ ${#files[@]} -gt 0 ]] || return 0

  before=${FAILURES}
  while IFS=$'\t' read -r kind tok; do
    [[ -n "${tok}" ]] || continue
    checked=$((checked + 1))
    reason="$(awk -F'\t' -v t="${tok}" '$1=="ignore" && $2==t { print $3; exit }' "${stream:-/dev/null}")"
    [[ -n "${reason}" ]] && continue
    grep -qF -- "${tok}" "${vendor}" \
      || bad "${comp}: [${kind}] '${tok}' is set in the manifests but appears nowhere in ${vendor} — document it (one clause: what it is FOR), or, if it genuinely is not a knob, add \`ignore ${tok}  <why>\` to the ${BLOCK_LANG} block there"
  done < <(extract_tokens "${files[@]}" | sort -u)

  # stale ignores rot exactly like stale docs
  while IFS=$'\t' read -r _ tok reason; do
    [[ -n "${tok}" ]] || continue
    extract_tokens "${files[@]}" | cut -f2 | grep -qxF -- "${tok}" \
      || bad "${comp}: \`ignore ${tok}\` in ${vendor} matches nothing any more (\"${reason}\") — delete the line"
  done < <(awk -F'\t' '$1=="ignore"' "${stream:-/dev/null}")

  if [[ "${FAILURES}" -eq "${before}" ]]; then
    ok "${comp}: all ${checked} extracted knob(s) are mentioned in VENDOR.md"
  fi
}

# =============================================================================
# main
# =============================================================================
printf '=== VENDOR.md drift gate ===\n'
[[ "${RUN_RENDER}" -eq 1 ]] && printf 'guard 1: re-render + curation allowlist (needs network + helm)\n'
[[ "${RUN_TOKENS}" -eq 1 ]] && printf 'guard 2: knob-token coverage in VENDOR.md (offline)\n'
printf '\n'

if [[ "${RUN_RENDER}" -eq 1 ]] && ! command -v helm >/dev/null 2>&1; then
  bad "helm is not on PATH — guard 1 cannot run (mise install helm, or pass --offline)"
  exit 1
fi

comps=0
RENDERED_TOTAL=0
for dir in "${COMPONENTS_DIR}"/*/; do
  comp="$(basename "${dir}")"
  selected "${comp}" || continue
  comps=$((comps + 1))
  vendor="${dir}VENDOR.md"
  if [[ ! -f "${vendor}" ]]; then
    bad "${comp}: no VENDOR.md — every component must say where its manifests came from"
    continue
  fi

  stream="${WORK}/${comp}.directives"
  parse_block "${vendor}" "${comp}" > "${stream}"
  while IFS=$'\t' read -r _ msg; do
    [[ -n "${msg}" ]] && bad "${comp}: curation block in ${vendor}: ${msg}"
  done < <(awk -F'\t' '$1=="err"' "${stream}")

  if [[ "${RUN_RENDER}" -eq 1 ]]; then
    guard1_component "${comp}" "${stream}"
    if [[ "${UPDATE}" -eq 1 ]] && grep -q '^render' "${stream}"; then
      update_component "${comp}" "${stream}"
    fi
  fi

  if [[ "${RUN_TOKENS}" -eq 1 ]]; then
    if reason="$(deferred_reason "${comp}")"; then
      warn "${comp}: guard 2 DEFERRED — ${reason}"
    else
      guard2_component "${comp}" "${stream}"
    fi
  fi
done

echo
[[ "${comps}" -gt 0 ]] || { bad "no components matched --only"; exit 1; }

if [[ "${RUN_RENDER}" -eq 1 ]]; then
  info "guard 1 covered ${RENDERED_TOTAL} rendered file(s). The allowlists were BOOTSTRAPPED
   from the vendored manifests as they stood — that day's diff WAS the accepted
   curation. Green means \"nothing changed since\", not \"someone audited it\"."
fi
if [[ "${RUN_TOKENS}" -eq 1 ]]; then
  info "guard 2 proves each knob is MENTIONED in its VENDOR.md. It cannot tell
   a correct explanation from a stale one, and its extraction is a sample of
   knob shapes, not a full read of the YAML."
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\n❌ %d VENDOR.md drift failure(s).\n' "${FAILURES}"
  exit 1
fi
printf '\n'
ok "VENDOR.md files still describe the manifests they document"
