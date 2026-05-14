# ADR-014: AI-assisted PR review

**Status:** Accepted
**Date:** 2026-05-17 (originally drafted as "Claude skill"; generalised on 2026-05-19)

## Context

The repo is single-maintainer (ADR-005). Renovate (ADR-008) opens version-bump
PRs continuously; the human merging them is the same person who'd be
reviewing them. Two adjacent problems:

1. **Objective checks are easy to forget.** Shellcheck, actionlint, gitleaks,
   manifest schema validation — all deterministic, all fast, all should run
   on every PR. The repo had no PR-time linting before this ADR; only
   `boot-smoke.sh` after the fact.
2. **Architectural drift is hard to spot.** CLAUDE.md lists 14 locked
   decisions. A reviewer with the architecture loaded in their head catches
   "this introduces a fallback path / systemd creep / NixOS module" early;
   a tired human at midnight, merging a Renovate PR, does not.

We want a check that:

- Validates the objective rules deterministically and **blocks** merge.
- Surfaces architectural smells **advisorially**, with citations to the
  ADRs/CLAUDE.md sections being violated.
- Is cheap (no per-PR API cost unless explicitly invoked).
- Is **not tied to a single vendor** — single-maintainer hobby projects
  shouldn't need a paid Anthropic / OpenAI account to get a second opinion.

## Decision

Split PR review into two complementary workflows:

1. **`.github/workflows/pr-lint.yml`** — deterministic, always-on, **blocks
   merge**. Runs shellcheck, actionlint, gitleaks, and a `tools/manifest.json`
   schema check on `ubuntu-latest`.
2. **`.github/workflows/ai-review.yml`** — LLM-driven, **opt-in**
   (triggered by `@ai review` / `@claude review` comment or `ai-review` /
   `claude-review` label), **advisory only**. Speaks the OpenAI-compatible
   chat completions API so it works with any provider:
   - OpenRouter (free tier with DeepSeek V3 / R1, Qwen Coder, Llama 3.3) —
     **the default**, requires only a free OpenRouter account.
   - DeepSeek direct, Groq, Together, Fireworks, OpenAI — drop-in via
     repo variables.
   - Ollama on a self-hosted runner — for fully-local review.

The architectural rules the model applies are encoded **once** in the
skill at `.claude/skills/pr-review/` (kept under `.claude/` because that
path is Claude's skill-discovery convention, not because the content is
Claude-specific):

- `SKILL.md` — procedure, boundaries, output format. Works in two modes:
  agentic (a local `claude` invocation drives tool calls itself) and
  single-turn (the CI workflow pre-loads diff + ADRs and calls the API
  once).
- `checklist.md` — per-axis rules with severity levels and ADR citations.

## Rationale

- **Provider-agnostic by design.** ADR-005 says single-maintainer audience;
  we shouldn't gate the review on a paid Anthropic key. OpenRouter's free
  tier costs $0 and covers reasonable PR volume; the workflow accepts any
  OpenAI-compatible endpoint as a swap-in.
- **Skill as shared prompt template, not vendor lock-in.** Putting the
  rules in `.claude/skills/pr-review/` means a human running `claude`
  locally on their branch gets the same procedure as CI. The CI workflow
  just reads the same Markdown and sends it to whichever LLM is
  configured.
- **Opt-in, not always-on.** Per ADR-005 audience and ADR-008 Renovate
  cadence, most PRs are version bumps to pinned packages. Running an LLM on
  every one of them is wasteful and adds noise. `@ai review` is one
  comment; `ai-review` label is one click.
- **Advisory, not blocking.** LLMs hallucinate, especially on a codebase
  this idiosyncratic. The blocking gate is the deterministic linters; the
  LLM is a second opinion on architecture, not an authority.
- **Cite, don't lecture.** Every finding must reference a CLAUDE.md rule
  or ADR number. Findings without citations are dropped. Keeps feedback
  grounded in the locked decisions and avoids the "LLM suggests random
  best practices" failure mode.
