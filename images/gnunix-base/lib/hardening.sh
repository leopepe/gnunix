#!/bin/bash
# images/gnunix-base/lib/hardening.sh — compile-time hardening helper (ADR-011).
#
# Provides `hardening_export <package> <mode>` which exports CFLAGS,
# CXXFLAGS, LDFLAGS for the current shell, ready for a configure/make pair.
#
# Modes:
#   cross   — small, safe flag set; used by stages 01-cross-toolchain.sh and
#             02-temp-tools.sh while the toolchain is still being bootstrapped.
#             Excludes PIE, FORTIFY_SOURCE, stack-protector, branch-protection.
#   native  — full hardening set; used by stage 03b-chroot-inner.sh once a
#             native toolchain exists. Applies per-package exclusions from
#             manifest.json:hardening.exclude.<pkg>.
#
# Data source: tools/manifest.json:hardening.* (ADR-011, source of truth).
#
# Loading order:
#   Outside chroot (stages 01, 02): jq exists, the helper reads manifest.json
#     directly. Set HARDENING_MANIFEST_JSON before sourcing if it's at a
#     non-default path.
#   Inside chroot (stage 03b): jq does NOT exist. The orchestrator
#     (images/gnunix-base/build.sh) pre-renders the relevant flag strings into
#     /repo/hardening.env which 03b sources before this helper. The helper
#     then uses those env vars directly and skips the jq path.
#
# Usage:
#   . /repo/lib/hardening.sh
#   hardening_export binutils cross    # sets CFLAGS/CXXFLAGS/LDFLAGS
#   ./configure ...
#   make
#   make install

# -----------------------------------------------------------------------------
# Internal: load the hardening config into HARDENING_* env vars (idempotent).
# Reads from manifest.json via jq if available; otherwise expects the caller
# (the orchestrator) to have already exported the vars (via hardening.env).
# -----------------------------------------------------------------------------
_hardening_resolve_manifest() {
  # Caller can override via HARDENING_MANIFEST_JSON. Otherwise we walk up
  # from the helper's own location to find tools/manifest.json. BASH_SOURCE[0]
  # is the helper's path (works for both `source` and `bash -c '. helper'`).
  if [ -n "${HARDENING_MANIFEST_JSON:-}" ]; then
    echo "$HARDENING_MANIFEST_JSON"
    return
  fi
  if [ -n "${REPO_ROOT:-}" ] && [ -f "${REPO_ROOT}/tools/manifest.json" ]; then
    echo "${REPO_ROOT}/tools/manifest.json"
    return
  fi
  local helper_dir
  helper_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # helper at images/gnunix-base/lib/hardening.sh → 3 levels up to repo root
  local guess="$(cd "$helper_dir/../../.." && pwd)/tools/manifest.json"
  echo "$guess"
}

_hardening_load() {
  # Already loaded? Skip.
  [ -n "${HARDENING_NATIVE_CFLAGS:-}" ] && return 0

  # Inside chroot path: caller must have sourced /repo/hardening.env first.
  if ! command -v jq >/dev/null 2>&1; then
    echo "[hardening] jq not available and HARDENING_NATIVE_CFLAGS not set;" >&2
    echo "            either source /repo/hardening.env before this script," >&2
    echo "            or set HARDENING_MANIFEST_JSON to a manifest.json path." >&2
    return 1
  fi

  local manifest
  manifest=$(_hardening_resolve_manifest)
  [ -f "$manifest" ] || { echo "[hardening] manifest not found: $manifest" >&2; return 1; }

  HARDENING_NATIVE_CFLAGS=$(jq -r '.hardening.native_cflags  // ""' "$manifest")
  HARDENING_NATIVE_CXXFLAGS_EXTRA=$(jq -r '.hardening.native_cxxflags_extra // ""' "$manifest")
  HARDENING_NATIVE_LDFLAGS=$(jq -r '.hardening.native_ldflags // ""' "$manifest")
  HARDENING_CROSS_CFLAGS=$(jq -r  '.hardening.cross_cflags   // ""' "$manifest")
  HARDENING_CROSS_LDFLAGS=$(jq -r '.hardening.cross_ldflags  // ""' "$manifest")
  export HARDENING_NATIVE_CFLAGS HARDENING_NATIVE_CXXFLAGS_EXTRA \
         HARDENING_NATIVE_LDFLAGS HARDENING_CROSS_CFLAGS HARDENING_CROSS_LDFLAGS

  # Per-package excludes: serialize as HARDENING_EXCLUDE_<pkg>="flag1 flag2 ..."
  # (or "ALL"). Hyphens in package names are replaced with underscores so the
  # var name is shell-safe. We never read with a hyphen; callers normalize.
  # The loop variables are `local`'d so they don't clobber the caller's $pkg
  # (which bit us during testing — `hardening_export binutils cross` got an
  # empty $pkg in its echo because this function ran in the same dynamic scope).
  local _pkg _flags _safe_pkg
  while IFS=$'\t' read -r _pkg _flags; do
    [ -z "$_pkg" ] && continue
    _safe_pkg=${_pkg//-/_}
    eval "HARDENING_EXCLUDE_$_safe_pkg=\$_flags"
    export "HARDENING_EXCLUDE_$_safe_pkg"
  done < <(jq -r '.hardening.exclude // {} | to_entries[] | select(.key | startswith("$") | not) | "\(.key)\t\(.value | join(" "))"' "$manifest")
}

# -----------------------------------------------------------------------------
# Strip excluded tokens from a flag string.
# $1 = input space-separated flags
# $2 = space-separated exclude tokens (or "ALL" to mean "everything")
# stdout: filtered flag string
# -----------------------------------------------------------------------------
_hardening_strip() {
  local flags=$1 excl=$2
  case "$excl" in
    ALL|*' ALL '*|*' ALL'|'ALL '*) echo ""; return 0 ;;
  esac
  [ -z "$excl" ] && { echo "$flags"; return 0; }
  # Force IFS to the default for our `for` word-splits — the caller (or an
  # earlier `IFS=$'\t' read ...`) may have left IFS set to tab, which would
  # treat `$flags` as one giant unsplit string. Use a local IFS so we don't
  # disturb anything outside this function.
  local IFS=$' \t\n'
  local out=""
  local f e skip
  for f in $flags; do
    skip=0
    for e in $excl; do
      if [ "$f" = "$e" ]; then skip=1; break; fi
    done
    [ $skip -eq 0 ] && out="$out $f"
  done
  # Trim leading space
  echo "${out# }"
}

