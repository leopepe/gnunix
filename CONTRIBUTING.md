# Contributing to GNUnix

Thanks for thinking about contributing. GNUnix is a small, opinionated
distribution; the architecture is documented and most "should we do X?"
questions have an answer already. That makes contributing easier, not
harder — read the notes, pick an issue, send a PR.

## Who can contribute

**Anyone.** There's no contributor agreement to sign, no "core team" you
have to join. If you can read the rules below and you're willing to follow
them, your patch is welcome.

## Before you start

Read these in order. Each is short:

1. [`README.md`](README.md) — what GNUnix is and isn't.
2. [`CLAUDE.md`](CLAUDE.md) — the project's load-bearing philosophy:
   *"static base, dynamic userland"*, *"no policy in PID 1"*, *"boring base,
   declarative top"*. Also the **locked decisions** table (13 ADRs that
   cannot be relitigated without updating the ADR itself).
3. [`docs/architecture.md`](docs/architecture.md) — phase status and the
   two-layer model.
4. The ADRs in [`docs/adrs/`](docs/adrs/) that are relevant to your area.
   You don't need to read all 14; the table in `CLAUDE.md` tells you which
   ADR governs each topic.
5. The runbook for your area in [`docs/runbooks/`](docs/runbooks/) (build,
   build-nix, build-wayland, platforms, release, test-image).

If a task seems to require violating a locked decision, **don't silently
work around it** — open an issue first and surface the conflict. We'd
rather update an ADR than ship inconsistent code.

## Finding work

- **Browse open issues** at [the Issues tab](../../issues). Issues tagged
  `good-first-issue` are designed for someone new to the codebase.
- **Check [`docs/TODO.md`](docs/TODO.md)** for larger work items grouped
  by topic (hardening, platforms, Phase 4 follow-ups, etc.).
- **Read [`runbook.md`](runbook.md)** for the phase status — what's
  shipping, scaffolded, or planned. Scaffolded work is a productive place
  to start.
- **Don't have a specific issue in mind?** Open one describing what you
  want to do *before* writing the code. A 5-minute conversation can save a
  rewrite.

## Local development

You'll need a macOS Apple Silicon host with `tart`, `jq`, `rsync`, `ssh`,
`expect`, and `zstd`. The full setup is in
[`docs/runbooks/build.md`](docs/runbooks/build.md).

For changes that don't need a full image rebuild (documentation, CI
workflows, small script edits), `ubuntu-latest` in CI is enough — no local
build required.

### Pre-commit hooks (recommended)

The repo ships a `.pre-commit-config.yaml` that mirrors every check in
`.github/workflows/pr-lint.yml`: `shellcheck`, `actionlint`, `gitleaks`,
the `tools/manifest.json` schema validator, plus basic file hygiene.
Installing it locally means the deterministic checks that gate every PR
fail at `git commit` time instead of in CI:

```sh
pipx install pre-commit          # or: brew install pre-commit / nix-env -iA nixpkgs.pre-commit
pre-commit install               # registers .git/hooks/pre-commit (one-time per checkout)
```

After install, every `git commit` runs the changed-files subset of the
hooks. To run the full set the way CI does:

```sh
pre-commit run --all-files
```

The hook config keeps strict parity with `pr-lint.yml`. If you bump a
linter version or change a severity flag in either file, change it in
the other in the same PR. Shared inline pieces:

- `.shellcheckrc` — the disable-list + external-sources, read by both
  standalone shellcheck *and* actionlint's embedded shellcheck.
- `scripts/lint/manifest-schema.sh` — the manifest predicates, called
  from both the pre-commit hook and (in a future PR) `pr-lint.yml`.
- `scripts/lint/actionlint.sh` — a thin wrapper that sets
  `SHELLCHECK_OPTS=-S warning` before exec'ing actionlint, since
  pre-commit's hook schema has no `env:` key.

## Submitting a pull request

### 1. Branch and code

- Branch from `main`. Keep the branch focused on one change.
- Match the file-placement conventions in `CLAUDE.md § Where things go`.
  In short: image-specific config under `images/<name>/`, reusable Nix
  under `bundles/`, multi-image orchestration under `tools/`, one-shot
  helpers under `scripts/`, tests under `tests/`. "Why we chose X" goes in
  a new `docs/adrs/ADR-NNN.md`.
- Match the shell conventions in `CLAUDE.md § Shell scripts`:
  `#!/bin/sh` (with `set -eu`) for portable scripts; `bash` only when you
  actually use bash features. No silent `cd` — use absolute paths or
  compute `REPO_ROOT`.
- Don't bump pinned versions opportunistically. Version bumps are their
  own commits, gated by [ADR-008](docs/adrs/ADR-008-renovate-and-release.md).
  Renovate handles most of them automatically.

### 2. Write or update an ADR if you're proposing a load-bearing decision

