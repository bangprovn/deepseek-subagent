# Install the deepseek-subagent skill's OpenCode side (Windows PowerShell 5.1+ / PowerShell 7).
# Run from the skill directory, e.g. ~\.claude\skills\deepseek-subagent\install.ps1
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Base = if ($env:OPENCODE_CONFIG_DIR) { $env:OPENCODE_CONFIG_DIR } else { Join-Path $HOME '.config\opencode' }
$Dest = Join-Path $Base 'agents'

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item (Join-Path $Here 'opencode\agents\deepseek.md'), (Join-Path $Here 'opencode\agents\deepseek-worker.md') -Destination $Dest -Force
Write-Host "installed OpenCode agents -> $Dest"

$oc = Get-Command opencode -ErrorAction SilentlyContinue
if (-not $oc) {
  Write-Warning 'opencode not on PATH. Install it: https://opencode.ai/docs/#install'
  exit 0
}
Write-Host "opencode $(& opencode --version)"
$auth = (& opencode auth list 2>$null) -join "`n"
if ($auth -match '(?i)deepseek') { Write-Host 'DeepSeek credentials: ok' }
else { Write-Warning 'DeepSeek credentials: missing. Run:  opencode auth login   and choose DeepSeek.' }
Write-Host ''
Write-Host "Done. In Claude Code, type /deepseek-subagent <task> or ask it to 'use deepseek'."
