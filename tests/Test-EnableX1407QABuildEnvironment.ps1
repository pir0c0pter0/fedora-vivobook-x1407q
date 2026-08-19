$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\Enable-X1407QABuildEnvironment.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Environment enabler missing: $scriptPath" }
$source = Get-Content -Raw -LiteralPath $scriptPath
foreach ($token in 'Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform','Enable-Feature','NoRestart','wsl.exe --update') {
    if ($source -notmatch [regex]::Escape($token)) { throw "Missing environment behavior: $token" }
}
Write-Output 'PASS: WSL environment enabler is complete'
