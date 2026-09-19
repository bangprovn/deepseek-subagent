#!/usr/bin/env bash
# Run a DeepSeek subagent through OpenCode, non-interactively.
#
# Usage:
#   run.sh [options] "prompt text"
#   echo "prompt text" | run.sh [options] -
#
# Options:
#   -w, --worker        use the deepseek-worker agent (can edit files / run bash)
#   -d, --dir DIR       directory the subagent works in (default: current dir)
#   -m, --model ID      OpenCode model id (default: $DEEPSEEK_SUBAGENT_MODEL or deepseek/deepseek-flash)
#   -f, --file PATH     attach a file to the message (repeatable)
#   -t, --timeout SECS  kill the run after SECS seconds (default: 900)
#   -o, --out PATH      also write the cleaned output to PATH
#   --raw               keep ANSI/formatting instead of stripping it
#   --dry-run           print the opencode command and exit
#
# Exit code is opencode's exit code, or 124 on timeout.
set -uo pipefail

AGENT="deepseek"
DIR="$PWD"
MODEL="${DEEPSEEK_SUBAGENT_MODEL:-deepseek/deepseek-flash}"
TIMEOUT=900
OUT=""
RAW=0
DRY=0
FILES=()
PROMPT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -w|--worker) AGENT="deepseek-worker"; shift ;;
    -d|--dir) DIR="$2"; shift 2 ;;
    -m|--model) MODEL="$2"; shift 2 ;;
    -f|--file) FILES+=("--file" "$2"); shift 2 ;;
    -t|--timeout) TIMEOUT="$2"; shift 2 ;;
    -o|--out) OUT="$2"; shift 2 ;;
    --raw) RAW=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -) PROMPT="$(cat)"; shift ;;
    --) shift; PROMPT="$*"; break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) PROMPT="$*"; break ;;
  esac
done

if [ -z "$PROMPT" ]; then
  echo "error: no prompt given (pass as argument or '-' to read stdin)" >&2
  exit 2
fi
if ! command -v opencode >/dev/null 2>&1; then
  echo "error: opencode not found on PATH" >&2
  exit 127
fi
DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "error: bad --dir" >&2; exit 2; }

CMD=(opencode run --agent "$AGENT" --model "$MODEL" --dir "$DIR" --format default --title "claude-subagent" ${FILES[@]+"${FILES[@]}"} -- "$PROMPT")

if [ "$DRY" = 1 ]; then
  printf '%q ' "${CMD[@]}"; echo
  exit 0
fi

# Portable timeout: macOS has no coreutils `timeout` by default.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  if [ $rc -eq 143 ] || [ $rc -eq 137 ]; then
    echo "error: subagent timed out after ${secs}s" >&2
    return 124
  fi
  return $rc
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Non-interactive: never let a permission prompt hang the run.
export OPENCODE_DISABLE_AUTOUPDATE=1
run_with_timeout "$TIMEOUT" "${CMD[@]}" >"$TMP" 2>&1 </dev/null
RC=$?

if [ "$RAW" = 1 ]; then
  cat "$TMP"
else
  # Strip ANSI escape sequences and the leading "> agent · model" banner line.
  sed -E $'s/\e\\[[0-9;?]*[A-Za-z]//g' "$TMP" | sed -E '1{/^[[:space:]]*$/d;}' | sed -E '/^> [a-z0-9-]+ · /d'
fi | tee "${OUT:-/dev/null}"

exit $RC
