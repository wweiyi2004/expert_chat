param([Parameter(Mandatory=$true)][string]$ReportDirectory, [Parameter(Mandatory=$true)][string]$ExpectedExecutable)
$ErrorActionPreference = 'Stop'
$ExpectedExecutable = [IO.Path]::GetFullPath($ExpectedExecutable)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName Accessibility
Add-Type -Path (Join-Path $PSScriptRoot 'acceptance_msaa_probe.cs') -ReferencedAssemblies @([Accessibility.IAccessible].Assembly.Location, 'System.dll', 'System.Core.dll')
$taskWindowFile = Join-Path $ReportDirectory 'uia-window.json'
$taskDeadline = (Get-Date).AddSeconds(90)
while (!(Test-Path -LiteralPath $taskWindowFile) -and (Get-Date) -lt $taskDeadline) { Start-Sleep -Milliseconds 200 }
if (!(Test-Path -LiteralPath $taskWindowFile)) { throw 'Acceptance window did not start' }
$taskProcessId = (Get-Content -LiteralPath $taskWindowFile -Raw | ConvertFrom-Json).pid
$taskSamples = 0
$taskMaxNodes = 0
$taskMarkerSeen = $false
$taskSendSeen = $false
$taskErrors = 0
$taskMsaaNodes = 0
$taskMsaaMarker = $false
$taskMsaaSend = $false
$taskTimer = [Diagnostics.Stopwatch]::StartNew()
while ($taskTimer.Elapsed.TotalSeconds -lt 40) {
  $taskProcess = Get-Process -Id $taskProcessId -ErrorAction SilentlyContinue
  if ($null -eq $taskProcess) { break }
  try {
    if (![string]::Equals($taskProcess.MainModule.FileName, $ExpectedExecutable, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected process for UIA acceptance' }
    $taskMsaa = [AcceptanceMsaaProbe]::Read($taskProcess.MainWindowHandle)
    $taskMsaaNodes = [Math]::Max($taskMsaaNodes, $taskMsaa.Nodes)
    $taskMsaaMarker = $taskMsaaMarker -or $taskMsaa.Marker
    $taskMsaaSend = $taskMsaaSend -or $taskMsaa.Send
    $taskWindow = [System.Windows.Automation.AutomationElement]::FromHandle($taskProcess.MainWindowHandle)
    if ($null -ne $taskWindow) {
      $taskNodes = $taskWindow.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
      $taskMaxNodes = [Math]::Max($taskMaxNodes, $taskNodes.Count)
      for ($taskIndex=0; $taskIndex -lt $taskNodes.Count; $taskIndex++) {
        $taskName = $taskNodes.Item($taskIndex).Current.Name
        if ($taskName.Contains('acceptance-uia-marker')) { $taskMarkerSeen = $true }
        if ($taskName -eq '发送') { $taskSendSeen = $true }
      }
      $taskSamples++
    }
  } catch { $taskErrors++ }
  Start-Sleep -Milliseconds 120
}
@{ samples=$taskSamples; maxNodes=$taskMaxNodes; markerSeen=$taskMarkerSeen; sendButtonSeen=$taskSendSeen; readErrors=$taskErrors; msaaNodes=$taskMsaaNodes; msaaMarker=$taskMsaaMarker; msaaSend=$taskMsaaSend } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReportDirectory 'uia-probe-result.json') -Encoding UTF8
