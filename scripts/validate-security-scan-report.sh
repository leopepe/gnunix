#!/bin/sh
# Offline report validator/API traces; Node is already used by github-script.
# Arguments: one GWT scenario name. No network, real issues or new framework.
set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
exec node "$REPO_ROOT/tests/security-scan/fixtures/report/scenarios.js" "$@"
