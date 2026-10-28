param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$DartExecutable = 'dart',
    [string]$PythonExecutable = $env:EXPERT_MEDIA_PYTHON
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$target = [IO.Path]::GetFullPath($Destination)
if (!$PythonExecutable) { $PythonExecutable = Join-Path $repository 'server\.venv\Scripts\python.exe' }
if (!(Test-Path -LiteralPath $PythonExecutable -PathType Leaf)) {
    throw 'Media build Python missing. Run uv sync --frozen --group packaging in server, or set EXPERT_MEDIA_PYTHON.'
}
New-Item -ItemType Directory -Force -Path $target | Out-Null
Push-Location $repository
try {
    $dartOutput = Join-Path $target 'dart-build'
    & $DartExecutable build cli --target=bin/expert_host.dart --output $dartOutput
    if ($LASTEXITCODE -ne 0) { throw 'Independent host compilation failed' }
    $bundle = Join-Path $target 'dart-build\bundle'
    Move-Item -LiteralPath (Join-Path $bundle 'bin\expert_host.exe') -Destination (Join-Path $bundle 'bin\expert-host.exe') -Force
    $hostBundle = Join-Path $target 'host'
    New-Item -ItemType Directory -Force -Path $hostBundle | Out-Null
    Get-ChildItem -LiteralPath $bundle | Copy-Item -Destination $hostBundle -Recurse -Force
    & $PythonExecutable -m PyInstaller --noconfirm --onedir --console --name expert-media-worker `
        --distpath $target --workpath (Join-Path $target 'media-build') --specpath (Join-Path $target 'media-build') `
        --collect-submodules pypdf --collect-submodules PIL --collect-submodules zstandard server/desktop_media_worker.py
    if ($LASTEXITCODE -ne 0) { throw 'Independent media worker packaging failed' }
    $assets = Join-Path $target 'data\flutter_assets\assets'
    New-Item -ItemType Directory -Force -Path $assets | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $repository 'assets') | Copy-Item -Destination $assets -Recurse -Force
    Write-Output "Built shared host components at $target"
} finally { Pop-Location }
