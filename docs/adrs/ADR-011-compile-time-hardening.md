# ADR-011: Compile-time hardening flags for lfs-core

**Status:** Proposed
**Date:** 2026-05-14

## Context

`docs/TODO.md` § Compile-time hardening lists PIE, SSP, `_FORTIFY_SOURCE`,
full RELRO + BIND_NOW, `-fstack-clash-protection`, `_GLIBCXX_ASSERTIONS`,
and aarch64 branch protection as desired-but-not-yet-applied. We compile the
entire LFS base from source (Phase 2), so we get to pick these — but the
toolchain bootstrap (binutils-pass1, gcc-pass1, glibc, libstdc++-pass1) and
a handful of special packages (kernel, GRUB) actively reject some of them.
This ADR locks the specific flag set, the exclusion list, and how the flags
are delivered to the stage scripts, so the work can be picked up and merged
without re-litigating each flag.

References consulted: OpenSSF Compiler Options Hardening Guide for C/C++,
Debian Hardening wiki, Gentoo Hardened, the `ptr1337/5a05d230` community
gist. Where they disagree the choice and rationale are recorded inline.

## Decision

### 1. Recommended flag set — **final native build** (stages/03b-chroot-inner.sh and later)

```sh
# CFLAGS / CXXFLAGS
-O2
-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3
-fstack-protector-strong
-fstack-clash-protection
-fPIE                            # add -fPIC for shared libs
-mbranch-protection=standard     # aarch64 equivalent of x86 -fcf-protection=full
-fno-strict-overflow
-fno-delete-null-pointer-checks
-fno-strict-aliasing
-ftrivial-auto-var-init=zero
-Wformat -Wformat=2 -Werror=format-security
# CXXFLAGS only:
-D_GLIBCXX_ASSERTIONS

# LDFLAGS
-Wl,-z,relro -Wl,-z,now
-Wl,-z,noexecstack
-Wl,-z,nodlopen
-Wl,--as-needed
-pie                             # for executables (drop for shared libs)
```

Disagreements resolved:

- **FORTIFY level**: gist=2, Debian=2, OpenSSF=3 → choose **`=3`**. GCC 14
  is well past the GCC 12 floor where `=3` stabilized.
- **Stack protector**: gist `-fstack-protector-all`, others `-strong` →
  choose **`-strong`**. `-all` instruments leaf functions for negligible
  additional coverage.
- **Stack-clash protection**: omitted by gist + Debian; required by
  OpenSSF. Include it — Debian's omission is a known gap, not rejection.
- **Branch protection**: only OpenSSF addresses aarch64 (BTI + PAC-ret).
  Non-controversial; HINT-space encoded so it's free on pre-ARMv8.3 cores.

### 2. Exclusions for the **cross-toolchain phase** (stages/01-cross-toolchain.sh, stages/02-temp-tools.sh)

Do **not** set the following while building `binutils-pass1`, `gcc-pass1`,
`glibc`, `libstdc++-pass1`:

| Flag | Reason |
|---|---|
| `-fPIE -pie` | GCC stage1 and libgcc fail with PIE; bootstrap must produce relocatable static objects. |
| `-D_FORTIFY_SOURCE=*` | glibc *is* the implementation of `__*_chk`; defining FORTIFY while building glibc creates duplicate symbols. Glibc's build undefines it internally; the env must not force it back. |
| `-fstack-protector-*` | Cross-toolchain has no `__stack_chk_fail` yet — canaries would reference unresolved symbols. Re-enable for the final glibc pass and stage2 GCC. |
| `-mbranch-protection=standard` | Has tripped LFS-style builds in early static crt objects. Re-add for the chroot/native phase only. |

Keep `-O2`, the `-W*` warnings, and `-Wl,-z,relro,-z,now` during bootstrap;
they're harmless.

### 3. Per-package exceptions (final phase)

