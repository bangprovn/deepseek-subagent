<#
.SYNOPSIS
  Run a DeepSeek subagent through OpenCode, non-interactively. PowerShell port of run.sh.

.EXAMPLE
  .\run.ps1 -Dir C:\proj "Summarize src/auth and list every exported function."
  .\run.ps1 -Worker -Dir C:\proj -Timeout 600 "Add unit tests for src/utils/date.ts"
  Get-Content brief.md -Raw | .\run.ps1 -Dir C:\proj -

.PARAMETER Worker   Use the deepseek-worker agent (can edit files / run shell).
.PARAMETER Dir      Directory the subagent works in (default: current directory).
.PARAMETER Model    OpenCode model id (default: $env:DEEPSEEK_SUBAGENT_MODEL or deepseek/deepseek-flash).
.PARAMETER File     File(s) to attach to the message.
.PARAMETER Timeout  Seconds before the run is killed (default 900).
.PARAMETER Out      Also write cleaned output to this path.
.PARAMETER Raw      Keep ANSI codes and banner instead of stripping them.
.PARAMETER DryRun   Print the opencode command and exit.
.PARAMETER Prompt   The brief. Pass "-" to read it from stdin.

Exit code is opencode's exit code, or 124 on timeout, 2 on bad arguments, 127 if opencode is missing.
#>
[CmdletBinding()]
param(
  [switch]$Worker,
  [string]$Dir = (Get-Location).Path,
  [string]$Model = $(if ($env:DEEPSEEK_SUBAGENT_MODEL) { $env:DEEPSEEK_SUBAGENT_MODEL } else { 'deepseek/deepseek-flash' }),
  [string[]]$File = @(),
  [int]$Timeout = 900,
  [string]$Out = '',
  [switch]$Raw,
  [switch]$DryRun,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Prompt
)

$ErrorActionPreference = 'Stop'
$Agent = if ($Worker) { 'deepseek-worker' } else { 'deepseek' }

# --- prompt -------------------------------------------------------------------
$text = ($Prompt -join ' ')
if ($text -eq '-') {
  $text = [Console]::In.ReadToEnd()
}
if ([string]::IsNullOrWhiteSpace($text)) {
  [Console]::Error.WriteLine("error: no prompt given (pass as argument or '-' to read stdin)")
  exit 2
}

# --- opencode binary ----------------------------------------------------------
$cmd = Get-Command opencode -ErrorAction SilentlyContinue
if (-not $cmd) {
  [Console]::Error.WriteLine('error: opencode not found on PATH')
  exit 127
}
$exe = $cmd.Source
# An npm .cmd shim goes through cmd.exe, which mangles &, |, %, ^ and newlines in
# arguments. In that case ship the brief as an attached file instead of inline.
$viaShim = $exe -match '\.(cmd|bat)$'

try { $Dir = (Resolve-Path -LiteralPath $Dir).Path } catch {
  [Console]::Error.WriteLine("error: bad -Dir '$Dir'")
  exit 2
}

# --- build args ---------------------------------------------------------------
$ocArgs = @('run', '--agent', $Agent, '--model', $Model, '--dir', $Dir, '--format', 'default', '--title', 'claude-subagent')
foreach ($f in $File) { $ocArgs += @('--file', $f) }

$briefFile = $null
if ($viaShim) {
  $briefFile = Join-Path ([IO.Path]::GetTempPath()) ("deepseek-brief-" + [Guid]::NewGuid().ToString('N') + ".md")
  [IO.File]::WriteAllText($briefFile, $text, (New-Object Text.UTF8Encoding $false))
  $ocArgs += @('--file', $briefFile, '--', 'Your task is in the attached brief file. Follow it exactly and reply as it instructs.')
} else {
  $ocArgs += @('--', $text)
}

function Quote-Arg([string]$a) {
  # Windows CommandLineToArgvW rules: escape backslashes that precede a quote, escape quotes, wrap if needed.
  if ($a -notmatch '[\s"]' -and $a.Length -gt 0) { return $a }
  $s = [regex]::Replace($a, '(\\*)"', '$1$1\"')
  $s = [regex]::Replace($s, '(\\+)$', '$1$1')
  return '"' + $s + '"'
}

if ($DryRun) {
  Write-Output ((@($exe) + $ocArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
  if ($briefFile) { Remove-Item -LiteralPath $briefFile -ErrorAction SilentlyContinue }
  exit 0
}

# --- run with timeout ---------------------------------------------------------
$env:OPENCODE_DISABLE_AUTOUPDATE = '1'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardInput = $true
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = $Dir
if ($psi.PSObject.Properties['ArgumentList']) {
  foreach ($a in $ocArgs) { $psi.ArgumentList.Add($a) }
} else {
  $psi.Arguments = ($ocArgs | ForEach-Object { Quote-Arg $_ }) -join ' '
}

$sb = New-Object System.Text.StringBuilder
$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$handler = { if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
$null = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $handler -MessageData $sb
$null = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $handler -MessageData $sb

[void]$proc.Start()
$proc.StandardInput.Close()
$proc.BeginOutputReadLine()
$proc.BeginErrorReadLine()

$rc = 0
if (-not $proc.WaitForExit($Timeout * 1000)) {
  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    & taskkill /T /F /PID $proc.Id 2>$null | Out-Null
  } else {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
  }
  $proc.WaitForExit()
  [Console]::Error.WriteLine("error: subagent timed out after ${Timeout}s")
  $rc = 124
} else {
  $proc.WaitForExit()   # flush async readers
  $rc = $proc.ExitCode
}
Get-EventSubscriber | Where-Object { $_.SourceObject -eq $proc } | Unregister-Event
if ($briefFile) { Remove-Item -LiteralPath $briefFile -ErrorAction SilentlyContinue }

# --- clean output -------------------------------------------------------------
$outText = $sb.ToString()
if (-not $Raw) {
  $esc = [char]27
  $outText = [regex]::Replace($outText, "$esc\[[0-9;?]*[A-Za-z]", '')
  $lines = $outText -split "`r?`n"
  $lines = $lines | Where-Object { $_ -notmatch '^> [a-z0-9-]+ · ' }
  # drop leading blank lines
  $i = 0; while ($i -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$i])) { $i++ }
  $outText = (($lines | Select-Object -Skip $i) -join [Environment]::NewLine)
}

Write-Output $outText
if ($Out) { [IO.File]::WriteAllText($Out, $outText, (New-Object Text.UTF8Encoding $false)) }
exit $rc
