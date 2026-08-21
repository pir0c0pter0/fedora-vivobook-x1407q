$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'kernel/build-linux-7.2-x1407qa.sh'
$verify = Join-Path $root 'kernel/verify-linux-7.2-x1407qa.sh'
$prepare = Join-Path $root 'kernel/prepare-linux-7.2-x1407qa-config.sh'
$usbGuard = Join-Path $root 'kernel/verify-linux-usb-config-preservation.sh'
$manifestWriter = Join-Path $root 'kernel/write-linux-artifact-manifest.sh'

foreach ($path in $build, $verify, $prepare, $usbGuard, $manifestWriter) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required kernel script missing: $path" }
}

$buildText = Get-Content -Raw -LiteralPath $build
foreach ($token in 'aarch64','linux-7.2.tar.xz','f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3','X1407QA_LOCALVERSION','LOCALVERSION="$LOCALVERSION"','X1407QA_REFERENCE_CONFIG','CONFIG_PREPARER','MANIFEST_WRITER','Image','dtbs','modules_install','INSTALL_MOD_PATH') {
    if ($buildText -notmatch [regex]::Escape($token)) { throw "Kernel builder missing required behavior: $token" }
}

$prepareText = Get-Content -Raw -LiteralPath $prepare
foreach ($token in 'olddefconfig','CONFIG_BATTERY_QCOM_BATTMGR','CONFIG_ARM_SCMI_CPUFREQ','CONFIG_ISO9660_FS=y','CONFIG_JOLIET=y','CONFIG_EROFS_FS=y','CONFIG_EROFS_FS_ZIP=y','CONFIG_DM_SNAPSHOT=m','verify-linux-usb-config-preservation.sh','grep -qxF') {
    if ($prepareText -notmatch [regex]::Escape($token)) { throw "Kernel config preparer missing required behavior: $token" }
}

$verifyText = Get-Content -Raw -LiteralPath $verify
foreach ($token in 'file','ARM64','modules.dep','x1p42100-asus-zenbook-a14','7.2.0-x1407qa','CONFIG_ISO9660_FS=y','CONFIG_EROFS_FS=y','CONFIG_EROFS_FS_ZIP=y','CONFIG_DM_SNAPSHOT=m','sha256sum','X1407QA_REFERENCE_CONFIG','verify-linux-usb-config-preservation.sh','rndis_host.ko') {
    if ($verifyText -notmatch [regex]::Escape($token)) { throw "Kernel verifier missing required behavior: $token" }
}

Write-Output 'PASS: Linux 7.2 kernel build and verification scripts are complete'
