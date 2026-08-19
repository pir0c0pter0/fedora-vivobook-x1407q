$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\Export-X1407QAFirmware.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Exporter missing: $scriptPath"
}

$source = Get-Content -Raw -LiteralPath $scriptPath
$required = @(
    'FileRepository', 'qcadsp', 'qccdsp', 'qcdx', 'qcwlan', 'qcbt',
    'qcsubsys', 'HM1092', 'QCOM0C99', 'CameraAuxSensor', 'Spectra',
    '13041043', 'SHA256', 'firmware-catalog.json', 'manifest-sha256.txt'
)

foreach ($token in $required) {
    if ($source -notmatch [regex]::Escape($token)) {
        throw "Required acquisition token missing: $token"
    }
}

$forbidden = @('Remove-Item', 'Clear-Content', 'Move-Item', 'Format-Volume', 'diskpart', 'Set-Content $Source')
foreach ($token in $forbidden) {
    if ($source -match [regex]::Escape($token)) {
        throw "Forbidden source-mutating operation present: $token"
    }
}

if ($source -notmatch "-replace '\\\\', '/'") {
    throw 'Windows path separator must be escaped as a literal backslash regex'
}

Write-Output 'PASS: exporter contains required acquisition and safety behavior'
