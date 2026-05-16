# CLAUDE.md — guidance for Claude Code when working in `.github/`

This file scopes how Claude Code (and any other AI assistant) should operate
on the GitHub-side automation under `.github/` — workflows, issue/PR
templates, label palette, Renovate config, and the actionlint allowlist.
It is *narrower* than the repo-root `CLAUDE.md`: it assumes that document's
locked decisions and project conventions already apply, and adds rules
specific to CI/CD changes.

Read the repo-root `CLAUDE.md` first. Then read this one. Then read the
relevant ADRs before touching anything load-bearing.

## 1. Where decisions about `.github/` are made

The shape of the CI/CD pipeline is **not** a free-floating engineering
choice. It is bound by ADRs. Before changing any workflow, check whether
your change touches a locked decision:

| ADR | What it locks for `.github/` |
|---|---|
| [ADR-005](../docs/adrs/ADR-005-audience.md) | Single-maintainer audience. CI must work for forks; no paid infra; no per-PR cost. |
| [ADR-008](../docs/adrs/ADR-008-renovate-and-release.md) | Renovate is the bump source. GitHub Releases is the artifact host. `tools/manifest.json:lfs_image_version` drives the release tag (auto-tagged by `tag-on-version-bump.yml`). Userland bumps auto-merge on green CI; base/toolchain bumps require human review. |
| [ADR-010](../docs/adrs/ADR-010-multi-arch-and-platforms.md) | The CI matrix axis is `(arch, image, platform)`. Active arch is `aarch64`; x86_64 is scaffolded. |
| [ADR-014](../docs/adrs/ADR-014-ai-pr-review.md) | Two-workflow split: `pr-lint.yml` (deterministic, **blocks**) vs `ai-review.yml` (advisory, **opt-in**, provider-agnostic via OpenAI-compatible API). |
| [ADR-016](../docs/adrs/ADR-016-ci-split-build-and-validation.md) | Routine CI runs on free hosted `ubuntu-22.04-arm` with qemu+KVM. `gnunix-base` rebuilds happen on a developer's Mac and ship as release artifacts that CI fetches. |
| [ADR-018](../docs/adrs/ADR-018-artifact-taxonomy.md) | Artifact naming grammar: `gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>`. Three forms: `.img.zst`, `.iso`, `.tart.zst`. `gnunix-minimal` is the release-dependency anchor. |
| [ADR-021](../docs/adrs/ADR-021-no-self-hosted-runners.md) | **No self-hosted runners.** Ever. Every job in this repo runs on free hosted runners. `actionlint`'s `self-hosted-runner:` block exists only to catalogue hosted-runner labels the pinned actionlint version doesn't know yet — never to allow real self-hosted labels. |

If your proposed change conflicts with any of these, **stop** and write
an ADR (or amend an existing one) before editing the workflow.

## 2. Inventory: what lives in `.github/`

Treat this as a map. Before adding a new file here, check whether the
concern already has a home.

```
.github/
├── CLAUDE.md                      ← this file
├── PULL_REQUEST_TEMPLATE.md       PR checklist (ties to CLAUDE.md § locked decisions)
├── actionlint.yaml                Hosted-runner label allowlist (per ADR-021)
├── labeler.yml                    Path-based PR labels (consumed by pr-labeler.yml)
├── labels.yml                     Label palette — single source of truth
├── renovate.json5                 Renovate config (per ADR-008)
├── ISSUE_TEMPLATE/
│   ├── adr_proposal.yml           Use for load-bearing decisions
│   ├── bug_report.yml             Layered by image / runbook references
│   ├── config.yml                 Disables blank issues; routes off-topic
│   ├── documentation.yml          Doc-only issues
│   ├── feature_request.yml        Non-architectural enhancements
│   └── question.yml               Questions that may produce doc updates
└── workflows/
    ├── ai-review.yml              Opt-in LLM review (ADR-014)
    ├── build.yml                  Image build + smoke + package (ADR-016, ADR-018)
    ├── labels-sync.yml            Reconciles GitHub labels with labels.yml
    ├── pr-labeler.yml             Applies labeler.yml to PRs
    ├── pr-lint.yml                Blocking lint (shellcheck/actionlint/gitleaks/manifest)
    ├── release.yml                Draft GitHub Release on v* tag (ADR-008, ADR-018)
    └── tag-on-version-bump.yml    Auto-tags vX.Y.Z on manifest bump (ADR-008)
```

