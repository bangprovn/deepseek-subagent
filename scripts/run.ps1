<#
.SYNOPSIS
  Run a DeepSeek subagent through OpenCode, non-interactively. PowerShell port of run.sh.

.EXAMPLE
  .\run.ps1 -Dir C:\proj "Summarize src/auth and list every exported function."
  .\run.ps1 -Worker -Dir C:\proj -Timeout 600 "Add unit tests for src/utils/date.ts"
  .\run.ps1 -Session ses_abc123 "Your RESULT mentions a race in cache.ts:40. Show the exact lines."
  Get-Content brief.md -Raw | .\run.ps1 -Dir C:\proj -

.PARAMETER Worker   Use the deepseek-worker agent (can edit files / run shell).
.PARAMETER Dir      Directory the subagent works in (default: current directory).
.PARAMETER Session  Continue an existing session (two-way conversation).
.PARAMETER Fork     With -Session: branch off instead of continuing in place.
.PARAMETER Model    OpenCode model id (default: $env:DEEPSEEK_SUBAGENT_MODEL or deepseek/deepseek-flash).
.PARAMETER File     File(s) to attach to the message.
.PARAMETER Timeout  Seconds before the run is killed (default 900).
.PARAMETER Out      Also write the final output to this path.
.PARAMETER Log      Append raw JSON events to this path (tail it to watch progress).
.PARAMETER Json     Print one JSON object {session,text,exit,tokens,...} instead of text.
.PARAMETER Quiet    No live progress lines on stderr.
.PARAMETER DryRun   Print the opencode command and exit.
.PARAMETER Prompt   The brief. Pass "-" to read it from stdin.

Output ends with a trailer:  ---  session: ses_...  exit: N
Exit code is opencode's, or 124 on timeout, 2 on bad arguments, 127 if opencode is missing.
#>
[CmdletBinding()]
param(
  [switch]$Worker,
  [string]$Dir = (Get-Location).Path,
  [string]$Session = '',
  [switch]$Fork,
  [string]$Model = $(if ($env:DEEPSEEK_SUBAGENT_MODEL) { $env:DEEPSEEK_SUBAGENT_MODEL } else { 'deepseek/deepseek-flash' }),
  [string[]]$File = @(),
  [int]$Timeout = 900,
  [string]$Out = '',
  [string]$Log = '',
  [switch]$Json,
  [switch]$Quiet,
  [switch]$DryRun,
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Prompt
)

$ErrorActionPreference = 'Stop'
$Agent = if ($Worker) { 'deepseek-worker' } else { 'deepseek' }

# --- prompt -------------------------------------------------------------------
$text = ($Prompt -join ' ')
if ($text -eq '-') { $text = [Console]::In.ReadToEnd() }
if ([string]::IsNullOrWhiteSpace($text)) {
  [Console]::Error.WriteLine("error: no prompt given (pass as argument or '-' to read stdin)")
  exit 2
}

# --- opencode binary ----------------------------------------------------------
$cmd = Get-Command opencode -ErrorAction SilentlyContinue
if (-not $cmd) { [Console]::Error.WriteLine('error: opencode not found on PATH'); exit 127 }
$exe = $cmd.Source
# npm PowerShell shims cannot be launched with ProcessStartInfo.
if ($exe -match '\.(ps1|cmd|bat)$') {
  $native = Join-Path (Split-Path -Parent $exe) 'node_modules/opencode-ai/bin/opencode.exe'
  if (Test-Path -LiteralPath $native) { $exe = $native }
  elseif ($exe -match '\.ps1$') {
    [Console]::Error.WriteLine('error: only an OpenCode PowerShell shim was found; install the native OpenCode executable on PATH')
    exit 127
  }
}
# An npm .cmd shim goes through cmd.exe, which mangles &, |, %, ^ and newlines in
# arguments. In that case ship the brief as an attached file instead of inline.
$viaShim = $exe -match '\.(cmd|bat)$'

try { $Dir = (Resolve-Path -LiteralPath $Dir).Path } catch {
  [Console]::Error.WriteLine("error: bad -Dir '$Dir'"); exit 2
}

# --- build args ---------------------------------------------------------------
$ocArgs = @('run', '--format', 'json', '--agent', $Agent, '--model', $Model, '--dir', $Dir, '--title', 'deepseek-subagent')
if ($Session) { $ocArgs += @('--session', $Session); if ($Fork) { $ocArgs += '--fork' } }
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

# --- process ------------------------------------------------------------------
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

# Shared state for the event handlers.
$state = @{
  texts = New-Object System.Collections.Generic.List[string]
  plain = New-Object System.Collections.Generic.List[string]
  session = $Session
  tools = 0
  tokIn = 0; tokOut = 0; tokTotal = 0; cost = 0.0
  log = $Log
  quiet = [bool]$Quiet
}

