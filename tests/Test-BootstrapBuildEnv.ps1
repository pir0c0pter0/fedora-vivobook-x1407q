$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\tools\bootstrap-build-env.sh'
if (-not (Test-Path -LiteralPath $path)) { throw "Bootstrap missing: $path" }
$source = Get-Content -Raw -LiteralPath $path
foreach ($token in 'aarch64','xorriso','unsquashfs','mksquashfs','dracut','gcc','bc','bison','flex','openssl','rsync','cpio','git') {
    if ($source -notmatch [regex]::Escape($token)) { throw "Bootstrap dependency missing: $token" }
}
Write-Output 'PASS: build bootstrap gates ARM64 and installs ISO/kernel dependencies'