# -----------------------------------------------------------------------------
# Public: hardening_export <package> <mode>
# Sets CFLAGS, CXXFLAGS, LDFLAGS for the current shell.
#   <package>: bash, glibc, kernel, linux, gcc, grub, binutils, ...
#              (matched against HARDENING_EXCLUDE_<package> env var; hyphens
#              normalized to underscores)
#   <mode>:    cross | native
# -----------------------------------------------------------------------------
hardening_export() {
  local pkg=$1 mode=$2
  _hardening_load || return $?

  local base_cflags base_ldflags cxx_extra=""
  case "$mode" in
    cross)
      base_cflags=$HARDENING_CROSS_CFLAGS
      base_ldflags=$HARDENING_CROSS_LDFLAGS
      ;;
    native)
      base_cflags=$HARDENING_NATIVE_CFLAGS
      base_ldflags=$HARDENING_NATIVE_LDFLAGS
      cxx_extra=$HARDENING_NATIVE_CXXFLAGS_EXTRA
      ;;
    *)
      echo "[hardening] usage: hardening_export <package> <cross|native> (got mode='$mode')" >&2
      return 1
      ;;
  esac

  local safe_pkg=${pkg//-/_}
  local excl
  eval "excl=\${HARDENING_EXCLUDE_$safe_pkg:-}"

  local cflags ldflags
  cflags=$(_hardening_strip "$base_cflags" "$excl")
  ldflags=$(_hardening_strip "$base_ldflags" "$excl")

  export CFLAGS="$cflags"
  export CXXFLAGS="$cflags${cxx_extra:+ $cxx_extra}"
  export LDFLAGS="$ldflags"
  echo "[hardening] $pkg ($mode): CFLAGS=$CFLAGS"
  echo "[hardening] $pkg ($mode): LDFLAGS=$LDFLAGS"
}

# -----------------------------------------------------------------------------
# hardening_render_env <output-path>
# Pre-renders the manifest's hardening config into a bash env file that can be
# sourced inside the chroot (where jq is unavailable). Called by build.sh
# right before entering the chroot.
# -----------------------------------------------------------------------------
hardening_render_env() {
  local out=$1
  _hardening_load || return $?
  local manifest
  manifest=$(_hardening_resolve_manifest)
  {
    echo "# Generated by lib/hardening.sh:hardening_render_env (do not edit)"
    echo "export HARDENING_NATIVE_CFLAGS='${HARDENING_NATIVE_CFLAGS}'"
    echo "export HARDENING_NATIVE_CXXFLAGS_EXTRA='${HARDENING_NATIVE_CXXFLAGS_EXTRA}'"
    echo "export HARDENING_NATIVE_LDFLAGS='${HARDENING_NATIVE_LDFLAGS}'"
    echo "export HARDENING_CROSS_CFLAGS='${HARDENING_CROSS_CFLAGS}'"
    echo "export HARDENING_CROSS_LDFLAGS='${HARDENING_CROSS_LDFLAGS}'"
    # Dump exclusions: tab-delimited pkg\tflag1 flag2 from jq, then format in bash.
    jq -r '
      .hardening.exclude // {}
      | to_entries[]
      | select(.key | startswith("$") | not)
      | [.key, (.value | join(" "))] | @tsv
    ' "$manifest" | while IFS=$'\t' read -r pkg flags; do
      [ -z "$pkg" ] && continue
      local safe_pkg=${pkg//-/_}
      printf "export HARDENING_EXCLUDE_%s='%s'\n" "$safe_pkg" "$flags"
    done
  } > "$out"
}
