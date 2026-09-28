param([string]$DistDirectory = "")
$ErrorActionPreference = 'Stop'
$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ExpectedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ($ServerRoot -ne $ExpectedRoot -or !(Test-Path (Join-Path $ServerRoot 'pyproject.toml'))) { throw 'Unexpected server workspace' }
if (!$DistDirectory) { $DistDirectory = Join-Path $ServerRoot 'dist' }
$DistDirectory = [IO.Path]::GetFullPath($DistDirectory)
$AllowedDist = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'dist'))
if ($DistDirectory -ne $AllowedDist -and !$DistDirectory.StartsWith($AllowedDist + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Build output must stay inside server/dist' }
Push-Location $ServerRoot
try {
    & uv sync --frozen --group packaging
    if ($LASTEXITCODE -ne 0) { throw 'Locked build environment setup failed' }
    & uv run --frozen --group packaging python mcp_server/packaging/check_output.py (Join-Path $DistDirectory 'expert-chat-mcp')
    if ($LASTEXITCODE -ne 0) { throw 'Output directory contains runtime data; use -DistDirectory with a fresh path inside server/dist' }
    & uv run --frozen --group packaging pyinstaller --noconfirm --clean `
        --distpath $DistDirectory `
        --workpath (Join-Path $ServerRoot 'build\pyinstaller') `
        (Join-Path $PSScriptRoot 'expert-chat-mcp.spec')
    if ($LASTEXITCODE -ne 0) { throw 'MCP packaging failed' }
    $Out = Join-Path $DistDirectory 'expert-chat-mcp'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mcp.env.example') -Destination (Join-Path $Out 'mcp.env.example') -Force
    & (Join-Path $Out 'expert-chat-mcp.exe') --version
    if ($LASTEXITCODE -ne 0) { throw 'Packaged executable smoke check failed' }
    Write-Host "Built $Out\expert-chat-mcp.exe"
} finally { Pop-Location }
