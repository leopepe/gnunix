#!/bin/sh
# Reject malformed report bytes before any API mutation.
# Scenario: Validate the entire frozen corpus with independent trusted inputs.
# Given: Node, 106 read-only shared cases and consumer-specific side inputs.
# When: The actual CommonJS validator and synchronizer consume raw bytes.
# Then: 21 positives pass; 85 negatives make zero writes; corpus stays unchanged.
# Mutation: skip malformed rows, trust producer counts, or lose duplicate keys.
# Exit codes: 0 passed; 1 assertion failure; other nonzero harness failure.
set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/validate-security-scan-report.sh" invalid-report