- **One comment per run.** The skill explicitly forbids drive-by line
  comments. A single consolidated review comment is the contract.

## Consequences

### Added

- `.github/workflows/pr-lint.yml` — shellcheck + actionlint + gitleaks +
  manifest schema. Blocks PRs.
- `.github/workflows/ai-review.yml` — invokes whichever LLM is configured
  on `@ai review` / `@claude review` or `ai-review` / `claude-review`
  label.
- `.claude/skills/pr-review/SKILL.md` — procedure, boundaries, output format.
- `.claude/skills/pr-review/checklist.md` — the rule body with severity
  levels and ADR citations.
- New secret required: `AI_REVIEW_API_KEY` (single secret regardless of
  provider).
- New repo variables (optional): `AI_REVIEW_API_URL`, `AI_REVIEW_MODEL`.

### Changed

- `docs/runbooks/release.md` references the new pipeline.

### Removed

- The originally-drafted `claude-review.yml` (superseded by
  `ai-review.yml`; the `claude-review` label remains as a trigger alias
  for back-compat).

## Configuration

| Setting | Type | Default | Notes |
|---|---|---|---|
| `AI_REVIEW_API_KEY` | secret | _(required)_ | API key for the chosen provider. |
| `AI_REVIEW_API_URL` | variable | `https://openrouter.ai/api/v1/chat/completions` | Any OpenAI-compatible endpoint. |
| `AI_REVIEW_MODEL` | variable | `deepseek/deepseek-chat-v3:free` | Model identifier in the provider's namespace. |

Provider quick-pick is in the header comment of
`.github/workflows/ai-review.yml`.

If the key is missing or revoked, the workflow fails closed (no review
posted) but no other CI is affected. PR merges aren't blocked.

## Boundaries

The skill is **read-only**:

- May read any file in the repo (in agentic mode) or whatever the workflow
  pre-loaded (single-turn mode).
- May call `gh pr {view,diff,review,comment}` and `git log|show|diff` in
  agentic mode only. In single-turn mode, the workflow does this.
- May not push commits, edit files, close issues, or modify state.
- Bounded to ~15 tool calls per run (agentic) or a single API call
  (single-turn).
- Never uses `gh pr review --approve` or `--request-changes`.

These constraints are stated in `SKILL.md § Boundaries` and reiterated in
the workflow's system-prompt assembly so they're load-bearing in both
invocation paths.

## Out of scope

- **Auto-fix.** The skill never proposes patches via `git apply`. If
  fixes are obvious, the human applies them in a follow-up commit.
- **Approving PRs.** Always advisory; merge approval remains human.
- **Security scanning of dependencies.** Renovate + Dependabot's security
  advisories cover that path; the skill doesn't try to replicate it.
- **Replacing the boot-smoke / wayland-session tests.** Those are the real
  gate (per CLAUDE.md § How to validate work); the AI review is a layer on
  top, not a substitute.

## Revisit when

- The audience expands beyond one maintainer (then the advisory/blocking
  split may need rebalancing — possibly turning some findings into
  blocking ones).
- The free-tier provider consistently rate-limits or produces low-quality
  output — switch the default in the workflow header (a doc-only change)
  or set `AI_REVIEW_API_URL` / `AI_REVIEW_MODEL` at the repo level.
- The skill consistently produces low-signal findings — tighten
  `checklist.md` or drop axes that aren't paying for themselves.
- A new locked decision is added — extend `checklist.md § Locked decisions`
  with the new ADR.

## See also

- ADR-008 — the surrounding release / CI pipeline this plugs into.
- `CLAUDE.md § Locked decisions` — the source of truth the skill cites.
- `.claude/skills/pr-review/SKILL.md` — implementation.
- `.github/workflows/ai-review.yml` — provider configuration and trigger logic.