$handler = {
  $line = $EventArgs.Data
  if ($null -eq $line) { return }
  $st = $Event.MessageData
  if ($st.log) { Add-Content -LiteralPath $st.log -Value $line -Encoding UTF8 }
  if ([string]::IsNullOrWhiteSpace($line)) { return }
  $ev = $null
  try { $ev = $line | ConvertFrom-Json -ErrorAction Stop } catch { }
  if ($null -eq $ev -or -not $ev.PSObject.Properties['type']) {
    $st.plain.Add($line)
    if (-not $st.quiet) { [Console]::Error.WriteLine($line) }
    return
  }
  if ($ev.sessionID) { $st.session = $ev.sessionID }
  $part = $ev.part
  switch ($ev.type) {
    'text' { if ($part.text) { $st.texts.Add([string]$part.text) } }
    'tool_use' {
      $st.tools++
      $inp = $part.state.input
      $summ = ''
      if ($inp) {
        foreach ($k in 'filePath','path','command','pattern','url','query','description') {
          if ($inp.PSObject.Properties[$k] -and $inp.$k) { $summ = [string]$inp.$k; break }
        }
      }
      $summ = ($summ -replace "`r?`n", ' ')
      if ($summ.Length -gt 100) { $summ = $summ.Substring(0, 97) + '...' }
      $mark = if ($part.state.status -eq 'error') { 'x' } else { '»' }
      if (-not $st.quiet) { [Console]::Error.WriteLine(("$mark $($part.tool) $summ").TrimEnd()) }
    }
    'step_finish' {
      $tk = $part.tokens
      if ($tk) {
        $st.tokIn += [int]($tk.input); $st.tokOut += [int]($tk.output); $st.tokTotal += [int]($tk.total)
      }
      if ($part.cost) { $st.cost += [double]$part.cost }
    }
    'error' {
      $msg = ($ev.error | ConvertTo-Json -Compress -Depth 5)
      $st.plain.Add("Error: $msg")
      if (-not $st.quiet) { [Console]::Error.WriteLine("x error $msg") }
    }
  }
}

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$subs = @()
$subs += Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $handler -MessageData $state
$subs += Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $handler -MessageData $state

[void]$proc.Start()
$proc.StandardInput.Close()
$proc.BeginOutputReadLine()
$proc.BeginErrorReadLine()

# Poll instead of WaitForExit(ms) so event actions run and progress is live.
$deadline = (Get-Date).AddSeconds($Timeout)
$timedOut = $false
while (-not $proc.HasExited) {
  if ((Get-Date) -gt $deadline) {
    $timedOut = $true
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { & taskkill /T /F /PID $proc.Id 2>$null | Out-Null }
    else { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    break
  }
  Start-Sleep -Milliseconds 150
}
$proc.WaitForExit()          # flush async readers
Start-Sleep -Milliseconds 200 # let queued event actions drain
$subs | ForEach-Object { Unregister-Event -SourceIdentifier $_.Name -ErrorAction SilentlyContinue }
if ($briefFile) { Remove-Item -LiteralPath $briefFile -ErrorAction SilentlyContinue }

$rc = if ($timedOut) { 124 } else { $proc.ExitCode }
$final = ($state.texts -join "`n`n").Trim()
if ($timedOut) { $state.plain.Add("error: subagent timed out after ${Timeout}s") }
if ($rc -eq 0 -and -not $final -and $state.plain.Count -gt 0) { $rc = 1 }

if ($Json) {
  $obj = [ordered]@{
    session = $state.session; exit = $rc; text = $final; errors = @($state.plain)
    tools = $state.tools
    tokens = [ordered]@{ input = $state.tokIn; output = $state.tokOut; total = $state.tokTotal }
    cost = [math]::Round($state.cost, 6); dir = $Dir; agent = $Agent; model = $Model
  }
  $outText = $obj | ConvertTo-Json -Depth 5
} else {
  $parts = @()
  if ($final) { $parts += $final }
  if ($state.plain.Count -gt 0) { $parts += ($state.plain -join "`n") }
  $sess = if ($state.session) { $state.session } else { 'unknown' }
  $parts += '---'
  $parts += "session: $sess"
  $parts += ("agent: {0}  model: {1}  tools: {2}  tokens: in={3} out={4}  cost: `${5:N4}" -f $Agent, $Model, $state.tools, $state.tokIn, $state.tokOut, $state.cost)
  $parts += "exit: $rc"
  $outText = $parts -join "`n"
}

Write-Output $outText
if ($Out) { [IO.File]::WriteAllText($Out, $outText + "`n", (New-Object Text.UTF8Encoding $false)) }
exit $rc
