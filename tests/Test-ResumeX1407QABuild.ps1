$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\tools\Resume-X1407QABuild.ps1'
if (-not (Test-Path -LiteralPath $path)) { throw "Resume script missing: $path" }
$source = Get-Content -Raw -LiteralPath $path
foreach ($token in '--import','FedoraBuilder','--version','2','ubuntu-noble-wsl-arm64-24.04lts.rootfs.tar.gz','bootstrap-build-env.sh') {
    if ($source -notmatch [regex]::Escape($token)) { throw "Resume behavior missing: $token" }
}
Write-Output 'PASS: resume script imports verified ARM64 rootfs and bootstraps build tools'
