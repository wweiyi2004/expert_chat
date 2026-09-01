$ErrorActionPreference = 'Stop'
$ServerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $ServerRoot

if (-not (Test-Path .venv)) {
    python -m venv .venv
}
& .\.venv\Scripts\python.exe -m pip install -U pip
& .\.venv\Scripts\python.exe -m pip install -r mcp_server\requirements.txt
& .\.venv\Scripts\python.exe -m pip install pyinstaller

& .\.venv\Scripts\pyinstaller.exe --noconfirm --clean `
    --distpath (Join-Path $ServerRoot 'dist') `
    --workpath (Join-Path $ServerRoot 'build\pyinstaller') `
    (Join-Path $PSScriptRoot 'expert-chat-mcp.spec')

$Out = Join-Path $ServerRoot 'dist\expert-chat-mcp'
Copy-Item (Join-Path $PSScriptRoot 'mcp.env.example') (Join-Path $Out 'mcp.env.example') -Force
Write-Host "Built $Out\expert-chat-mcp.exe"
Write-Host "Run that exe; it writes mcp.env beside itself on first launch."
