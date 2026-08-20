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
        $filePath = Join-Path $moduleDirectory $file
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Repository core module package is incomplete: $module-1.0/$file"
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash.ToLowerInvariant()
        if ($setup -notmatch [regex]::Escape("modules/$module-1.0/${file}:$hash")) {
            throw "Setup lacks blocking provenance: $module-1.0/$file"
        }
    }
    $dkms = Get-Content -Raw -LiteralPath (Join-Path $moduleDirectory 'dkms.conf')
    if ($dkms -notmatch 'AUTOINSTALL="no"') { throw "Unsafe AUTOINSTALL: $module" }
}
if ($setup -notmatch 'CORE_DKMS_MISSING') { throw 'Setup lacks aggregate missing-module gate' }
if ($builder -notmatch 'CORE_DKMS_MISSING') { throw 'Builder lacks aggregate missing-module report' }
foreach ($token in 'preflight_core_paths','build_core_dkms_modules','verify_core_dkms_vermagic',
    'install_built_core_dkms_modules','publish_initramfs_candidate') {
    if ($setup -notmatch [regex]::Escape($token)) { throw "Setup lacks safety phase: $token" }
}
Write-Output 'PASS: repository, setup and builder cover every core DKMS source package'
