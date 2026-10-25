param([string]$Destination = 'output/releases/remote-host')
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$target = [IO.Path]::GetFullPath((Join-Path $repository $Destination))
New-Item -ItemType Directory -Force -Path $target | Out-Null
$executable = Join-Path $target 'expert-remote-host.exe'
Push-Location $repository
try {
    & dart compile exe tool/remote_host.dart -o $executable
    if ($LASTEXITCODE -ne 0) { throw 'Remote host compilation failed' }
    $assets = Join-Path $target 'assets/math'
    New-Item -ItemType Directory -Force -Path $assets | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository 'assets/math/toolkit.py') -Destination (Join-Path $assets 'toolkit.py')
    Copy-Item -LiteralPath (Join-Path $repository 'docs/REMOTE-HOST-START.md') -Destination (Join-Path $target 'README.md')
    Copy-Item -LiteralPath (Join-Path $repository 'docs/REMOTE-EXECUTION.md') -Destination (Join-Path $target 'DEVELOPMENT.md')
    $versionLine = Select-String -LiteralPath (Join-Path $repository 'pubspec.yaml') -Pattern '^version:'
    $versionLine.Line.Substring(8).Trim() | Set-Content -LiteralPath (Join-Path $target 'package-version.txt') -Encoding utf8
    $manifest = @('expert-remote-host.exe', 'assets/math/toolkit.py', 'README.md', 'DEVELOPMENT.md', 'package-version.txt') | ForEach-Object {
        $file = Join-Path $target $_
        @{ path = $_; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; bytes = (Get-Item -LiteralPath $file).Length }
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'manifest.json') -Encoding utf8
    Write-Output "Built independent remote host package: $target"
} finally { Pop-Location }
