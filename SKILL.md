---
name: deepseek-subagent
description: Delegate bounded exploration, review, research, or implementation tasks to DeepSeek through OpenCode. Use when the user asks to use DeepSeek, a DeepSeek subagent, or offload work to DeepSeek/OpenCode.
---

# DeepSeek subagent for Codex

Run DeepSeek as a headless OpenCode process, then verify its output. This uses the configured DeepSeek credentials and API, not a native Codex collaboration agent. The child receives only its brief, attached files, and OpenCode session history.

## Locate and check

Resolve scripts relative to the directory containing this SKILL.md. Do not use Claude-specific variables or assume the project directory is the skill directory. The usual location is $CODEX_HOME/skills/deepseek-subagent, or ~/.codex/skills/deepseek-subagent when CODEX_HOME is unset.

Run `opencode --version` and `opencode auth list` without reading credential files. Check that `opencode agent list` includes deepseek and deepseek-worker. If agents are missing, run this skill's install.ps1 on Windows or bash install.sh on Unix. If OpenCode or authentication is missing, report the prerequisite; the user can run `opencode auth login` and choose DeepSeek. Never include keys in briefs or logs.

## Run a bounded task

Always pass the absolute project path, including on follow-ups. The directory option sets the working directory; it is not an OS sandbox. Use read-only mode for findings and worker mode only for authorized edits. Worker shell deny patterns are guardrails, not comprehensive isolation.

On Windows, use an absolute script path:

```powershell
$skillDir = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'skills/deepseek-subagent' } else { Join-Path $HOME '.codex/skills/deepseek-subagent' }
& "$skillDir/scripts/run.ps1" -Dir C:/project -Out C:/scratch/result.md -Log C:/scratch/events.log 'Review src/auth. Cite paths and lines; make no edits.'
& "$skillDir/scripts/run.ps1" -Worker -Dir C:/project 'Add the requested tests and run the relevant test command.'
& "$skillDir/scripts/run.ps1" -Dir C:/project -Session ses_example 'Explain the race you reported.'
```

On macOS/Linux/WSL:

```bash
skill_dir="${CODEX_HOME:-$HOME/.codex}/skills/deepseek-subagent"
bash "$skill_dir/scripts/run.sh" --dir /absolute/project -o /scratch/result.md 'Review src/auth. Cite paths and lines; make no edits.'
bash "$skill_dir/scripts/run.sh" --worker --dir /absolute/project 'Implement the bounded change and run its relevant tests.'
bash "$skill_dir/scripts/run.sh" --dir /absolute/project -s ses_example 'Explain the finding in detail.'
```

For long briefs, attach an absolute file with -File (PowerShell) or -f (Bash) and pass a short instruction to read it. Defaults: read-only deepseek agent, model deepseek/deepseek-flash, timeout 900 seconds. Override with -Model / -m or DEEPSEEK_SUBAGENT_MODEL. -DryRun / --dry-run prints the command without an API call. -Json / -j returns structured output. See the README flag table for additional options.

Use the shell execution tool available in the current Codex session. If it yields a running session ID, poll that same session using its associated tool (for example, exec_command then write_stdin). Distinguish this process handle from the OpenCode session ID in the final result. Do not use Claude's run_in_background parameter. Read logs with Get-Content -Tail 20 or tail -n 20 when progress is needed. For independent tasks, use distinct output/log paths and avoid overlapping worker edits; parallelize only within the session's authorization and limits.

## Brief and verify

Include the goal, deliverable, relevant paths, known findings, constraints, and verification command. The child does not see this conversation. Avoid secrets or unrelated private files. Record existing working-tree changes before a worker runs so you can distinguish its edits from the user's work.

Read the RESULT and check important claims against source files. Review worker diffs and run relevant checks. Do not discard existing user changes or blindly revert files to remove unwanted edits. Report what DeepSeek did, what you verified, and remaining uncertainty.

Keep the returned session ID for corrections using -Session / -s, preserving directory, model, and worker mode as appropriate. A QUESTION section requests a turn-based reply; answer in the same session. Use -Fork / --fork with a session to branch its history. Start a fresh session for unrelated work. The parent routes information between children.

Nonzero exit means failure: 124 is timeout, 2 invalid arguments, 127 missing OpenCode. Inspect output before retrying. After a worker timeout or error, review partial changes first. Correct a concrete cause before retrying; report repeated failures instead of looping. Native Codex collaboration tools do not manage these external processes.
