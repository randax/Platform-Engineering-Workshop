#!/usr/bin/env bash
# Scenario 01 — poison the Git-managed demo-app PORT with a plausible release edit.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Runtime lookup is anchored to this script; ShellCheck cannot resolve $DIR.
# shellcheck disable=SC1091
source "$DIR/../../../common.sh"

DEMO_REPO_URL="${DEMO_REPO_URL:-http://gitea_admin:cloudbox123@${GITEA_HOST}/cloudbox/demo-app.git}"
DEPLOYMENT_PATH="deploy/deployment.yaml"
POISON_VALUE="8080-canary"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
CLONE="$TMP_ROOT/demo-app"

if ! git clone --quiet --depth 100 --branch main --single-branch \
  "$DEMO_REPO_URL" "$CLONE" 2>/dev/null; then
  echo "ERROR: could not clone http://${GITEA_HOST}/cloudbox/demo-app.git — is Gitea running and seeded?" >&2
  exit 1
fi

if [ ! -f "$CLONE/$DEPLOYMENT_PATH" ]; then
  echo "ERROR: cloudbox/demo-app has no $DEPLOYMENT_PATH." >&2
  echo "Enable module 10's packaging/day-2 demo app first, then run ./inject.sh 1 again." >&2
  exit 1
fi

# Idempotency is by construction: the poison value is the injected artifact's
# marker. Refusing before mutation makes a second injection unable to push.
if grep -Fq -- "$POISON_VALUE" "$CLONE/$DEPLOYMENT_PATH"; then
  echo "ERROR: scenario 1 already injected — run ./restore.sh 1 first" >&2
  exit 1
fi

MUTATED="$TMP_ROOT/deployment.yaml"
if ! awk -v poison="$POISON_VALUE" '
  function indent_of(s, t) {
    t = s
    sub(/[^ ].*$/, "", t)
    return length(t)
  }
  function spaces(n, s) {
    s = ""
    while (length(s) < n) s = s " "
    return s
  }
  function blank_or_comment(s, t) {
    t = s
    sub(/^[ ]*/, "", t)
    return t == "" || substr(t, 1, 1) == "#"
  }
  function add_port(env_column) {
    print spaces(env_column + 2) "- name: PORT"
    print spaces(env_column + 4) "value: \"" poison "\""
    port_found = 1
    changed = 1
  }
  function close_env() {
    if (in_demo && in_env && !port_found) add_port(env_indent)
    in_env = 0
  }
  function close_container() {
    close_env()
    if (in_demo && !env_seen) {
      print spaces(container_indent + 2) "env:"
      add_port(container_indent + 2)
    }
    in_demo = 0
    env_seen = 0
    port_found = 0
    port_pending = 0
  }
  BEGIN {
    container_indent = -1
  }
  {
    line = $0
    ind = indent_of(line)

    # A PORT item is changed only when its immediately adjacent child is value:.
    if (port_pending) {
      if (ind > port_name_indent && line ~ /^[ ]*value:[ ]*/) {
        comment = ""
        if (match(line, /[ ]+#/)) comment = substr(line, RSTART)
        print spaces(ind) "value: \"" poison "\"" comment
        port_pending = 0
        port_found = 1
        changed = 1
        next
      }
      print "PORT under the demo-app container is not immediately followed by value:" > "/dev/stderr"
      bad = 1
      exit 42
    }

    if (in_demo && in_env && !blank_or_comment(line) && ind <= env_indent)
      close_env()

    if (in_containers && !blank_or_comment(line) && ind <= containers_indent) {
      close_container()
      in_containers = 0
      container_indent = -1
    }

    if (line ~ /^[ ]*containers:[ ]*(#.*)?$/) {
      in_containers = 1
      containers_indent = ind
      container_indent = -1
      print line
      next
    }

    if (in_containers && container_indent < 0 && line ~ /^[ ]*-[ ]+name:/)
      container_indent = ind

    if (in_containers && container_indent >= 0 && ind == container_indent &&
        line ~ /^[ ]*-/) {
      close_container()
      in_demo = (line ~ /^[ ]*-[ ]+name:[ ]*["\047]?demo-app["\047]?[ ]*(#.*)?$/)
      if (in_demo) demo_seen = 1
    }

    if (in_demo && line ~ /^[ ]*env:[ ]*\[[ ]*\][ ]*(#.*)?$/) {
      print spaces(ind) "env:"
      env_seen = 1
      add_port(ind)
      next
    }
    if (in_demo && line ~ /^[ ]*env:[ ]*(#.*)?$/) {
      env_seen = 1
      in_env = 1
      env_indent = ind
    } else if (in_demo && line ~ /^[ ]*env:/) {
      print "unsupported inline env value under the demo-app container" > "/dev/stderr"
      bad = 1
      exit 43
    }

    if (in_demo && in_env &&
        line ~ /^[ ]*-[ ]+name:[ ]*["\047]?PORT["\047]?[ ]*(#.*)?$/) {
      port_pending = 1
      port_name_indent = ind
    }

    print line
  }
  END {
    if (bad) exit 1
    close_container()
    if (!demo_seen) {
      print "could not find a container named demo-app" > "/dev/stderr"
      exit 1
    }
    if (!changed) {
      print "deployment was not changed" > "/dev/stderr"
      exit 1
    }
  }
' "$CLONE/$DEPLOYMENT_PATH" > "$MUTATED"; then
  echo "ERROR: could not safely update PORT in $DEPLOYMENT_PATH — check the demo-app container's YAML structure" >&2
  exit 1
fi
mv "$MUTATED" "$CLONE/$DEPLOYMENT_PATH"

git -C "$CLONE" add "$DEPLOYMENT_PATH"
git -C "$CLONE" -c user.name="cloudbox" -c user.email="cloudbox@localhost" \
  commit -q -m "release: demo-app port-band rollout" \
  -m "Cloudbox-Scenario: day2-01"
INJECTED_SHA="$(git -C "$CLONE" rev-parse --short HEAD)"
git -C "$CLONE" push -q origin main

echo "💥 Scenario 01-bad-release-rollback injected as commit $INJECTED_SHA."
echo
echo "Your job: find the symptom, write a diagnosis, prove it, then revert the bad release."
echo "Start with:"
echo "  kubectl -n demo get all"
echo
echo "NO PEEKING at scenarios/01-bad-release-rollback/description.md"
echo "until you have written down a diagnosis. Give up / done: ./restore.sh 1"
