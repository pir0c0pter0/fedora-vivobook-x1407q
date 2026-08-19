[CmdletBinding()]
param([string]$BuildRoot = 'C:\LinuxBuild')

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot 'enable-wsl.log'
$operation = 'Enable-Feature'

foreach ($feature in 'Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform') {
    "[$operation] $feature" | Tee-Object -FilePath $logPath -Append
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
    $result | Format-List FeatureName,State,RestartNeeded | Out-String | Tee-Object -FilePath $logPath -Append
}

& wsl.exe --update 2>&1 | Tee-Object -FilePath $logPath -Append
$updateCode = $LASTEXITCODE

$pending = [pscustomobject]@{
    timestamp = (Get-Date).ToString('o')
    wsl_update_exit_code = $updateCode
    reboot_required = $true
}
$pending | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $BuildRoot 'wsl-reboot-required.json')
Write-Output "WSL features enabled. Restart Windows, then resume the build. Log: $logPath"
