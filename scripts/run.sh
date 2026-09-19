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
#   -s, --session ID    continue an existing session (two-way conversation)
#       --fork          with --session: branch off instead of continuing in place
#   -m, --model ID      OpenCode model id (default: $DEEPSEEK_SUBAGENT_MODEL or deepseek/deepseek-flash)
#   -f, --file PATH     attach a file to the message (repeatable)
#   -t, --timeout SECS  kill the run after SECS seconds (default: 900)
#   -o, --out PATH      also write the final output to PATH
#   -l, --log PATH      append raw JSON events to PATH (tail it to watch progress)
#   -j, --json          print one JSON object {session,text,exit,tokens,...} instead of text
#   -q, --quiet         no live progress lines on stderr
#       --dry-run       print the opencode command and exit
#
# Output ends with a trailer:  ---  session: ses_...  exit: N
# Pass that session id to -s to reply to the subagent in the same conversation.
# Exit code is opencode's exit code, or 124 on timeout.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARGS=()
PROMPT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -w|--worker) ARGS+=(--agent deepseek-worker); shift ;;
    -d|--dir) ARGS+=(--dir "$2"); shift 2 ;;
    -s|--session) ARGS+=(--session "$2"); shift 2 ;;
    --fork) ARGS+=(--fork); shift ;;
    -m|--model) ARGS+=(--model "$2"); shift 2 ;;
    -f|--file) ARGS+=(--file "$2"); shift 2 ;;
    -t|--timeout) ARGS+=(--timeout "$2"); shift 2 ;;
    -o|--out) ARGS+=(--out "$2"); shift 2 ;;
    -l|--log) ARGS+=(--log "$2"); shift 2 ;;
    -j|--json) ARGS+=(--json); shift ;;
    -q|--quiet) ARGS+=(--quiet); shift ;;
    --dry-run) ARGS+=(--dry-run); shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
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

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
if [ -z "$PY" ]; then
  echo "error: python3 is required by run.sh. On Windows use scripts/run.ps1 instead." >&2
  exit 127
fi

exec "$PY" "$HERE/deepseek_run.py" ${ARGS[@]+"${ARGS[@]}"} -- "$PROMPT"
