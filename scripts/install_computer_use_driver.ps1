param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'ExpertChat/drivers/cua-0.28.0'))
$ErrorActionPreference = 'Stop'
$version = '0.28.0'
$asset = "cua-driver-rs-$version-windows-x86_64-binary.zip"
$expectedHash = '9db2096df8d80da4e73ffb797947dcdfab2a362faddd9d1b77682c77aace5aa9'
$resolvedDestination = [IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Path $resolvedDestination -Force | Out-Null
$archive = Join-Path $resolvedDestination 'cua-driver.zip'
if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
    Invoke-WebRequest -Uri "https://github.com/trycua/cua/releases/download/cua-driver-rs-v$version/$asset" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Driver checksum mismatch' }
# Validate every archive path before extracting into the named directory.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        $target = [IO.Path]::GetFullPath((Join-Path $resolvedDestination $entry.FullName))
        if (!$target.StartsWith($resolvedDestination.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Archive path outside driver directory'
        }
    }
} finally { $zip.Dispose() }
Expand-Archive -LiteralPath $archive -DestinationPath $resolvedDestination -Force
Write-Output (Join-Path $resolvedDestination 'cua-driver.exe')
Write-Output 'Cua Driver 0.28.0 installed locally; no services, startup tasks, or permission changes.'
