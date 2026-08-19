$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'kernel/build-linux-7.2-x1407qa.sh'
$verify = Join-Path $root 'kernel/verify-linux-7.2-x1407qa.sh'

foreach ($path in $build, $verify) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required kernel script missing: $path" }
}

$buildText = Get-Content -Raw -LiteralPath $build
foreach ($token in 'aarch64','linux-7.2.tar.xz','f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3','LOCALVERSION=-x1407qa','olddefconfig','Image','dtbs','modules_install','INSTALL_MOD_PATH','! -name SHA256SUMS','CONFIG_BATTERY_QCOM_BATTMGR','CONFIG_ARM_SCMI_CPUFREQ') {
    if ($buildText -notmatch [regex]::Escape($token)) { throw "Kernel builder missing required behavior: $token" }
}

$verifyText = Get-Content -Raw -LiteralPath $verify
foreach ($token in 'file','ARM64','modules.dep','x1p42100-asus-zenbook-a14','7.2.0-x1407qa','sha256sum') {
    if ($verifyText -notmatch [regex]::Escape($token)) { throw "Kernel verifier missing required behavior: $token" }
}

Write-Output 'PASS: Linux 7.2 kernel build and verification scripts are complete'
