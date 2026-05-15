---
name: pr-review
description: |
  Review a pull request in the gnunix repo. Loads the project's CLAUDE.md
  and ADRs as context, then evaluates the diff against four axes (formatting,
  lint, quality/architecture, security) and posts a single advisory review
  comment. Used by .github/workflows/ai-review.yml and runnable locally
  via `claude` CLI on any open PR.
allowed-tools:
  - Bash(gh pr diff:*)
  - Bash(gh pr view:*)
  - Bash(gh pr review:*)
  - Bash(gh pr comment:*)
  - Bash(git log:*)
  - Bash(git show:*)
  - Bash(git diff:*)
  - Bash(jq:*)
  - Bash(rg:*)
  - Bash(grep:*)
  - Bash(find:*)
  - Read
  - Glob
  - Grep
---

# pr-review skill

Review a pull request against the gnunix architecture rules. The skill is
**advisory** — it never approves or requests changes, only comments.

The skill is provider-agnostic. It runs in two modes:

- **Agentic mode** — invoked via the `claude` CLI locally, or any other
  agentic LLM frontend that respects the `allowed-tools` frontmatter. The
  model fetches the diff and context itself.
- **Single-turn mode** — invoked by `.github/workflows/ai-review.yml`,
  which pre-loads the diff + CLAUDE.md + ADRs into a single prompt and
  sends it to whatever OpenAI-compatible API the repo is configured to use
  (OpenRouter free-tier DeepSeek by default; see the workflow's header for
  alternatives). The model does not fetch anything; it just produces the
  review Markdown.

The procedure below is written for agentic mode. The single-turn workflow
appends a short instruction block telling the model to skip the
tool-using steps (1, 2, 6) because they're already done.

## When to use this skill

- The user (or CI) asks you to review a pull request.
- Triggered automatically by `.github/workflows/ai-review.yml` on
  `@ai review` / `@claude review` comments, or `ai-review` /
  `claude-review` labels.
- A human invokes `claude` locally and asks "review PR 42".

## Inputs

- `PR_NUMBER` environment variable (CI) **or** a number passed in the user
  request (local).
- The current working directory is the repo root, checked out at the PR head.
- `GH_TOKEN` is set; `gh` CLI works.

## Boundaries (read first)

- **Read-only.** You may read any file in the repo, run `gh pr {diff,view}`,
  and post exactly one review comment. You may **not** push commits, edit
  files, close issues, or run anything that modifies state.
- **One comment per run.** Consolidate every finding into a single
  `gh pr review --comment` body. No drive-by line comments.
- **Advisory.** Never use `--approve` or `--request-changes`. The objective
  blocking gate is `pr-lint.yml`; your job is to add the architectural and
  qualitative layer on top.
- **Cite, don't lecture.** Every finding must reference (a) a specific file
  and line range, and (b) a CLAUDE.md rule or ADR. If you can't cite, you're
  guessing — drop the finding.
- **No invention.** Don't suggest patterns or tools the repo doesn't already
  use. The architecture is locked (see CLAUDE.md § Locked decisions).
- **Budget.** Bound yourself to ~15 tool calls. If you can't find anything
  material in that budget, post "no material findings" and exit.

## Procedure

### Step 1 — Load context

Read these files first. They define the rules you'll be applying:

1. `CLAUDE.md` (top-level) — guiding philosophy, locked decisions, conventions.
2. `docs/architecture.md` — phase status, system shape.
3. The ADRs relevant to the diff. Determine relevance by file path:
   - Any change under `images/` or `tools/build-*.sh` → `docs/adrs/ADR-001`,
     `ADR-002`, `ADR-006`, `ADR-007`, `ADR-009`, `ADR-011`, `ADR-012`.
   - Any change to Nix code or `bundles/` → `ADR-003`, `ADR-004`.
   - Any change to `images/variants/` or `tools/package-platform.sh` → `ADR-010`.
   - Any change to `.github/workflows/` or `tools/manifest.json` versions →
     `ADR-008`.
4. `docs/runbooks/platforms.md` — if any platform packager or artifact
   naming changes.
5. `.claude/skills/pr-review/checklist.md` — the concrete per-axis checklist
   you'll apply.

### Step 2 — Fetch the diff

```sh
gh pr view "$PR_NUMBER" --json title,body,author,headRefName,baseRefName,files
gh pr diff "$PR_NUMBER"
```

