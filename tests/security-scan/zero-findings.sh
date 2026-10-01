#!/bin/sh
# Distinguish scoped complete-zero from incomplete-zero coverage.
# Scenario: Close only complete-zero existing open reports.
# Given: Valid complete/incomplete zero-finding bytes and in-memory issue history.
# When: The actual injected synchronizer plans and executes report actions.
# Then: Complete-zero closes scoped reports, never creates or heartbeats.
# Then: Incomplete-zero creates/reopens, never closes or claims clean.
# Mutation: treat zero findings alone as clean or ignore closed unchanged reports.
# Exit codes: 0 passed; 1 assertion failure; other nonzero harness failure.
set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
exec "$REPO_ROOT/scripts/validate-security-scan-report.sh" zero-findings