## 3. Operating rules for Claude Code

### 3.1. Read before writing

Before editing any workflow, **read the file end-to-end**. The header
comment of every workflow in this repo is load-bearing: it explains the
ADR it implements, why the trigger/concurrency/permissions shape is what
it is, and what its inputs/outputs are. If the header doesn't answer your
question, read the referenced ADR. Do not infer the design from the job
names alone.

### 3.2. Don't repeat yourself across workflows

Three recurring patterns must not be duplicated:

1. **Runner labels.** Use `ubuntu-22.04-arm` for anything that benefits
   from arm64 (build, smoke tests, image work). Use `ubuntu-latest`
   only for arch-agnostic lint/release-assembly. Never write
   `[self-hosted, ...]` — ADR-021 forbids it; actionlint's allowlist
   does not cover that case and the workflow will fail lint.
2. **Permissions.** Every workflow declares `permissions:` at the top
   level explicitly. Default to `contents: read`; add specific scopes
   per job (`pull-requests: write`, `issues: write`, `contents: write`)
   only when the job actually needs them. Never set
   `permissions: write-all`.
3. **Concurrency.** Every workflow declares a `concurrency:` group.
   Per-PR/per-ref groups (`<workflow>-${{ github.ref }}` or
   `${{ github.event.pull_request.number }}`) with
   `cancel-in-progress: true` for cheap workflows; `cancel-in-progress:
   false` for workflows that mutate external state (release.yml,
   labels-sync.yml, tag-on-version-bump.yml).

If you find yourself copy-pasting more than ~10 lines between workflows,
stop and extract:

- Shared shell logic into `scripts/lint/*.sh` or `tools/*.sh` and call
  it from the workflow (per `pr-lint.yml`'s `manifest-schema` job —
  the predicate lives in `scripts/lint/manifest-schema.sh`).
- Shared workflow logic into a **reusable workflow**
  (`workflow_call`-triggered) under `.github/workflows/_*.yml`. Name
  reusable workflows with a leading underscore so the inventory above
  stays scannable.
- **Never** factor shared logic into a composite action checked into
  this repo just to avoid one copy — the indirection costs more than
  it saves at this scale.

### 3.3. Pin everything

- **Actions:** pin to a major version tag (`@v4`, `@v5`) for first-party
  GitHub actions, and to a specific SHA for any third-party action that
  Renovate doesn't manage. Never `@main`, never `@master`.
- **Installer scripts** (e.g., `download-actionlint.bash`): pin the
  release in the URL **and** pass the version as an argument so the
  script can't drift. See `pr-lint.yml`'s actionlint install step.
- **Renovate** manages action-version bumps automatically; do not
  hand-edit `@vN` pins unless reverting a Renovate bump.
- Per [ADR-008](../docs/adrs/ADR-008-renovate-and-release.md), any
  pinned-version change goes in its own commit so revert is cheap.

### 3.4. Triggers — minimum viable

Every `on:` block should be the **smallest** set of triggers that does
the job. Specifically:

- `pull_request` for read-only jobs that validate the PR.
- `pull_request_target` **only** when the workflow legitimately needs
  write access to PR metadata (labeler, ai-review). When using it,
  the workflow MUST NOT check out and execute PR code (`labeler@v5`
  reads the diff via the API; `ai-review.yml` checks out
  `refs/pull/<n>/head` but only feeds it to an LLM, never executes it).
- `push: branches: [main]` for main-branch validation and side-effects
  (labels-sync, tag-on-version-bump).
- `push: tags: ['v*']` for release publishing.
- `merge_group` — required for jobs in the GitHub Merge Queue's
  `required_status_checks` list. Currently only `pr-lint.yml` carries
  this; add it to any new check that the ruleset requires.
- `workflow_dispatch` — always provide as a manual escape hatch on
  workflows that touch external state (release, labels-sync,
  tag-on-version-bump). Document the inputs in the workflow header.
- `paths:` filters — use for workflows whose work is gated on specific
  files (labels-sync watches `labels.yml`; tag-on-version-bump watches
  `tools/manifest.json`). Do NOT add paths filters to `pr-lint.yml`
  or `build.yml` — they apply to the whole repo by design.

Avoid `schedule:` (cron) triggers unless an ADR justifies them. Cron
runs cost CI minutes for forks and obscure failure modes; prefer
event-driven triggers.