If your change introduces a new dependency, replaces an existing
component, alters the build pipeline shape, or sets a precedent other
contributors will follow, it needs an ADR. Use the existing ADRs as
templates — they're all short, structured, and to the point. Reference
the new ADR number from any code comment that needs the rationale.

### 3. Open the PR

Follow the [pull request template](.github/PULL_REQUEST_TEMPLATE.md). It
asks for:

- Summary of the change
- Why (link to the issue, ADR, or runbook)
- How you validated it (the smoke tests are the real gate — see
  `CLAUDE.md § How to validate work`)
- Whether you touched any locked decision

### 4. CI runs automatically

Two PR checks run on every push to your branch:

- **`PR lint`** (blocking) — shellcheck, actionlint, gitleaks,
  `manifest.json` schema. If this fails, fix the findings and push again.
- **`Build images`** (blocking when reachable) — full image rebuild and
  smoke-test on a macOS arm64 Tart runner. Slow (~hours for `gnunix-base`).
  Skips for doc-only PRs.

Optionally, you (or a maintainer) can request an advisory architectural
review from an LLM:

- Comment **`@ai review`** (or `@claude review`) on the PR, or
- Apply the **`ai-review`** (or `claude-review`) label.

The review is provider-agnostic — the repo defaults to OpenRouter's free
tier (DeepSeek V3) but works with any OpenAI-compatible API (DeepSeek
direct, Groq, Together, Ollama on a self-hosted runner, OpenAI, etc.).
The model cites the specific CLAUDE.md rules / ADRs it thinks your change
touches. It never blocks merge — the maintainer makes the call. See
[ADR-014](docs/adrs/ADR-014-ai-pr-review.md) for the design and
[`.github/workflows/ai-review.yml`](.github/workflows/ai-review.yml) for
provider configuration.

### 5. Iterate

- Respond to review comments either by pushing a fix or by explaining why
  you disagree. Both are fine.
- Force-pushes to your branch are OK; we squash on merge.
- If a maintainer asks for an ADR update, do it in the same PR.

## What we don't accept

Per `CLAUDE.md § What NOT to do`:

- **`systemd`** anywhere, even "just for one service". Init-system decision
  is in [ADR-001](docs/adrs/ADR-001-init-system.md).
- **NixOS modules** (`configuration.nix`, `nixosModules`). User-visible
  config goes through home-manager; system-level config goes in `rc.d`
  scripts. See [ADR-004](docs/adrs/ADR-004-config-style.md).
- **"Fallback" or "compatibility" layers** for hypothetical future
  requirements. We ship for one target audience (ADR-005); if the audience
  expands, we'll write code then.
- **Opportunistic version bumps.** Each bump is its own commit and goes
  through Renovate or a deliberate PR.
- **README/CLAUDE.md/doc rewrites** that aren't asked for. If a doc is
  factually wrong, fix the fact; don't restructure for style.

## Code of conduct

We keep this short on purpose.

**Be respectful, in every interaction.**

- Critique code, not people. "This script has a race condition" is fine;
  "this is a stupid script" is not.
- Assume good faith. New contributors don't know the conventions yet —
  that's the entire point of CONTRIBUTING.md. Point them at the relevant
  section instead of dunking.
- Disagreement is welcome; sourness is not. If a PR review thread is
  spiraling, take it to an issue or close the PR with a polite explanation
  and reopen later. We don't argue people into agreement.
- No "funny" comments at someone else's expense. Inside-jokes that exclude
  newcomers, sarcasm targeting a contributor, snark about "obvious"
  mistakes — none of it lands the way you think it does.
- No harassment, no discrimination, no off-topic personal attacks. Zero
  tolerance, single warning, then a permanent ban from the repo. We don't
  litigate the boundary in public; the maintainer's judgment is final.

Disagreements about *technical direction* go through the ADR process.
Disagreements about *conduct* go to the maintainer privately
(open a confidential issue or email — see repo settings for the current
maintainer contact). We will not adjudicate conduct disputes in PR
threads.

## License

By contributing, you agree that your contribution is licensed under the
[LICENSE](LICENSE) at the root of this repository — **BSD 2-Clause**
(SPDX: `BSD-2-Clause`), the OSI-canonical "Simplified BSD" text. See
[`NOTICE.md`](NOTICE.md) for what the LICENSE covers (the GNUnix-authored
glue) versus what it does not (upstream software like the Linux kernel,
glibc, GRUB, Nix, nixpkgs, etc., each of which keeps its own upstream
license). No CLA, no copyright assignment — your commit metadata is your
attribution.

## Questions

- Architecture questions → open an issue with the `question` label.
- Bug reports → open an issue with steps to reproduce.
- Security concerns → see the maintainer contact in repo settings; do not
  open a public issue for security-sensitive findings.

Thanks for reading this far. Now go pick an issue.
