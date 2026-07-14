#!/usr/bin/env bash
# Module 00 — full solution. Mirrors the "Full solution" block in README.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Order matters: the pre-flight check verifies the pre-pulled images, so the
# init (pull) step must come first — on a fresh machine check-first is all red.
"$REPO_ROOT/scripts/dev-setup.sh"
"$REPO_ROOT/scripts/cloudbox-init.sh"
"$REPO_ROOT/scripts/install.sh" --check