### 3.5. Secrets and variables

- Secrets in workflow files are referenced as
  `${{ secrets.NAME }}`. Variables as `${{ vars.NAME }}`. The
  difference matters: variables are visible in logs and to forks;
  secrets are not.
- A new secret requires a header comment in the workflow that documents
  its name, what it's for, and which provider/scope it needs (see
  `ai-review.yml`'s header for the canonical example).
- Never log a secret. Never echo `$GH_TOKEN`. Workflows that need to
  surface auth failures should print only the HTTP code and a
  sanitised error body.
- Workflows must **fail closed** if a required secret is missing —
  emit `::error title=...` with a clear remediation step (see
  `ai-review.yml`'s "Sanity check — API key is configured" step).
  Do not silently skip work.

### 3.6. Shell hygiene

Inline `run:` blocks are shell scripts and obey the project's bash
conventions (per repo-root CLAUDE.md):

- `set -eu` at minimum; `set -euo pipefail` if you use pipes.
- Use `${{ ... }}` to interpolate workflow context **only** into
  environment variables at the top of the step (`env:` block); reference
  them as `$VAR` inside the script. Never inline `${{ ... }}` into the
  middle of a shell heredoc — it makes shellcheck/actionlint blind to
  injection risks.
- All inline shell must pass actionlint's embedded shellcheck at
  `SHELLCHECK_OPTS=-S warning` (matches the standalone shellcheck job).
- Use `gh` CLI for GitHub API calls; the token is available as
  `${{ secrets.GITHUB_TOKEN }}` and exposed via `env: GH_TOKEN`.
- For non-trivial logic (>~30 lines or any control flow), move the
  script under `scripts/lint/` or `tools/` and call it from the
  workflow. Keeps workflows readable and lets the same logic run via
  pre-commit locally.

### 3.7. Permissions least-privilege checklist

When adding or editing a workflow, walk this list:

1. Top-level `permissions:` block is present.
2. Default is `contents: read`.
3. Each scope above `read` is justified by a concrete API call in the
   workflow (e.g., `pull-requests: write` → `gh pr review` /
   `gh pr comment`).
4. `actions: read` only when the workflow downloads another workflow's
   artifacts (`release.yml`).
5. `id-token: write` only if invoking OIDC. None of our workflows do
   today.

### 3.8. Concurrency — what to set

- `group:` is per-resource-being-mutated, not per-workflow. Examples:
  - `pr-lint-${{ github.ref }}` — one in flight per branch.
  - `ai-review-${{ github.event.pull_request.number || github.event.issue.number }}` — one in flight per PR.
  - `release-${{ github.ref }}` — one per tag.
  - `tag-on-version-bump` — singleton; manifest mutations serialise.
  - `labels-sync` — singleton; label reconciliation serialises.
- `cancel-in-progress: true` for validators; `false` for mutators.

### 3.9. Failure modes — design for them

Every workflow that talks to the outside world (API, registry, LLM,
Renovate datasource) must:

- Set `timeout-minutes:` per job. Use the smallest realistic value.
  Lint jobs ≤ 5 min; release assembly ≤ 30 min; long-poll jobs (like
  release.yml's "wait for build run") have explicit in-script deadlines
  rather than relying on the job timeout alone.
- Distinguish "fail closed" (missing secret, malformed config) from
  "fail open" (advisory work that should never block merge). The
  `ai-review.yml` workflow is the reference for fail-closed (no key →
  job fails with a clear error); per ADR-014 its **finding output** is
  always advisory regardless of job conclusion.
- Use `if: always()` for cleanup / metadata-collection steps so a
  build failure still ships logs and artifacts for triage.

## 4. Specific guidance per workflow

### `pr-lint.yml`

- Blocking by design. Anything deterministic and fast belongs here.
- Subjective / architectural feedback does **not** belong here; that's
  `ai-review.yml`'s job. Splitting them is locked by ADR-014.
- When adding a new linter, add it as a separate job (parallelism) and
  include it in the Merge Queue's `required_status_checks` ruleset.
- Linter version pins live in the workflow itself and are Renovate-
  managed via the regex manager in `.github/renovate.json5`. When
  upgrading a linter's `-S` threshold or rule set, document the
  reason in the step's `name:` or a comment.

### `ai-review.yml`

- Per ADR-014: provider-agnostic, OpenAI-compatible API.
- The skill at `.claude/skills/pr-review/` is the source of truth for
  procedure and checklist. Do not duplicate the rules into the workflow
  — assemble them at runtime (the workflow does this in the "Assemble
  prompt" step).
- Opt-in only. Do not change the trigger model to "every PR" without an
  ADR amendment. The triggers accept `@ai review`, `@claude review`,
  and the `ai-review` / `claude-review` labels — keep all four for
  back-compat unless an ADR retires the legacy aliases.
- Advisory only. Never use `gh pr review --approve` or
  `--request-changes` from this workflow.
- New providers go in the header comment's "Provider quick-pick"
  table only; the workflow code is provider-agnostic and should not
  branch on `AI_REVIEW_API_URL`.

### `build.yml`

- Per ADR-016 + ADR-021: hosted arm64 runners only
  (`ubuntu-22.04-arm`). qemu+KVM is the VM driver on Linux
  (see `scripts/vm-helpers.sh` and `scripts/qemu-helpers.sh`).
- The matrix axis is `(image, arch, platform)` per ADR-010; today
  `arch=aarch64` and `platform=generic-uefi` are the only shipping
  rows.
- Artifact names follow ADR-018's grammar:
  `gnunix-<image>-<arch>[-<platform>]-<ver>.<ext>`. Never reintroduce
  the legacy `gnunix-<image>-disk-<ver>.img.zst` form.
- Retention: `retention-days: ${{ github.event_name == 'pull_request' && 3 || (startsWith(github.ref, 'refs/tags/v') && 90 || 30) }}`.
  Use this expression verbatim for every artifact upload so retention
  is consistent across the matrix.
- `gnunix-base` is `workflow_dispatch`-only (per ADR-016). Downstream
  jobs fetch it via `tools/fetch-image.sh` from a GH Release. Do not
  reintroduce it as a PR-gated job without ADR change.

### `release.yml`

- Per ADR-008 + ADR-018: drafts a GitHub Release on `v*` tag.
- **Drafts only.** A human clicks Publish. Do not change this without
  an ADR — auto-publish is one Renovate misfire away from shipping
  broken bits.
- Asset globs cover `.img.zst`, `.iso`, and (when ADR-018's
  `.tart.zst` form ships) `.tart.zst`. Always emit `SHA256SUMS` over
  every disk image in the release.
- The release body's image × form table is the user-facing surface
  of ADR-018. Update it in lockstep with any change to which forms
  an image ships.

### `tag-on-version-bump.yml`

- Per ADR-008: the manifest is the source of truth for the release
  version. Do not let a workflow elsewhere push tags directly — they
  must flow through this workflow (or a `workflow_dispatch` of it
  with explicit `version:` input).
- Refuse to overwrite existing tags. The current implementation
  checks `git ls-remote --tags --exit-code` before tagging; preserve
  that guard.

### `labels-sync.yml` and `pr-labeler.yml` (with `labels.yml` + `labeler.yml`)

- `labels.yml` is the **single source of truth** for the label palette.
  Do not edit labels via the GitHub UI; they will be reconciled away
  on the next push to main.
- `pr-labeler.yml` uses `pull_request_target` for write access; the
  job reads the diff via the API and never executes PR code. Do not
  add any `run:` step that touches PR files.
- `delete-other-labels` defaults to `false`. Only flip via
  `workflow_dispatch` when intentionally pruning, and only after
  confirming `labels.yml` covers every label currently in use.
- When adding a new area, follow the three-family convention
  (`type/`, `area/`, `status/`) from `labels.yml`'s header. Don't
  invent new families.

### `actionlint.yaml`

- The `self-hosted-runner:` key is misleadingly named; it's the
  bucket for **any custom runner label**, not just self-hosted ones.
  Per ADR-021 we use it **only** for free hosted runner labels that
  the pinned actionlint version doesn't catalogue yet
  (e.g., `ubuntu-22.04-arm`).
- If a real self-hosted label (`[self-hosted, ...]`) ever lands here,
  that's a regression against ADR-021. Remove it (or write an ADR
  superseding ADR-021).
- Bump the actionlint version pin in `pr-lint.yml` first; only add a
  new hosted-runner label here after confirming the newer actionlint
  still doesn't know it.

### `renovate.json5`

- Per ADR-008: userland auto-merges; base/toolchain bumps require
  human review. The `packageRules:` blocks codify the two lanes —
  do not move a base/toolchain package (kernel, glibc, gcc, binutils,
  sysvinit, eudev, dbus, elogind, GRUB, perl, python) into the
  userland auto-merge list without an ADR.
- Custom regex managers are required for `tools/manifest.json` —
  Renovate's standard JSON manager doesn't understand our shape.
  When adding a new pin site, add a regex manager rather than
  changing the manifest's shape.
- Schedule and PR limits balance "stay current" against "don't drown
  the maintainer". Don't increase `prHourlyLimit` or
  `prConcurrentLimit` without a concrete need.

### Issue and PR templates

- `config.yml` disables blank issues; do not re-enable. The contact
  links route off-topic traffic to Discussions and security
  advisories — both endorsed by repo-root CLAUDE.md and CONTRIBUTING.md.
- Each template's prose mirrors a section of the repo-root
  documentation (CLAUDE.md, runbooks, ADRs). When that documentation
  changes, update the template prose in the same PR — drift between
  template guidance and source docs is a documentation bug.
- The PR template's "Locked-decisions check" must list the same ADRs
  as repo-root CLAUDE.md's "Locked decisions" table. Adding an ADR
  to the table → update the PR template in the same PR.

## 5. Adding a new workflow — checklist

Before opening a PR that adds a workflow under `.github/workflows/`:

1. Have you read every existing workflow in this directory? If yes,
   does the new workflow duplicate logic from one of them? If so,
   refactor instead of adding.
2. Does the new workflow implement a locked decision (ADR)? Cite the
   ADR number in the workflow's header comment.
3. Is it advisory or blocking? Advisory workflows must say so in the
   header and never use `--approve` / `--request-changes` / branch-
   protection-bypassing operations.
4. Does it run on a free hosted runner (`ubuntu-latest`,
   `ubuntu-22.04-arm`)? If you need anything else, you need an ADR
   amendment to ADR-021 first.
5. Does it have `permissions:` (least-privilege),
   `concurrency:` (correctly grouped), `timeout-minutes:` per job?
6. Is every action pinned? Are inline scripts shellcheck-clean at
   `-S warning`?
7. Does it `fail closed` on missing config and `fail open` on
   transient outages of advisory services?
8. Is its name listed in CLAUDE.md's `.github/` inventory? Add it
   here and to repo-root CLAUDE.md if it's load-bearing.
9. Does the Merge Queue ruleset need a new `required_status_checks`
   entry? If yes, plan the change to the ruleset (it's GitHub-side
   config, not in this repo) and note it in the PR description.
10. Have you run `actionlint` locally against the new file?
    (`./actionlint .github/workflows/<new>.yml`)

## 6. What not to do

- Don't add cron-scheduled workflows. They cost CI minutes for forks
  and create obscure failure modes (token-rotation drift, secret
  rotation drift). Event-driven only.
- Don't add a self-hosted runner anywhere. ADR-021. No exceptions.
- Don't add a workflow that pushes commits to `main` or any protected
  branch. The two workflows that mutate refs (`tag-on-version-bump.yml`,
  `release.yml`) push tags only, never branches.
- Don't merge "lint config" into `pr-lint.yml`'s job definitions —
  config (rule excludes, severity) lives in the called scripts /
  config files (`actionlint.yaml`, `scripts/lint/*.sh`).
- Don't change a workflow's trigger model to "every PR" / "every push"
  for a workflow currently opt-in (e.g., `ai-review.yml`). The
  opt-in design is locked by ADR-014.
- Don't downgrade `permissions:` to `write-all` for convenience.
  If a step needs a scope, declare it.
- Don't paste a Renovate config example from the internet into
  `renovate.json5` without checking that ADR-008's two-lane policy
  (userland auto-merge vs base human-review) is preserved.
- Don't bypass the PR template's "Locked-decisions check" — if your
  workflow change touches an ADR, say so in the PR.

## 7. Where to ask

- Question about the **shape** of a workflow → re-read the workflow's
  header comment and the ADR it cites. If still unclear, open a
  `documentation.yml` issue against the workflow.
- Question about whether a change is in scope → open a
  `feature_request.yml` issue if non-architectural; an
  `adr_proposal.yml` if load-bearing.
- Security concern in CI (token misuse, sandbox escape) → use the
  private security advisory link in `ISSUE_TEMPLATE/config.yml`.
