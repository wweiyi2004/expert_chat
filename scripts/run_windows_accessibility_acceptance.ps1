param([string]$ReportDirectory = 'output/acceptance')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
Push-Location $taskRoot
try {
  $taskReport = [IO.Path]::GetFullPath((Join-Path $taskRoot $ReportDirectory))
  New-Item -ItemType Directory -Path $taskReport -Force | Out-Null
  foreach ($taskName in @('uia-window.json', 'uia-probe-result.json', 'uia-dart-result.json')) {
    $taskFile = Join-Path $taskReport $taskName
    if (Test-Path -LiteralPath $taskFile) { Remove-Item -LiteralPath $taskFile }
  }
  $taskProbe = Join-Path $PSScriptRoot 'probe_acceptance_uia.ps1'
  $taskExe = Join-Path $taskRoot 'build/windows/x64/runner/Debug/expert_chat.exe'
  $taskPowerShell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
  $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ReportDirectory "{1}" -ExpectedExecutable "{2}"' -f $taskProbe, $taskReport, $taskExe
  $taskHelper = Start-Process -FilePath $taskPowerShell -ArgumentList $taskArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskReport 'probe.stdout.log') -RedirectStandardError (Join-Path $taskReport 'probe.stderr.log')
  # Retain the native handle before the short-lived helper exits; otherwise
  # Windows PowerShell may return a null ExitCode for Start-Process -PassThru.
  $null = $taskHelper.Handle
  try {
    & flutter test --no-pub integration_test/windows_uia_acceptance_test.dart -d windows --dart-define=EXPERT_CHAT_UIA_ACCEPTANCE=true "--dart-define=ACCEPTANCE_REPORT_DIR=$($taskReport.Replace('\', '/'))" --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw 'Native accessibility acceptance failed' }
    if (!$taskHelper.WaitForExit(10000)) { throw 'Native probe did not finish' }
    if ($taskHelper.ExitCode -ne 0) { throw 'Native probe failed' }
    $taskResult = Get-Content -LiteralPath (Join-Path $taskReport 'uia-dart-result.json') -Raw | ConvertFrom-Json
    if ($taskResult.status -ne 'passed') { throw 'Acceptance result was not passed' }
  } finally {
    if (!$taskHelper.HasExited) { $taskHelper.Kill(); $taskHelper.WaitForExit() }
  }
} finally {
  Pop-Location
}
