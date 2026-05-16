#!/bin/sh
# tests/installer/tui-interactions.sh
#
# TUI-interaction tests for gnunix-installer. Runs every .exp scenario
# under tui-scenarios/ against the dry-run mode of the installer, then
# asserts the gathered values in /tmp/gnunix-installer-choices.env.
#
# Host-side test: no VM, no disks touched. Prereqs: whiptail + expect.
#
# Usage:
#   tests/installer/tui-interactions.sh           # run every scenario
#   tests/installer/tui-interactions.sh <name>    # run one scenario
#
# Exit codes:
#   0  every scenario passed
#   1  one or more scenarios failed
#   2  prereqs missing

set -eu

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
INSTALLER="$REPO_ROOT/images/installer/installer/gnunix-installer"
SCEN_DIR="$REPO_ROOT/tests/installer/tui-scenarios"
WORK_DIR="$REPO_ROOT/cache/tui-test"
CHOICES="/tmp/gnunix-installer-choices.env"

ONLY=${1:-}

# ----------------------------------------------------------------------------
# Prereqs
# ----------------------------------------------------------------------------
for t in expect whiptail; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "[tui-test] missing prerequisite: $t" >&2
    echo "  macOS: brew install newt expect" >&2
    echo "  Linux: sudo apt-get install -y whiptail expect" >&2
    exit 2
  fi
done
[ -x "$INSTALLER" ] || { echo "[tui-test] $INSTALLER not executable" >&2; exit 2; }

# ----------------------------------------------------------------------------
# Stage a mock lsblk so the disk-menu has deterministic entries
# regardless of the host. Two disks: vda (default cursor), vdb.
# ----------------------------------------------------------------------------
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/lsblk" <<'MOCK'
#!/bin/sh
# Mock lsblk for TUI tests — installer only calls `lsblk -dno NAME,SIZE,TYPE`.
printf '%s\n' "vda	10G	disk" "vdb	20G	disk"
MOCK
chmod +x "$WORK_DIR/bin/lsblk"

# ----------------------------------------------------------------------------
# Each scenario is a (name, expected-values-or-"cancel") tuple. The
# expected values block is the literal expected content of CHOICES,
# trimmed of leading/trailing whitespace, compared byte-for-byte.
# "cancel" means CHOICES must NOT exist after the scenario runs.
# ----------------------------------------------------------------------------
scenarios="
desktop-hyprland|TARGET_DISK=/dev/vda;PROFILE=desktop-hyprland;HOSTNAME=gnunix;USERNAME=user;PASSWORD=secret123
minimal|TARGET_DISK=/dev/vdb;PROFILE=minimal;HOSTNAME=tiny;USERNAME=op;PASSWORD=letmein01
desktop-sway|TARGET_DISK=/dev/vda;PROFILE=desktop-sway;HOSTNAME=gnunix;USERNAME=user;PASSWORD=swaytest
desktop-labwc|TARGET_DISK=/dev/vda;PROFILE=desktop-labwc;HOSTNAME=gnunix;USERNAME=user;PASSWORD=labwctest
desktop-labwc-nextspace|TARGET_DISK=/dev/vda;PROFILE=desktop-labwc-nextspace;HOSTNAME=gnunix;USERNAME=user;PASSWORD=nextspacetest
password-mismatch|TARGET_DISK=/dev/vda;PROFILE=minimal;HOSTNAME=gnunix;USERNAME=user;PASSWORD=correct-on-retry
escape-cancels|cancel
"

run_one() {
  name=$1
  expected=$2

  rm -f "$CHOICES"

  PATH="$WORK_DIR/bin:$PATH" \
    GNUNIX_INSTALLER_DRY_RUN=1 \
    expect "$SCEN_DIR/$name.exp" "$INSTALLER" \
      >"$WORK_DIR/$name.log" 2>&1
  rc=$?

  if [ "$expected" = "cancel" ]; then
    if [ -f "$CHOICES" ]; then
      echo "FAIL  $name — choices file was written despite cancel:"
      cat "$CHOICES" | sed 's/^/        /'
      return 1
    fi
    echo "PASS  $name (cancelled cleanly)"
    return 0
  fi

  if [ "$rc" -ne 0 ]; then
    echo "FAIL  $name — expect script exited $rc"
    tail -5 "$WORK_DIR/$name.log" | sed 's/^/        /'
    return 1
  fi
  if [ ! -f "$CHOICES" ]; then
    echo "FAIL  $name — no choices file written"
    tail -5 "$WORK_DIR/$name.log" | sed 's/^/        /'
    return 1
  fi

  # Compare line-by-line so we report which field differs.
  diff_msg=""
  actual=$(tr '\n' ';' < "$CHOICES" | sed 's/;$//')
  if [ "$actual" != "$expected" ]; then
    diff_msg=$(
      echo "expected:"
      echo "$expected" | tr ';' '\n' | sed 's/^/        /'
      echo "actual:"
      echo "$actual" | tr ';' '\n' | sed 's/^/        /'
    )
    echo "FAIL  $name — choices mismatch:"
    echo "$diff_msg"
    return 1
  fi

  echo "PASS  $name"
  return 0
}

# ----------------------------------------------------------------------------
# Iterate
# ----------------------------------------------------------------------------
pass=0
fail=0
total=0

OLDIFS=$IFS
IFS='
'
for row in $scenarios; do
  [ -z "$row" ] && continue
  name=${row%%|*}
  expected=${row#*|}
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  total=$((total + 1))
  if run_one "$name" "$expected"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done
IFS=$OLDIFS

echo
if [ "$total" -eq 0 ]; then
  echo "[tui-test] no scenario matched '$ONLY'" >&2
  exit 1
fi
echo "[tui-test] $pass/$total passed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