| Package | Disable | Reason |
|---|---|---|
| **glibc** | `-D_FORTIFY_SOURCE=*`, `-fstack-protector*` on early csu/ld.so objects | Glibc provides the runtime symbols; build system handles it internally but the env must not force them. |
| **Linux kernel** | All hardening flags | Kernel has its own (`CONFIG_FORTIFY_SOURCE`, `CONFIG_STACKPROTECTOR_STRONG`, `CONFIG_ARM64_BTI_KERNEL`). Build with `make` only; do not leak host CFLAGS. |
| **GCC (stage2/final)** | `-pie` on the driver itself | GCC driver is built without PIE upstream; setting it globally breaks libgcc and libgcc_s. |
| **GRUB** | `-fPIE`, `-fstack-protector*`, `-mbranch-protection` | GRUB modules are freestanding; protection symbols don't exist in firmware context. |
| **binutils (final)** | `-D_FORTIFY_SOURCE=3` | Historically miscompiles opcode-table TUs; downgrade to `=2` here, or omit. |
| **bash, gettext** | `-ftrivial-auto-var-init=zero` (case-by-case) | Have been observed to depend on uninit reads in arena code; remove the flag for the offending package if it breaks. |

### 4. Delivery mechanism

**Chosen: `tools/manifest.json` + a small `lib/hardening.sh` helper sourced
by the stage scripts.** Concretely, add to manifest.json:

```jsonc
{
  "hardening": {
    "$note": "Compile-time hardening per ADR-011. The native_* sets are exported by stage 03b onwards; the cross_* sets are exported by stages 01-02. Per-package exclusions are merged at export time.",
    "native_cflags":  "-O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fstack-protector-strong -fstack-clash-protection -fPIE -mbranch-protection=standard -fno-strict-overflow -fno-delete-null-pointer-checks -fno-strict-aliasing -ftrivial-auto-var-init=zero -Wformat -Wformat=2 -Werror=format-security",
    "native_cxxflags_extra": "-D_GLIBCXX_ASSERTIONS",
    "native_ldflags": "-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,nodlopen -Wl,--as-needed -pie",
    "cross_cflags":   "-O2 -Wformat -Wformat=2 -Werror=format-security",
    "cross_ldflags":  "-Wl,-z,relro -Wl,-z,now",
    "exclude": {
      "glibc":       ["-D_FORTIFY_SOURCE=3", "-fstack-protector-strong"],
      "linux":       ["ALL"],
      "gcc":         ["-pie"],
      "grub":        ["-fPIE", "-pie", "-fstack-protector-strong", "-fstack-clash-protection", "-mbranch-protection=standard"],
      "binutils":    ["-D_FORTIFY_SOURCE=3"],
      "bash":        ["-ftrivial-auto-var-init=zero"],
      "gettext":     ["-ftrivial-auto-var-init=zero"]
    }
  }
}
```

Stage scripts source `images/lfs-core/lib/hardening.sh`, which exposes
`hardening_export <package_name>` to set `CFLAGS`, `CXXFLAGS`, `LDFLAGS`
with per-package exclusions applied.

Alternatives rejected:

- **GCC spec file** (`/etc/specs`) — silently mutates *every* compile in the
  resulting system including users' Nix-builds and kernel rebuilds.
  Violates the "no hidden policy" principle (CLAUDE.md). Also breaks
  `nix-shell`'s wrapper detection. Hard no.
- **Plain `export` blocks duplicated per stage** — drifts and re-types the
  same long string in 30+ stage entry points; the exclusion list would have
  to be maintained inline as bash conditionals. Worse than data.

The manifest approach is consistent with ADR-008 (pinning lives in
manifest.json) and lets Renovate-style review surface flag changes the same
way it surfaces version bumps.

### 5. Performance overhead (claimed)

OpenSSF for the full recommended set:

