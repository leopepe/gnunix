# Release-dependency flow

How GNUnix decouples slow `gnunix-base` rebuilds from hosted-CI
runtime, per [ADR-018](../adrs/ADR-018-artifact-taxonomy.md).

## The problem

`gnunix-base` builds from source — kernel + glibc + binutils + GCC +
sysvinit + everything else. On Apple Silicon native virtualization it
takes 6–10 h. GitHub-hosted runners (per [ADR-016](../adrs/ADR-016-ci-split-build-and-validation.md))
have a 6 h timeout. So `gnunix-base` cannot be rebuilt in hosted CI.

## The flow

```
Mac (local)              GH Release: base-images-<ver>        CI (hosted, ubuntu-22.04-arm)
────────────────         ────────────────────────────         ──────────────────────────────
build gnunix-base    ──► gnunix-base-<arch>-<ver>.img.zst   ◄── tools/fetch-image.sh gnunix-base
build gnunix-minimal ──► gnunix-minimal-<arch>-<ver>.img.zst ◄── tools/fetch-image.sh gnunix-minimal
                                                                  │
                                                                  ▼
                                                                  build gnunix-desktop
                                                                  build gnunix-installer
                                                                  installer-test
                                                                  │
                                                                  ▼
                                                                 GH Release: v<ver>
                                                                 (the user-facing release with
                                                                  base + minimal + desktop +
                                                                  installer artifacts)
```

Two release tracks:

- **`base-images-<ver>`** — intermediate, populated by Mac runs. Consumed
  by CI. Auto-published (not a draft) so CI can find the assets.
- **`v<ver>`** — the user-facing release, drafted by `release.yml` after
  CI bundles all four images. A human reviews and clicks "Publish."

## Publishing base + minimal (Mac dev workflow)

After a successful local rebuild:

```sh
# Build (once, when manifest pins change):
tools/build-all.sh gnunix-base
tools/build-all.sh gnunix-minimal

# Publish both forms (img.zst + tart.zst) of both images:
tools/release-image.sh gnunix-base
tools/release-image.sh gnunix-minimal
```

Each invocation:

1. Ensures the `.img.zst` and `.tart.zst` artifacts exist (calls
   `tools/package.sh` if missing).
2. Computes SHA256SUMS for the uploaded set.
3. Creates or reuses the `base-images-<ver>` GitHub Release and
   uploads with `--clobber` (idempotent — safe to re-run).

To force a different tag (e.g., for a hotfix):

```sh
tools/release-image.sh gnunix-base --release-tag=base-images-0.2.1-hotfix
```

## Fetching from CI

`build.yml` calls `tools/fetch-image.sh` as a pre-step on downstream
jobs:

```yaml
- name: Fetch gnunix-minimal-${{ matrix.ver }}
  run: tools/fetch-image.sh gnunix-minimal --ver=${{ matrix.ver }}
```

Behaviour:

1. Looks at `${GITHUB_REPOSITORY}` first (so forks pull their own
   base images when present).
2. Falls back to the upstream repo (from
   `tools/manifest.json:upstream_repo`, default `leopepe/gnunix`) if
   the fork hasn't published its own.
3. Decompresses, verifies against SHA256SUMS, and imports into the
   active VM driver (Tart on macOS, qemu on Linux — qemu path is
   stubbed today; lands in a follow-up).

## Fetching for local development

Skip the 6–10 h base rebuild:

```sh
# Pull the latest base image into Tart on your Mac:
tools/fetch-image.sh gnunix-minimal

# Then go straight to building the next layer:
tools/build-all.sh gnunix-desktop
```

To fetch without importing into a VM (e.g., just want the `.img` on
disk to pass to `qemu-img convert` or `dd`):

```sh
tools/fetch-image.sh gnunix-minimal --no-import --out-dir=.
ls -lh gnunix-minimal-aarch64-*.img
```

## Forks

A fork's CI works unchanged on `ubuntu-22.04-arm`:

- If the fork hasn't rebuilt `gnunix-base` (most cases), `fetch-image.sh`
  pulls from the upstream `leopepe/gnunix` release. Downstream layers
  build against upstream's base.
- If the fork DID change kernel / glibc / toolchain, the maintainer
  rebuilds locally on a Mac and runs
  `tools/release-image.sh gnunix-base --repo=$FORK`. The fork's CI
  then picks up the fork's base instead of upstream's.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `asset not found in <repo> nor <upstream>` | No published base for this version yet | Run `tools/release-image.sh gnunix-base` on a Mac that has the build. |
| `CHECKSUM MISMATCH` | Asset was re-uploaded between download and verification | Re-run `tools/fetch-image.sh` — `--clobber` will replace. |
| Tart `VM '<name>' already exists` on fetch | Previous run left a Tart VM behind | `tart delete <name>` or pass `--no-import` to skip the import step. |
| `qemu import — TODO` on Linux | qemu driver path not wired yet | Use `--no-import`; raw image is at `cache/artifacts/<name>.img`. |
