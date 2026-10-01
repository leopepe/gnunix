#!/bin/sh
# Fingerprint substantive identity, findings, inventory and coverage, not runs.
# Scenario: Refresh version/coverage changes even when CVE IDs are unchanged.
# Given: Valid shared result bytes, trusted side inputs and an in-memory issue.
# When: The injected synchronizer compares canonical substantive states.
# Then: Version/coverage/score/output changes refresh; order/time changes do not.
# Then: Every finding/source association survives and markdown is escaped.
# Mutation: fingerprint only CVE IDs or omit coverage/provenance associations.
# Exit codes: 0 passed; 1 assertion failure; other nonzero harness failure.
set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/validate-security-scan-report.sh" report-delta
