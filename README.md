# deepseek-subagent

A [Claude Code](https://code.claude.com) skill that lets Claude delegate bounded tasks to **DeepSeek Flash** running headlessly through [OpenCode](https://opencode.ai), using DeepSeek's own API.

Claude Code's Agent tool and `CLAUDE_CODE_SUBAGENT_MODEL` only reach Anthropic-served models. This skill sidesteps that: Claude briefs DeepSeek the way it would brief a subagent, runs it as an `opencode run` session in your project directory, then reads and verifies the result.

Works on macOS, Linux, WSL, and native Windows.

## What's inside

| Path | Purpose |
|---|---|
| `SKILL.md` | The skill Claude Code loads. Tells Claude when and how to delegate, how to brief, and to verify results. |
| `scripts/run.sh` | Bash wrapper around `opencode run` (macOS, Linux, Git Bash). |
| `scripts/run.ps1` | PowerShell wrapper with the same flags (Windows PowerShell 5.1 and PowerShell 7). Kills the whole process tree on timeout. |
| `opencode/agents/deepseek.md` | Read-only OpenCode agent on `deepseek/deepseek-flash`. Cannot edit or run shell. |
| `opencode/agents/deepseek-worker.md` | Same model, may edit files and run shell. `git commit`, `git push`, `git reset --hard`, `rm -rf`, `sudo` denied. |
| `install.sh` / `install.ps1` | Copy the OpenCode agents into place and check your setup. |

Both agents deny OpenCode's `question` and `doom_loop` permissions so a headless run can never stall waiting for a human.

## Install

1. Install [OpenCode](https://opencode.ai/docs/#install) and add your DeepSeek key:
   ```bash
   opencode auth login   # choose DeepSeek
   ```
2. Clone this repo into Claude Code's user-level skills folder:
   ```bash
   git clone https://github.com/bangprovn/deepseek-subagent.git ~/.claude/skills/deepseek-subagent
   ```
   Windows: `git clone https://github.com/bangprovn/deepseek-subagent.git $HOME\.claude\skills\deepseek-subagent`
3. Install the OpenCode agents:
   ```bash
   ~/.claude/skills/deepseek-subagent/install.sh
   ```
   Windows: `& $HOME\.claude\skills\deepseek-subagent\install.ps1`

Restart Claude Code. The skill now appears as `/deepseek-subagent`.

## Use

In Claude Code:

```
/deepseek-subagent review src/auth for missing error handling
```

or just say "use deepseek for this". Claude writes a self-contained brief, runs it, and checks the answer against the code before relaying it.

Direct use of the wrapper:

```bash
# read-only: explore, review, research
scripts/run.sh --dir /path/to/project "Summarize src/auth and list every exported function."

# worker: may edit files in --dir
scripts/run.sh --worker --dir /path/to/project "Add unit tests for src/utils/date.ts using the existing vitest setup."

# long brief on stdin, save output, custom timeout
cat brief.md | scripts/run.sh --dir /path/to/project -o out.md -t 600 -
```

```powershell
scripts\run.ps1 -Dir C:\path\to\project "Summarize src/auth and list every exported function."
scripts\run.ps1 -Worker -Dir C:\path\to\project -Timeout 600 "Add unit tests for src/utils/date.ts"
Get-Content brief.md -Raw | scripts\run.ps1 -Dir C:\path\to\project -
```

| bash flag | PowerShell | meaning |
|---|---|---|
| `-w`, `--worker` | `-Worker` | use the `deepseek-worker` agent |
| `-d`, `--dir DIR` | `-Dir` | project directory (default: current) |
| `-m`, `--model ID` | `-Model` | OpenCode model id, default `deepseek/deepseek-flash` |
| `-f`, `--file PATH` | `-File` | attach file(s) to the message |
| `-t`, `--timeout SECS` | `-Timeout` | default 900 |
| `-o`, `--out PATH` | `-Out` | also write output to a file |
| `--raw` | `-Raw` | keep ANSI codes |
| `--dry-run` | `-DryRun` | print the command only |

Set `DEEPSEEK_SUBAGENT_MODEL` to change the default model without editing anything. Exit code 124 means timeout, 2 bad arguments, 127 OpenCode missing.

## Changing the model

OpenCode's DeepSeek provider currently exposes `deepseek/deepseek-flash`, `deepseek/deepseek-v4-flash`, and `deepseek/deepseek-v4-pro`. To switch permanently, edit the `model:` line in both files under `opencode/agents/` and re-run the installer.

## Platform notes

- **macOS / Linux / WSL:** everything works as-is.
- **Windows, Git Bash:** `run.sh` works, but Git Bash cannot reliably kill a Node process tree, so a hung run may outlive `-t`. Prefer `run.ps1`.
- **Windows, PowerShell:** if `opencode` on your PATH is an npm `.cmd` shim, `run.ps1` passes the brief as an attached file instead of inline to avoid `cmd.exe` mangling special characters. The native OpenCode installer avoids this.
- OpenCode reads global agents from `~/.config/opencode/agents` on every platform (`%USERPROFILE%\.config\opencode\agents` on Windows). Set `OPENCODE_CONFIG_DIR` before running the installer if yours lives elsewhere.

## License

MIT
