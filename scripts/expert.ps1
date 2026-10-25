$ErrorActionPreference = 'Stop'
$candidates = @((Join-Path $PSScriptRoot 'expert-tui.exe'), (Join-Path $PSScriptRoot '..\next\target\release\expert-tui.exe'), (Join-Path $PSScriptRoot '..\next\target\debug\expert-tui.exe'))
foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        & $candidate @args
        exit $LASTEXITCODE
    }
}
Write-Error 'expert-tui is not built. Run cargo build --release --manifest-path next/Cargo.toml -p expert-tui.'
exit 1
