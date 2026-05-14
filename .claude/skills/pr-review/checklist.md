# pr-review checklist

Concrete per-axis checks. Walked by `SKILL.md` step 3.

Severity legend: `info` (FYI) / `suggestion` (consider it) / `concern`
(should fix before merge) / `blocking-concern` (don't merge until resolved
by the maintainer — advisory only; you can't actually block).

## Axis 1 — Formatting

The objective formatting pass lives in `pr-lint.yml`. Your job here is to
catch what the linters miss.

| Check | Severity if violated | Rule |
|---|---|---|
| Shell script has shebang on line 1 | `concern` | CLAUDE.md § Shell scripts |
| Shebang matches the actual shell features used (no bashisms under `#!/bin/sh`) | `concern` | CLAUDE.md § Shell scripts |
| `set -eu` (or `set -euo pipefail` for bash) at top | `concern` | CLAUDE.md § Shell scripts |
| Indentation consistent within the file (2 or 4 spaces, no tabs in shell) | `suggestion` | CLAUDE.md § Shell scripts |
| Workflow YAML has top-of-file comment explaining purpose | `suggestion` | Existing convention (see `build.yml`, `release.yml`) |

## Axis 2 — Lint (semantic)

Things shellcheck/actionlint can't catch.

| Check | Severity | Rule |
|---|---|---|
| New file under `images/` matches the image directory it belongs to (no cross-image config) | `concern` | CLAUDE.md § Where things go |
| New reusable Nix expression is in `bundles/`, not duplicated per-image | `concern` | CLAUDE.md § Where things go |
| New one-shot helper is in `scripts/`; reusable pipeline tool is in `tools/` | `suggestion` | CLAUDE.md § Where things go |
| `bundles/*.nix` is a pure function of `pkgs` (no side effects, no top-level reads) | `concern` | CLAUDE.md § Nix |
| Pinned version (`tools/manifest.json`, `bundles/*.nix`, image `build.sh`) bumped in its own commit | `suggestion` | CLAUDE.md § What NOT to do |
| Each `rc.<service>` script enables/disables exactly one service | `concern` | CLAUDE.md § rc.d scripts |
| `rc.S` / `rc.M` is a dispatcher — no service logic inlined | `blocking-concern` | CLAUDE.md § rc.d scripts |
| New shell script uses absolute paths or computes `REPO_ROOT` properly (no silent `cd`) | `concern` | CLAUDE.md § Shell scripts |
| New test in `tests/` exits non-zero on failure with a one-line reason | `concern` | CLAUDE.md § Shell scripts |

## Axis 3 — Quality (architecture)

The expensive axis. Worth the budget.

### Locked decisions (CLAUDE.md table)

Flag any of these as `blocking-concern` and reference the ADR:

| Pattern in diff | ADR violated |
|---|---|
| `systemctl`, `systemd-` binary calls, `*.service` units, `/etc/systemd/` | ADR-001 |
| `seatd`, `systemd-logind` | ADR-002 |
| Single-user Nix install, removing `nixbld*` users | ADR-003 |
| `configuration.nix`, `nixosModules`, flakes-as-system | ADR-004 |
| Server-targeted defaults (no graphical, no Nix daemon) | ADR-005 |
| `systemd-boot`, `rEFInd` config | ADR-006 |
| x86_64 base build path that doesn't go via `archs.x86_64` | ADR-007 |
| Skipping pinning, floating `latest` refs | ADR-008 |
| GNOME, gnome-session, X11-only WM | ADR-009 |
| i686 / 32-bit anywhere | ADR-010 § Out of scope |
| `-fstack-protector-all`, blanket `-Werror`, disabling `_FORTIFY_SOURCE` | ADR-011 |
| Monolithic kernel `=y` everywhere, initramfs introduction | ADR-012 |
| New project / image name not derived from `gnunix` | ADR-013 |

### Architectural smells

| Smell | Severity | Why |
|---|---|---|
| New "fallback" or "compatibility" code path for hypothetical future requirements | `concern` | CLAUDE.md § What NOT to do |
| Code comment that re-explains an ADR's rationale | `suggestion` | CLAUDE.md § Where things go: "Code comments reference the ADR number; they do not re-explain." |
| Image-specific config placed outside its `images/<name>/` directory | `concern` | CLAUDE.md § Where things go |
| Multi-image orchestration outside `tools/` | `suggestion` | CLAUDE.md § Where things go |
| New service supervisor / pid1-like daemon | `blocking-concern` | ADR-001: no policy in PID 1 |
| New "policy in PID 1" code in `rc.S` (e.g., conditional service starts based on hardware) | `blocking-concern` | CLAUDE.md § Guiding philosophy |
| Anything that pushes user-facing config into the static base instead of home-manager / nix | `concern` | CLAUDE.md § Guiding philosophy: "boring base, declarative top" |

### Manifest hygiene

| Check | Severity |
|---|---|
| Bump to a base-layer pin (kernel, glibc, binutils, gcc, sysvinit, eudev, dbus, elogind, GRUB) lacks a human-reviewer note | `concern` (per ADR-008: human review required) |
| New entry has `sha256: ""` and isn't accompanied by a fetch-sources update | `concern` |
| `active_arch` changed but downstream stages weren't audited | `blocking-concern` |
| New platform added to `platforms` but no `images/variants/<name>/package.sh` exists | `concern` |
| `lfs_image_version` bumped without corresponding artifact/runbook updates | `suggestion` (the auto-tag workflow handles tagging; just confirm it's intentional) |

### Platform matrix (ADR-010 / platforms.md)

| Check | Severity |
|---|---|
| New `package.sh` exits 0 without producing the expected artifact path | `concern` |
| Scaffolded packager (`rpi-native`, `nuc-installer`) flipped to "shipping" without manifest updates (`kernel_has_bcm_drivers`, x86_64 nix_binary_sha256) | `blocking-concern` |
| Artifact naming deviates from `<image>-<platform>-<arch>-<ver>.{img.zst,iso}` | `concern` |
| `.github/workflows/build.yml` matrix updated without matching `tools/manifest.json:platforms` entry | `concern` |

## Axis 4 — Security

Both gitleaks and shellcheck catch a lot here; focus on what they can't.

| Check | Severity | Rule |
|---|---|---|
| `curl ... \| sh` (or wget/fetch piped) without sha256 verification | `blocking-concern` | ADR-008 § "Pin everything." Also `docs/TODO.md § Supply chain` |
| New external download URL without a matching `sha256` field in manifest.json | `concern` | ADR-008 |
| Hardcoded credentials, API tokens, SSH keys, certificates | `blocking-concern` | (Gitleaks should catch; double-check) |
| New `ssh` invocation without `StrictHostKeyChecking` policy | `suggestion` | Existing pattern in `scripts/tart-helpers.sh` |
| New world-writable file mode (`chmod 777`, `0666`) | `concern` | CLAUDE.md § Conventions implied; KSPP |
| New SUID binary added to the rootfs | `blocking-concern` | `docs/TODO.md § System configuration hardening` |
| `eval` on user-controlled input | `blocking-concern` | shell injection |
| `rm -rf $VAR` without verifying `$VAR` is non-empty | `concern` | shell footgun |
| Disabling a hardening flag from ADR-011 for a specific package — exception not documented in `manifest.json:hardening.exclude` | `concern` | ADR-011 |
| Network listener added to a base-image rc script (binding `0.0.0.0`) | `concern` | Implicit; user audience is dev workstation, not server |
| New `dhcpcd` / `iproute2` config that doesn't restrict to expected interfaces | `suggestion` | Defense in depth |

## Axis 5 — Documentation (light pass)

Don't be exhaustive here; the human writes prose, you spot-check.

| Check | Severity |
|---|---|
| New ADR added but not referenced in CLAUDE.md § Locked decisions table | `concern` |
| Code introduces a new "load-bearing" pattern (per CLAUDE.md philosophy) without an ADR | `concern` |
| Runbook command shown in `docs/runbooks/*.md` no longer matches the actual tool flag set | `concern` |
| Cross-link to ADR-NNN where N is out of range or file doesn't exist | `concern` |
| New runbook lives outside `docs/runbooks/` | `suggestion` |

## What NOT to flag

Per CLAUDE.md § What NOT to do and the skill's `Failure modes you should
avoid`, do not raise findings about:

- Missing unit tests for shell scripts.
- Style preferences shellcheck doesn't flag (e.g., `[[ ]]` vs `[ ]` in bash).
- README/CLAUDE.md updates "for completeness".
- Switching to flakes / `pre-commit` / `mise` / `direnv`.
- Adding systemd "for one service."
- Adding a fallback path for an environment the architecture doesn't target.
