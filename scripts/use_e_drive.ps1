# Force Flutter / Dart / MSBuild / Gradle temp + caches onto E: (avoid full C:).
# Dot-source before flutter commands:
#   . .\scripts\use_e_drive.ps1
#   flutter run -d windows

$ErrorActionPreference = 'Stop'

$dirs = @(
  'E:\wweiyi\tmp',
  'E:\dev\pub-cache',
  'E:\dev\gradle',
  'E:\dev\nuget',
  'E:\dev\android'
)
foreach ($d in $dirs) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$env:TEMP = 'E:\wweiyi\tmp'
$env:TMP = 'E:\wweiyi\tmp'
$env:TMPDIR = 'E:\wweiyi\tmp'
$env:PUB_CACHE = 'E:\dev\pub-cache'
$env:GRADLE_USER_HOME = 'E:\dev\gradle'
$env:NUGET_PACKAGES = 'E:\dev\nuget'
$env:ANDROID_USER_HOME = 'E:\dev\android'

Write-Host 'Using E: for build temps/caches:' -ForegroundColor Cyan
Write-Host "  TEMP/TMP = $env:TEMP"
Write-Host "  PUB_CACHE = $env:PUB_CACHE"
Write-Host "  GRADLE_USER_HOME = $env:GRADLE_USER_HOME"
Write-Host "  NUGET_PACKAGES = $env:NUGET_PACKAGES"
