#!/bin/sh
# tests/installer/run-all.sh
#
# Run the installer acceptance test for every profile and print a
# summary at the end. Continues past individual failures so you see
# the full picture in one CI run.
#
# Exit code = number of failed profiles (0 if all passed).

set -u
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}

PROFILES="minimal desktop-sway desktop-hyprland desktop-labwc desktop-cosmic"
PASSED=""
FAILED=""

for P in $PROFILES; do
  echo
  echo "================================================================"
  echo "  installer profile: $P"
  echo "================================================================"
  if "$REPO_ROOT/tests/installer/profile-${P##desktop-}.sh" 2>&1 \
       | sed "s/^/[$P] /"; then
    PASSED="$PASSED $P"
  else
    FAILED="$FAILED $P"
  fi
done

echo
echo "================================================================"
echo "  installer test summary"
echo "================================================================"
[ -n "$PASSED" ] && echo "  PASS:$PASSED"
[ -n "$FAILED" ] && echo "  FAIL:$FAILED"

if [ -n "$FAILED" ]; then
  echo "  artifacts preserved under $REPO_ROOT/cache/installer-test/"
  count=$(echo "$FAILED" | wc -w | tr -d ' ')
  exit "$count"
fi
exit 0
