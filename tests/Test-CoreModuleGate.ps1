$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$setup = Get-Content -Raw -LiteralPath (Join-Path $root 'setup-vivobook.sh')
$builder = Get-Content -Raw -LiteralPath (Join-Path $root 'build-vivobook-iso.sh')
$coreModules = @{
    'wcn-regulator-fix' = 'wcn_regulator_fix.c'
    'vivobook-kbd-fix' = 'vivobook_kbd_fix.c'
    'vivobook-bl-fix' = 'vivobook_bl_fix.c'
    'vivobook-hotkey-fix' = 'vivobook_hotkey_fix.c'
}
foreach ($module in $coreModules.Keys) {
    if ($setup -notmatch [regex]::Escape($module)) { throw "Setup does not gate missing core module: $module" }
    if ($builder -notmatch [regex]::Escape($module)) { throw "Builder does not audit missing core module: $module" }
    $moduleDirectory = Join-Path $root "modules/$module-1.0"
    foreach ($file in $coreModules[$module],'Makefile','dkms.conf') {
        if (-not (Test-Path -LiteralPath (Join-Path $moduleDirectory $file) -PathType Leaf)) {
            throw "Repository core module package is incomplete: $module-1.0/$file"
        }
    }
}
if ($setup -notmatch 'CORE_DKMS_MISSING') { throw 'Setup lacks aggregate missing-module gate' }
if ($builder -notmatch 'CORE_DKMS_MISSING') { throw 'Builder lacks aggregate missing-module report' }
Write-Output 'PASS: repository, setup and builder cover every core DKMS source package'
