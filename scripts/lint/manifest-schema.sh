#!/bin/sh
# scripts/lint/manifest-schema.sh
#
# Verifies tools/manifest.json structure. Mirrors the `manifest-schema`
# job in .github/workflows/pr-lint.yml — keep the two predicates here
# in sync with that workflow.
#
# Invoked by:
#   - .pre-commit-config.yaml (local pre-commit hook)
#   - pr-lint.yml (CI, when we wire it to call this script)
#
# Exits 0 on pass; non-zero with a one-line reason on failure.

set -eu

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
MANIFEST="$REPO_ROOT/tools/manifest.json"

[ -f "$MANIFEST" ] || { echo "[manifest] missing: $MANIFEST" >&2; exit 1; }

jq -e '.lfs_image_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$MANIFEST" >/dev/null \
  || { echo "[manifest] lfs_image_version is not semver" >&2; exit 1; }

jq -e '
  .active_arch as $a
  | (.archs[$a] | type) == "object"
  and (.platforms | type) == "object"
  and ([.platforms[] | .archs | length] | add) > 0
' "$MANIFEST" >/dev/null \
  || { echo "[manifest] active_arch / archs / platforms structure invalid" >&2; exit 1; }

echo "[manifest] OK ($(jq -r .lfs_image_version "$MANIFEST"))"
