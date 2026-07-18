#!/usr/bin/env bash
# Canonical answer for attendees and the CI inject -> solve -> verify regression.
# Unlike module 05, solving this lab means reverting whatever is injected now;
# solve.sh must not inject a scenario of its own first.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$DIR/restore.sh" all