- `_FORTIFY_SOURCE=3`: ~0.1%
- `-fstack-protector-strong`: "minimal"
- `-fstack-clash-protection`: variable, ~0 for small-stack code
- `-fPIE` on 64-bit: "negligible" (the gist warns of a penalty, but that
  reflects 32-bit-era data)
- `-D_GLIBCXX_ASSERTIONS`: "up to 6%" — C++ hot paths only
- `-mbranch-protection=standard`: "mild"; free on pre-ARMv8.3 silicon
- Full RELRO + BIND_NOW: startup cost only; Debian dismisses it for daemons

Realistic aggregate for our workstation base: **<1% on typical C, 2–6% on
hot C++** with `_GLIBCXX_ASSERTIONS`. Acceptable.

### 6. "Do not enable on first pass" list

- **`-fstack-protector-all`** — covered above; outvoted by OpenSSF/Debian.
- **`-fzero-call-used-regs=all`** — GCC 11+ ROP/Spectre-lite mitigation;
  real codegen cost; breaks some inline asm. Revisit after the base is stable.
- **`-fhardcfr` / `-fharden-control-flow-redundancy`** — GCC 14 brand-new,
  no production track record. Skip.
- **`-fcf-protection=full`** — x86-only; no-op on aarch64. Replaced by
  `-mbranch-protection=standard` in our flag set.
- **`-Werror`** (blanket) — OpenSSF explicit: "never ship in source
  distributions." Blocks kernel/glibc rebuilds when a new GCC warns.
- **`-ftrapv`** — the gist itself flags it as "currently bugged in gcc."

## Consequences

- New file: `images/lfs-core/lib/hardening.sh` — pure function of package
  name; sources manifest.json via `jq` and emits the right exports.
- `tools/manifest.json` schema bump: `hardening: { ... }` block.
- `images/lfs-core/stages/01-cross-toolchain.sh`,
  `02-temp-tools.sh`, and `03b-chroot-inner.sh` modified to source the
  helper and call `hardening_export <pkg>` before each `./configure`.
- A new lfs-core build (~6–10h) is required to validate the flags don't
  break anything. CI's `build` job will catch toolchain-breakage early.
- Renovate continues to manage version pins; the hardening block is hand-
  edited (per-flag bumps are too small to warrant automation).

## Out of scope

- **Kernel hardening config flips** (`CONFIG_INIT_STACK_ALL_ZERO`,
  `CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT`, etc.) — separate ADR, separate
  rebuild. Tracked in `docs/TODO.md`.
- **Sysctls + runtime hardening** — Phase 4+ work, also already in TODO.md.
- **MAC frameworks** (AppArmor/SELinux) — see ADR placeholder; default
  remains "no MAC on the workstation base."
- **Reproducible builds** (`SOURCE_DATE_EPOCH`, sorted archives) — separate
  ADR. Useful prerequisite to make the published image hash meaningful but
  orthogonal to hardening flag choice.

## How to roll out

1. Land the manifest schema + `lib/hardening.sh` helper (no rebuild needed
   yet — it's dead code until stage scripts call it).
2. Modify one stage at a time (cross-toolchain first, then temp-tools, then
   chroot-inner). Each step: rebuild, run `tests/boot-smoke.sh`. If the
   build breaks, the exclusion list grows by one row in the manifest.
3. Once `lfs-core-0.2.0` boots clean with the full set, tag it and let
   Phase 3/4 inherit (they don't recompile anything — they layer on top).

## References

- OpenSSF Compiler Options Hardening Guide for C and C++: https://best.openssf.org/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C++
- Debian Hardening wiki: https://wiki.debian.org/Hardening
- Gentoo Hardened: https://wiki.gentoo.org/wiki/Project:Hardened
- ptr1337 community gist: https://gist.github.com/ptr1337/5a05d230bae5ea00478ce13a211a263c
- GCC manual, "Options That Control Optimization" and "Options for Code Generation Conventions"
- ARMv8.3+ branch-protection HINT-space encoding (gcc `-mbranch-protection` docs)
