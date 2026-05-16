#!/bin/sh
# Index this repo into MemPalace (https://github.com/mempalace/mempalace).
#
# What it does: runs `mempalace mine` over the canonical knowledge sources
# (ADRs, runbooks, the manifest, every CLAUDE.md, the workflow files) plus
# this project's Claude Code transcripts, all tagged under the `gnunix`
# wing so queries can be scoped.
#
# The palace itself lives in ~/.mempalace/ (per-developer, not committed —
# see PR introducing this script for rationale). Re-run after any
# substantive docs / ADR change to keep the index fresh.
#
# Optional: install the upstream auto-save hooks
# (hooks/mempal_save_hook.sh, hooks/mempal_precompact_hook.sh from
# mempalace/mempalace) into your Claude Code settings so the index
# updates on every session compaction. Not committed here — they're
# upstream's, may change, and not all contributors will want auto-save.

set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WING=${WING:-gnunix}
CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-"$HOME/.claude/projects/-Users-pepe-Workspace-lfs-nix-distro"}

if ! command -v mempalace >/dev/null 2>&1; then
  echo "mempalace not installed."
  echo "  pip install: https://github.com/mempalace/mempalace#install"
  exit 1
fi

cd "$REPO_ROOT"

echo "[mempalace-sync] wing=$WING"

# Knowledge-source paths. `mempalace mine <dir>` walks recursively; we
# pass the broad ones and let it respect .gitignore (kept defaults).
# Paths are listed by mining cost order — small files first, faster
# feedback when something breaks.
for path in \
  CLAUDE.md \
  CONTRIBUTING.md \
  README.md \
  docs/ \
  .github/ \
  images/CLAUDE.md \
  tools/manifest.json
do
  if [ -e "$path" ]; then
    echo "[mempalace-sync] mining $path"
    mempalace mine "$path" --wing "$WING" --mode projects
  fi
done

# Claude Code transcripts for this project. `--mode convos` parses
# session JSONL into one drawer per user/assistant exchange.
if [ -d "$CLAUDE_PROJECT_DIR" ]; then
  echo "[mempalace-sync] mining transcripts: $CLAUDE_PROJECT_DIR"
  mempalace mine "$CLAUDE_PROJECT_DIR" --wing "$WING" --mode convos
else
  echo "[mempalace-sync] no transcripts dir at $CLAUDE_PROJECT_DIR (skipping)"
fi

echo "[mempalace-sync] done."
mempalace status --wing "$WING" 2>/dev/null || true
