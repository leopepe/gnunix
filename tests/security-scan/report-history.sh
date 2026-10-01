#!/bin/sh
# Reuse one stable-title, fully labeled issue across paginated history.
# Scenario: Discover closed reports, reject ambiguous candidates and exclude PRs.
# Given: Offline GitHub pages with a closed report on page two and API traces.
# When: The actual injected synchronizer discovers and plans report actions.
# Then: The same report reopens, arbitrary numbers work, duplicates cause no writes.
# Then: PRs and partial-label matches are excluded; API errors propagate.
# Mutation: discover only open/page-one issues, hardcode 151 or merge duplicates.
# Exit codes: 0 passed; 1 assertion failure; other nonzero harness failure.
set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/validate-security-scan-report.sh" report-history
