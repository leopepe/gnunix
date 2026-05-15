<!--
Thanks for the PR. Fill in the sections below; delete any that don't apply.
Brevity is fine — "Fixes #42, see ADR-009" is a complete answer for many PRs.
-->

## Summary

<!-- One or two sentences. What does this change do? -->

## Why

<!-- Link the driving issue, ADR, or runbook. If this implements an ADR,
     reference it by number (e.g., "implements ADR-010 § rpi-native"). -->

Fixes #
Implements:

## How validated

<!--
Per CLAUDE.md § How to validate work, smoke tests are the real gate.
Tick what you ran; note anything you couldn't run locally and why.
-->

- [ ] `tests/boot-smoke.sh <image>` — for any change to `gnunix-base` or `gnunix-minimal`
- [ ] `tests/wayland-session.sh <image>` — for any change to `gnunix-desktop`
- [ ] `tests/minimal-smoke.sh <image>` — for any change to the Nix layer
- [ ] `tools/package-platform.sh <image> <arch> <platform>` — for platform packagers
- [ ] CI `PR lint` is green (shellcheck + actionlint + gitleaks + manifest schema)
- [ ] Documentation only — no image rebuild needed
- [ ] Other: <!-- describe -->

## Locked-decisions check

<!--
The 13 locked decisions in CLAUDE.md cannot be relitigated without updating
the relevant ADR. Tick if this PR touches any of them; otherwise leave
unticked.
-->

- [ ] Touches a locked decision (which ADR?): <!-- ADR-NNN -->
- [ ] Introduces a new locked decision (new ADR included in this PR): <!-- ADR-NNN -->
- [ ] None of the above

## Reviewer notes

<!--
Anything that isn't obvious from the diff. Backwards-incompatible behaviour,
state migration, manual steps after merge, follow-up PRs you're planning.
-->

## Checklist

- [ ] I read [`CONTRIBUTING.md`](../CONTRIBUTING.md) and followed the relevant conventions in [`CLAUDE.md`](../CLAUDE.md).
- [ ] Pinned versions changed in their own commit (per ADR-008), or no version pins were touched.
- [ ] New scripts have `set -eu` (or `set -euo pipefail` for bash) and use absolute paths / `REPO_ROOT`.
- [ ] New files are in the right directory per `CLAUDE.md § Where things go`.
- [ ] I am OK with my contribution being distributed under the [`LICENSE`](../LICENSE).

<!--
Optional: request an advisory architectural review by commenting
`@ai review` (or `@claude review`) on this PR after it's open, or apply
the `ai-review` (or `claude-review`) label. The review is non-blocking and
runs against whichever LLM the repo is configured for (OpenRouter free
tier by default); see ADR-014 and .github/workflows/ai-review.yml.
-->