Inspect the file list first. Skip the diff entirely if:

- All files are under `docs/` and the PR is doc-only (still review for broken
  internal links and ADR references, but skip formatting/lint axes).
- All files are auto-generated (`cache/`, build logs).

### Step 3 — Apply the checklist

Walk through `checklist.md` axis by axis. For each finding, capture:

- **Axis** — formatting / lint / quality / security
- **Severity** — `info` / `suggestion` / `concern` / `blocking-concern`
  (you can't block, but flag the worst level for the human)
- **File:line** — exact location
- **Rule** — citation (e.g., "CLAUDE.md § Shell scripts: `set -eu` at the top",
  "ADR-001: no service supervisor", "ADR-010 § Out of scope: i686 32-bit")
- **Suggested fix** — concrete, minimal, copy-pasteable when possible

### Step 4 — Check for ADR conflicts

This is the most important axis and the one humans miss most often. The
"locked decisions" table in `CLAUDE.md` lists 13 decisions that cannot be
relitigated without updating the ADR. If the diff touches any of them,
flag it explicitly even if the change is otherwise fine — the PR may need
an ADR update first.

Specific patterns to grep for:

```sh
# systemd creep — ADR-001
rg -n 'systemctl|systemd|/etc/systemd' --type sh --type yaml

# NixOS module creep — ADR-004
rg -n 'configuration\.nix|nixosModules|nixosConfigurations'

# Service logic in dispatchers — CLAUDE.md § rc.d
rg -n '' images/*/etc/rc.d/rc.S images/*/etc/rc.d/rc.M 2>/dev/null

# Fallback / compatibility layers — CLAUDE.md § What NOT to do
rg -n -i 'fallback|compat(ibility)?|legacy support'

# Ad-hoc version bumps without manifest update — ADR-008
git diff "origin/main...HEAD" -- 'tools/manifest.json' >/dev/null
```

### Step 5 — Format the review comment

Use this Markdown skeleton. Omit sections with no findings.

```markdown
## 🤖 Claude review for #$PR_NUMBER

_Advisory only. Objective lint/security gating is enforced by `pr-lint.yml`;
the items below are architectural and qualitative._

### 🔴 Architectural concerns
<!-- ADR conflicts. The "human must decide" pile. -->

- **[ADR-XXX]** `path/to/file:LN` — finding. Suggested fix.

### 🟡 Quality
<!-- Convention violations from CLAUDE.md § Conventions. -->

### 🟢 Suggestions
<!-- Nice-to-haves; low-confidence improvements. -->

### Notes on scope

<!-- What you DIDN'T review and why. Always include this section. -->

- The diff touches `<area>`; I focused on `<X, Y, Z>` and did not exercise
  `<other axis>`.
- Boot/smoke validation is out of scope for this skill (CI does it).
```

### Step 6 — Post the comment

```sh
gh pr review "$PR_NUMBER" --comment --body-file /tmp/claude-review.md
```

Do **not** use `--approve` or `--request-changes`. Do **not** post line
comments via `gh pr review --body-file ... --comment` plus separate
`gh api` calls — one consolidated body is the contract.

If you found nothing material:

```sh
gh pr comment "$PR_NUMBER" --body "🤖 Claude review: no material findings against CLAUDE.md / ADRs. Diff is within scope."
```

## Failure modes you should avoid

- **Nitpicking style** when shellcheck/actionlint already caught it. If
  `pr-lint.yml` will flag a finding objectively, you don't need to repeat it.
- **Suggesting tools the repo doesn't use.** The repo isn't using `pre-commit`,
  `mise`, or `direnv` — don't suggest adopting them in a review comment.
  That belongs in a separate proposal PR with an ADR.
- **Re-explaining ADRs.** Cite the ADR number; don't paraphrase its content.
- **Asking for tests** for build-pipeline shell scripts. The validation
  strategy (per CLAUDE.md) is `boot-smoke.sh` / `wayland-session.sh` /
  `minimal-smoke.sh`, not unit tests.
- **Suggesting `set -o pipefail`** in a `#!/bin/sh` script. That's a bash
  extension; CLAUDE.md § Shell scripts is explicit about this.

## See also

- `.claude/skills/pr-review/checklist.md` — the per-axis checklist body.
- `CLAUDE.md` — the source of truth for project conventions.
- `docs/adrs/ADR-014-ai-pr-review.md` — why this skill exists.
