[CmdletBinding()]
param([string]$BuildRoot = 'C:\LinuxBuild')

$ErrorActionPreference = 'Stop'
$distro = 'FedoraBuilder'
$installLocation = Join-Path $BuildRoot 'wsl\FedoraBuilder'
$rootfs = Join-Path $BuildRoot 'downloads\wsl\ubuntu-noble-wsl-arm64-24.04lts.rootfs.tar.gz'
$bootstrapWindows = Join-Path $BuildRoot 'source\fedora-vivobook-x1407q-main\tools\bootstrap-build-env.sh'
$rootfsSha256 = 'E113B8C49AF3AB49B992B8E29550FC921E689F211ABC338176F8243786173A32'

if (-not (Test-Path -LiteralPath $rootfs)) { throw "ARM64 rootfs missing: $rootfs" }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $rootfs).Hash -ne $rootfsSha256) { throw "ARM64 rootfs checksum mismatch: $rootfs" }
if (-not (Test-Path -LiteralPath $bootstrapWindows)) { throw "Bootstrap script missing: $bootstrapWindows" }
New-Item -ItemType Directory -Force -Path $installLocation | Out-Null

& wsl.exe --status | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'WSL is not ready. Restart Windows after enabling the features.' }

$installed = (& wsl.exe --list --quiet 2>$null) -replace "`0", ''
if ($distro -notin $installed) {
    & wsl.exe --set-default-version 2
    if ($LASTEXITCODE -ne 0) { throw 'Unable to select WSL2.' }
    & wsl.exe --import $distro $installLocation $rootfs --version 2
    if ($LASTEXITCODE -ne 0) { throw 'ARM64 WSL import failed.' }
}

$bootstrapWslInput = $bootstrapWindows.Replace('\', '/')
$buildRootWslInput = $BuildRoot.Replace('\', '/')
$bootstrap = (& wsl.exe -d $distro -u root -- wslpath -a -u $bootstrapWslInput).Trim()
$buildRootLinux = (& wsl.exe -d $distro -u root -- wslpath -a -u $buildRootWslInput).Trim()
& wsl.exe -d $distro -u root -- env "BUILD_ROOT=$buildRootLinux" bash $bootstrap
if ($LASTEXITCODE -ne 0) { throw 'Linux build environment bootstrap failed.' }

[pscustomobject]@{
    distro = $distro
    install_location = $installLocation
    bootstrap_complete = $true
    timestamp = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $BuildRoot 'wsl-ready.json')

Write-Output 'WSL ARM64 builder is ready. Resume ISO construction.'
