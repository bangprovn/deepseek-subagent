#!/usr/bin/env bash
# Install the deepseek-subagent skill's OpenCode side (macOS / Linux / Git Bash).
# Run from the skill directory, e.g. ~/.codex/skills/deepseek-subagent/install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}/agents"

mkdir -p "$DEST"
cp "$HERE"/opencode/agents/deepseek.md "$HERE"/opencode/agents/deepseek-worker.md "$DEST"/
chmod +x "$HERE"/scripts/run.sh
echo "installed OpenCode agents -> $DEST"

if ! command -v opencode >/dev/null 2>&1; then
  echo "WARNING: opencode not on PATH. Install it: https://opencode.ai/docs/#install" >&2
  exit 0
fi
echo "opencode $(opencode --version)"
if opencode auth list 2>/dev/null | grep -qi deepseek; then
  echo "DeepSeek credentials: ok"
else
  echo "DeepSeek credentials: missing. Run:  opencode auth login   and choose DeepSeek." >&2
fi
echo
echo "Done. In Codex, ask it to 'use deepseek' or invoke the deepseek-subagent skill."
