$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$collector = Join-Path $root 'camera-ir\collect-hm1092-evidence.sh'
$enabler = Join-Path $root 'camera-ir\enable-hm1092-experimental.sh'
foreach ($path in $collector, $enabler) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing camera IR script: $path" }
    $null = Get-Content -Raw -LiteralPath $path
}
$enableSource = Get-Content -Raw -LiteralPath $enabler
foreach ($token in 'X1407QA','--apply','dry-run','HM1092','QCOM0C99','13041043','refusing') {
    if ($enableSource -notmatch [regex]::Escape($token)) { throw "Missing IR safety token: $token" }
}
if ($enableSource -match 'regulator-(min|max)-microvolt\s*=\s*<[0-9]') {
    throw 'IR activation must not guess regulator voltages'
}
if ($enableSource -match 'echo\s+.*>\s*/sys') {
    throw 'IR activation must not write directly to sysfs'
}
Write-Output 'PASS: camera IR scripts are model-gated and dry-run by default'
