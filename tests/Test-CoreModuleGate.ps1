$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$setup = Get-Content -Raw -LiteralPath (Join-Path $root 'setup-vivobook.sh')
$builder = Get-Content -Raw -LiteralPath (Join-Path $root 'build-vivobook-iso.sh')
foreach ($module in 'wcn-regulator-fix','vivobook-kbd-fix','vivobook-bl-fix','vivobook-hotkey-fix') {
    if ($setup -notmatch [regex]::Escape($module)) { throw "Setup does not gate missing core module: $module" }
    if ($builder -notmatch [regex]::Escape($module)) { throw "Builder does not audit missing core module: $module" }
}
if ($setup -notmatch 'CORE_DKMS_MISSING') { throw 'Setup lacks aggregate missing-module gate' }
if ($builder -notmatch 'CORE_DKMS_MISSING') { throw 'Builder lacks aggregate missing-module report' }
Write-Output 'PASS: setup and builder explicitly gate all missing core DKMS sources'
