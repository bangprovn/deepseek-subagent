---
name: deepseek-subagent
description: Delegate a bounded task to a DeepSeek Flash subagent that runs through OpenCode (DeepSeek API). Use when work can be handed off cheaply and in parallel: codebase exploration, summarizing many files, drafting boilerplate or tests, first-pass code review, or research the main agent doesn't need to do itself. Also use when the user says "use deepseek", "deepseek subagent", or asks to offload work to DeepSeek/OpenCode.
argument-hint: [task description]
license: MIT
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/run.sh *), Bash(bash ${CLAUDE_SKILL_DIR}/scripts/run.sh *), Bash(tail *)
---

# DeepSeek subagent via OpenCode

DeepSeek Flash is not an Anthropic model, so Claude Code cannot spawn it with the Agent tool. Instead, run it as a headless OpenCode session with the wrapper script. Treat each run exactly like a subagent: brief it fully, run it, read and verify its result, and continue the same session when you need to follow up. Every run prints a `session:` id in its trailer for exactly that.

## Preflight

```!
command -v opencode >/dev/null && opencode --version || echo "opencode NOT INSTALLED"
opencode auth list 2>/dev/null | grep -qi deepseek && echo "deepseek auth: ok" || echo "deepseek auth: MISSING (user must run: opencode auth login -> DeepSeek)"
```

If the auth line says MISSING, stop and tell the user to run `opencode auth login` and pick DeepSeek. Never enter an API key yourself.

## How to run

Script: `${CLAUDE_SKILL_DIR}/scripts/run.sh`

```bash
# read-only subagent (explore, review, research, summarize)
"${CLAUDE_SKILL_DIR}/scripts/run.sh" --dir /abs/path/to/project "<self-contained brief>"

# worker subagent (may edit files and run commands in --dir)
"${CLAUDE_SKILL_DIR}/scripts/run.sh" --worker --dir /abs/path/to/project "<self-contained brief>"

# long brief: pipe it on stdin
cat brief.md | "${CLAUDE_SKILL_DIR}/scripts/run.sh" --dir /abs/path -

# attach files, save output, custom timeout (seconds)
"${CLAUDE_SKILL_DIR}/scripts/run.sh" -f src/foo.ts -o /tmp/out.md -t 600 "<brief>"

# reply to a subagent in its existing session
"${CLAUDE_SKILL_DIR}/scripts/run.sh" -s ses_xxxxxxxx "<follow-up>"
```

Defaults: agent `deepseek` (read-only), model `deepseek/deepseek-flash`, timeout 900s, `--dir` = current directory. Override the model with `-m provider/model` or the `DEEPSEEK_SUBAGENT_MODEL` env var. `--dry-run` prints the command without running it. `-j` prints one JSON object instead of text. `-l FILE` appends raw events to a log you can `tail -f`.

Every run ends with a trailer:

```
---
session: ses_f464f63c9ffefGqXj2UlKd844d
agent: deepseek  model: deepseek/deepseek-flash  tools: 3  tokens: in=4102 out=337  cost: $0.0008
exit: 0
```

Keep the `session:` id. It is the handle for talking to that subagent again.

## Talking back and forth

The channel is turn-based. Each `run.sh` call is one message from you; the subagent's output is its reply. Pass `-s <session id>` to send the next message into the same conversation. The subagent keeps everything it read and did.

Use it for:

- **Answering a question.** Agents are told to stop and end with a `QUESTION` section when they are blocked on something only you can decide. Reply with the answer via `-s` and they resume.
- **Drilling in.** "Your RESULT says `cache.ts:40` has a race. Show the exact lines and explain the interleaving."
- **Iterating on worker changes.** Review the diff, then: "`npm test` fails on `date.test.ts:12`, expected `2024-01-01`. Fix the timezone handling and rerun the tests."
- **Handing over more context.** Attach a file with `-f` or paste findings from another subagent into the message.
- **Branching.** `-s <id> --fork "<message>"` continues from the same history in a new session, leaving the original intact. Use it to try two approaches from one exploration.

Subagents cannot talk to each other. You are the router: run A, take what you need from A's reply, put it into B's brief or a `-s` message to B.

Do not use `-s` to give a subagent a new, unrelated task. Start a fresh session so its context stays small and cheap.

## Watching a long run

Launch with `-l /path/to/events.log` and `run_in_background: true`. The log gets one JSON line per event; the live progress lines on stderr show each tool call as `» read src/foo.ts`, `» bash npm test`, or `x edit ...` on failure. Check on it with:

```bash
tail -n 20 /path/to/events.log | cut -c1-200
```

If it is heading the wrong way, let it finish or time out, then correct it with `-s`. There is no mid-turn interrupt.

### Windows

On native Windows prefer the PowerShell port, which has the same flags and kills the whole process tree on timeout:

```powershell
& "${CLAUDE_SKILL_DIR}/scripts/run.ps1" -Dir C:/abs/path/to/project "<brief>"
& "${CLAUDE_SKILL_DIR}/scripts/run.ps1" -Worker -Dir C:/abs/path/to/project -Timeout 600 "<brief>"
& "${CLAUDE_SKILL_DIR}/scripts/run.ps1" -Session ses_xxxxxxxx "<follow-up>"
```

Run it with `pwsh -File` or `powershell -File` from Bash if that is the shell you have. `run.sh` also works under Git Bash, but its timeout cannot reliably stop a hung Node process there. Use forward slashes in `--dir` either way.

Always pass `--dir` explicitly with the absolute project path. The subagent only sees that directory.

## Choosing read-only vs worker

- **Read-only (`deepseek`)** is the default. Use it for anything whose output is text: findings, plans, summaries, reviews, answers.
- **Worker (`deepseek-worker`)** may edit files and run shell commands, but is blocked from `git commit`, `git push`, `rm -rf`, and `sudo`. Use it only for well-specified, mechanical implementation work where you will review the diff afterwards. Never use it for anything destructive or irreversible.

## Running in parallel

Each run is an independent process. For several independent tasks, launch several Bash calls with `run_in_background: true` in the same message, each writing to its own `-o` file, then read the files when they finish. Do not launch more than about 4 at once.

## Writing the brief

The brief is the only context the subagent gets. It cannot ask questions and it cannot see this conversation. Include:

1. The goal in one or two sentences, and the exact deliverable.
2. Absolute or repo-relative paths of files and directories to look at. Do not paste whole files; point at them.
3. What you already know or have ruled out, so it does not repeat that work.
4. Constraints: what not to touch, what style to follow, what to skip.
5. For workers: how to verify (which test command, which type check) and to report the real result.

The agents are instructed to finish with a `RESULT` section. Ask for a specific shape if you need one (a list, a table, a patch description).

## After it returns

- Read the `RESULT` section, then check the claims against the code yourself before relaying them. Spot-check at least the `path:line` citations that matter.
- For worker runs, run `git status` and `git diff` in `--dir` and review every change. Revert anything out of scope with `git checkout -- <file>`.
- Report to the user what DeepSeek did and what you verified. Attribute it plainly: "the DeepSeek subagent found…". Do not present its output as your own verified work unless you checked it.
- If the reply ends with a `QUESTION` section, answer it with `-s <session>` rather than re-briefing from scratch.
- Exit code 124 means timeout. Exit 2 means bad arguments. Anything else non-zero is an OpenCode or API error; the output contains the message.

## When not to use this

- Tasks needing this conversation's context that you cannot compress into a brief.
- Anything security-sensitive, destructive, or touching credentials.
- Small lookups you can do in a couple of tool calls yourself.

## Task

$ARGUMENTS
