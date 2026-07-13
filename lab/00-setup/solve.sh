#!/usr/bin/env bash
# Module 00 — full solution. Mirrors the "Full solution" block in README.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

"$REPO_ROOT/scripts/dev-setup.sh"
"$REPO_ROOT/scripts/install.sh" --check
"$REPO_ROOT/scripts/cloudbox-init.sh"
