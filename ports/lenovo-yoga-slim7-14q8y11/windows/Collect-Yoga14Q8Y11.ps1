#Requires -Version 5.1
[CmdletBinding()]
param([string]$Destination)

function Write-CaptureJson {
    param($Value, [string]$Path)
    ConvertTo-Json -InputObject $Value -Depth 16 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-CaptureDirectory {
    param([string]$Destination, [string]$WindowsRoot)
    if ([string]::IsNullOrWhiteSpace($Destination) -or $Destination.StartsWith('\\')) {
        throw 'Use uma pasta local ou uma unidade USB como destino.'
    }
    $path = [IO.Path]::GetFullPath($Destination)
    if ($path -ne [IO.Path]::GetPathRoot($path)) { $path = $path.TrimEnd([char[]]'\/') }
    $windows = [IO.Path]::GetFullPath($WindowsRoot).TrimEnd([char[]]'\/')
    if ($path -eq $windows -or $path.StartsWith($windows + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'O destino nao pode ficar dentro da pasta Windows.'
    }
    $ancestor = $path
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'O destino e seus pais precisam ser pastas normais, sem links ou junctions.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($ancestor)
        if ($parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    $name = 'Yoga-14Q8Y11-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $result = Join-Path $path $name
    New-Item -ItemType Directory -Path $result -ErrorAction Stop | Out-Null
    return $result
}

function Invoke-CaptureCommand {
    param([string]$Executable, [string[]]$Arguments, [string]$Log, [int]$MaximumExitCode = 0)
    Get-Command $Executable -ErrorAction Stop | Out-Null
    # Windows PowerShell can turn native stderr into errors before LASTEXITCODE is checked.
    $ErrorActionPreference = 'Continue'
    & $Executable @Arguments 2>&1 | Out-File -LiteralPath $Log -Encoding UTF8
    $code = $LASTEXITCODE
    if ($code -lt 0 -or $code -gt $MaximumExitCode) {
        throw "$Executable retornou $code. Consulte $Log"
    }
}

function Copy-CaptureTree {
    param([string]$Source, [string]$Target, [string]$Log, [string[]]$Patterns = @('*'))
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Origem nao encontrada: $Source" }
    New-Item -ItemType Directory -Path $Target -Force -ErrorAction Stop | Out-Null
    Invoke-CaptureCommand 'robocopy.exe' (@($Source, $Target) + $Patterns + @(
        '/E', '/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/XJ', '/NP', '/NFL', '/NDL'
    )) $Log 7
}

function Invoke-CaptureStep {
    param([string]$Name, [scriptblock]$Action)
    Write-Host "[$Name]" -ForegroundColor Cyan
    $record = [ordered]@{ name = $Name; status = 'ok'; started = (Get-Date).ToString('o'); error = $null }
    try { & $Action | Out-Null }
    catch {
        $record.status = 'incomplete'
        $record.error = $_.Exception.Message
        Write-Warning "$Name : $($record.error)"
    }
    $record.finished = (Get-Date).ToString('o')
    $script:CaptureSteps.Add([pscustomobject]$record)
    Write-CaptureJson @($script:CaptureSteps.ToArray()) (Join-Path $script:CaptureRoot 'steps.json')
}

function Save-AcpiTable {
    param([byte[]]$Bytes, [string]$Path)
    if ($Bytes.Length -lt 36) { throw 'Tabela ACPI sem cabecalho completo.' }
    $signature = [Text.Encoding]::ASCII.GetString($Bytes, 0, 4)
    # MSDM contains the OEM Windows key; it is unrelated to the Linux port.
    if ($signature -in @('MSDM', 'SLIC')) { return $false }
    $length = [BitConverter]::ToUInt32($Bytes, 4)
    if ($signature -notmatch '^[A-Z0-9_!]{4}$' -or $length -lt 36 -or $length -gt $Bytes.Length) {
        throw 'Comprimento ou assinatura ACPI invalido.'
    }
    if ($signature -eq 'FACS' -and $length -lt 64) { throw 'FACS truncada.' }
    [byte[]]$table = $Bytes[0..($length - 1)]
    # FACS has no DESCRIPTION_HEADER checksum; other ACPI tables do.
    if ($signature -ne 'FACS') {
        $sum = 0
        foreach ($value in $table) { $sum = ($sum + $value) -band 255 }
        if ($sum -ne 0) { throw "Checksum ACPI invalido: $signature" }
    }
    [IO.File]::WriteAllBytes($Path, $table)
    return $true
}

function Write-CaptureManifest {
    param([string]$Root)
    $errors = [Collections.Generic.List[string]]::new()
    $enumerationErrors = @()
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Continue -ErrorVariable enumerationErrors)
    foreach ($errorRecord in $enumerationErrors) { $errors.Add($errorRecord.ToString()) }
    $rows = foreach ($file in $files) {
        if ($file.FullName -in @((Join-Path $Root 'manifest-sha256.csv'), (Join-Path $Root 'hash-errors.json'))) { continue }
        try {
            [pscustomobject]@{
                path = $file.FullName.Substring($Root.Length).TrimStart([char[]]'\/').Replace('\', '/')
                bytes = $file.Length
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            }
        }
        catch { $errors.Add("$($file.FullName): $($_.Exception.Message)") }
    }
    Write-CaptureJson @($errors.ToArray()) (Join-Path $Root 'hash-errors.json')
    $rows | Export-Csv -LiteralPath (Join-Path $Root 'manifest-sha256.csv') -NoTypeInformation -Encoding UTF8
    return $errors.Count
}

if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($env:OS -ne 'Windows_NT') { throw 'Execute este script no Windows do Lenovo.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Abra o Windows PowerShell como Administrador e execute novamente.'
}
$system = Get-CimInstance Win32_ComputerSystem
$product = Get-CimInstance Win32_ComputerSystemProduct
$cpus = @(Get-CimInstance Win32_Processor)
if ($system.Manufacturer -notmatch 'LENOVO' -or
    ($system.Model -notmatch '^83QR' -and $product.Version -notmatch 'Yoga Slim 7 14Q8Y11') -or
    @($cpus | Where-Object { $_.Architecture -ne 12 }).Count -gt 0 -or $cpus.Count -eq 0) {
    throw 'Alvo inesperado: este coletor e para o Lenovo Yoga Slim 7 14Q8Y11 ARM64.'
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') {
    throw 'Use o Windows PowerShell nativo ARM64 em C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe.'
}
if (-not $Destination) { $Destination = Read-Host 'Pasta de destino, por exemplo E:\Yoga-Coletas (reserve 30 GB livres)' }
$script:CaptureRoot = New-CaptureDirectory $Destination $env:SystemRoot
$script:CaptureSteps = [Collections.Generic.List[object]]::new()
$script:CaptureSources = [Collections.Generic.List[object]]::new()
foreach ($directory in @('inventory', 'logs', 'acpi', 'edid', 'colors')) {
    New-Item -ItemType Directory -Path (Join-Path $script:CaptureRoot $directory) | Out-Null
}
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $script:CaptureRoot 'collector.ps1')
Write-Host "Destino: $script:CaptureRoot"
Write-Host 'Coleta local. Nenhum arquivo sera enviado pela rede. Aguarde a geracao do RESUMO.txt.'

Invoke-CaptureStep 'identification' {
    Write-CaptureJson ([ordered]@{
        date = (Get-Date).ToString('o'); powershell = $PSVersionTable.PSVersion.ToString()
        system = $system | Select-Object Manufacturer, Model, SystemFamily, SystemSKUNumber, TotalPhysicalMemory
        product = $product | Select-Object Vendor, Name, Version, SKUNumber
        cpu = @($cpus | Select-Object Name, Manufacturer, Architecture, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)
        bios = Get-CimInstance Win32_BIOS | Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate
        os = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
    }) (Join-Path $script:CaptureRoot 'inventory/identification.json')
}

Invoke-CaptureStep 'storage-layout' {
    Write-CaptureJson ([ordered]@{
        disks = @(Get-Disk | Select-Object Number, FriendlyName, BusType, PartitionStyle, Size, LogicalSectorSize, PhysicalSectorSize, IsBoot, IsSystem)
        partitions = @(Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, Offset, Size, Type, GptType, IsBoot, IsSystem)
    }) (Join-Path $script:CaptureRoot 'inventory/storage-layout.json')
}

foreach ($class in @('Win32_PnPEntity', 'Win32_PnPSignedDriver', 'Win32_PnPAllocatedResource',
    'Win32_DeviceMemoryAddress', 'Win32_IRQResource', 'Win32_DMAChannel', 'Win32_PortResource',
    'Win32_VideoController', 'Win32_SoundDevice', 'Win32_Battery')) {
    Invoke-CaptureStep "cim-$class" {
        $values = @(Get-CimInstance -ClassName $class -ErrorAction Stop | ForEach-Object {
            $row = [ordered]@{}
            foreach ($property in $_.CimInstanceProperties) { $row[$property.Name] = $property.Value }
            [pscustomobject]$row
        })
        Write-CaptureJson $values (Join-Path $script:CaptureRoot "inventory/$class.json")
    }
}

Invoke-CaptureStep 'pnp-properties' {
    $folder = Join-Path $script:CaptureRoot 'inventory/pnp-properties'
    New-Item -ItemType Directory -Path $folder | Out-Null
    $failures = [Collections.Generic.List[string]]::new()
    $index = 0
    foreach ($device in Get-PnpDevice -PresentOnly -ErrorAction Stop) {
        try {
            $properties = @(Get-PnpDeviceProperty -InstanceId $device.InstanceId -ErrorAction Stop |
                Select-Object KeyName, Type, Data)
            Write-CaptureJson ([ordered]@{ instance_id = $device.InstanceId; properties = $properties }) (
                Join-Path $folder ('{0:D5}.json' -f $index))
        }
        catch { $failures.Add("$($device.InstanceId): $($_.Exception.Message)") }
        $index++
    }
    Write-CaptureJson @($failures.ToArray()) (Join-Path $folder 'errors.json')
    if ($failures.Count) { throw "$($failures.Count) dispositivos com propriedades incompletas; veja errors.json." }
}

Invoke-CaptureStep 'pnp-devices' {
    Invoke-CaptureCommand 'pnputil.exe' @('/enum-devices', '/connected', '/deviceids', '/relations', '/drivers', '/resources') (
        Join-Path $script:CaptureRoot 'logs/pnp-devices.txt')
}
Invoke-CaptureStep 'driver-list' {
    Invoke-CaptureCommand 'pnputil.exe' @('/enum-drivers', '/files') (Join-Path $script:CaptureRoot 'logs/pnp-drivers.txt')
}

Invoke-CaptureStep 'acpi-native' {
    if (-not ('YogaFirmwareReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class YogaFirmwareReader {
    const uint Provider = 0x41435049; // ACPI provider, distinct from little-endian table IDs.
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint EnumSystemFirmwareTables(uint provider, [Out] byte[] buffer, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint GetSystemFirmwareTable(uint provider, uint id, [Out] byte[] buffer, uint size);
    public static byte[] Read(uint id, bool enumerate) {
        uint size = enumerate ? EnumSystemFirmwareTables(Provider, null, 0) : GetSystemFirmwareTable(Provider, id, null, 0);
        if (size == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (size > 64 * 1024 * 1024) throw new InvalidOperationException("Firmware table exceeds 64 MiB.");
        byte[] data = new byte[size];
        uint read = enumerate ? EnumSystemFirmwareTables(Provider, data, size) : GetSystemFirmwareTable(Provider, id, data, size);
        if (read == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (read > size) throw new InvalidOperationException("Firmware changed during collection; repeat collection.");
        if (read < size) Array.Resize(ref data, (int)read);
        return data;
    }
}
'@
    }
    $ids = [YogaFirmwareReader]::Read(0, $true)
    if ($ids.Length % 4) { throw 'Lista de tabelas ACPI invalida.' }
    $tables = [Collections.Generic.List[object]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $ids.Length; $i += 4) {
        $id = [BitConverter]::ToUInt32($ids, $i)
        $signature = [Text.Encoding]::ASCII.GetString($ids, $i, 4)
        if ($signature -in @('MSDM', 'SLIC')) { continue }
        try {
            $relative = 'acpi/native-{0:D4}.dat' -f ($i / 4)
            $saved = Save-AcpiTable ([YogaFirmwareReader]::Read($id, $false)) (Join-Path $script:CaptureRoot $relative)
            if ($saved) { $tables.Add([pscustomobject]@{ signature = $signature; id = $id; path = $relative }) }
        }
        catch { $failures.Add("$signature : $($_.Exception.Message)") }
    }
    Write-CaptureJson ([ordered]@{
        tables = @($tables.ToArray()); errors = @($failures.ToArray())
        limitation = 'GetSystemFirmwareTable returns only the first table for duplicate signatures (e.g. SSDT). Registry capture complements it but does not guarantee all SSDTs.'
    }) (Join-Path $script:CaptureRoot 'acpi/native-index.json')
    if ($tables.Count -eq 0 -or $failures.Count) { throw 'Coleta ACPI nativa incompleta; veja native-index.json.' }
}

foreach ($registrySource in @(
    @{ name = 'acpi-registry'; key = 'Registry::HKEY_LOCAL_MACHINE\HARDWARE\ACPI' },
    @{ name = 'edid-registry'; key = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\DISPLAY' }
)) {
    Invoke-CaptureStep $registrySource.name {
        $records = [Collections.Generic.List[object]]::new()
        $failures = [Collections.Generic.List[string]]::new()
        $registryErrors = @()
        $keys = @(
            if ($registrySource.name -eq 'edid-registry') {
                # EDID lives under Device Parameters; sibling Properties keys have protected ACLs.
                foreach ($monitor in Get-ChildItem -LiteralPath $registrySource.key -ErrorAction Continue -ErrorVariable +registryErrors) {
                    foreach ($instance in Get-ChildItem -LiteralPath $monitor.PSPath -ErrorAction Continue -ErrorVariable +registryErrors) {
                        $parameters = $instance.PSPath + '\Device Parameters'
                        if (Test-Path -LiteralPath $parameters -ErrorAction Continue -ErrorVariable +registryErrors) {
                            Get-Item -LiteralPath $parameters -ErrorAction Continue -ErrorVariable +registryErrors
                        }
                    }
                }
            }
            else {
                Get-Item -LiteralPath $registrySource.key -ErrorAction Stop
                Get-ChildItem -LiteralPath $registrySource.key -Recurse -ErrorAction Continue -ErrorVariable +registryErrors
            }
        )
        foreach ($err in $registryErrors) { $failures.Add($err.ToString()) }
        foreach ($key in $keys) {
            try {
                foreach ($valueName in $key.GetValueNames()) {
                    $data = $key.GetValue($valueName)
                    if ($data -isnot [byte[]]) { continue }
                    $isEdid = $registrySource.name -eq 'edid-registry'
                    if ($isEdid -and $valueName -ne 'EDID') { continue }
                    $relative = '{0}/{1}-{2:D4}.dat' -f $(if ($isEdid) { 'edid' } else { 'acpi' }), $registrySource.name, $records.Count
                    $target = Join-Path $script:CaptureRoot $relative
                    if ($isEdid) { [IO.File]::WriteAllBytes($target, $data) }
                    elseif (-not (Save-AcpiTable $data $target)) { continue }
                    $records.Add([pscustomobject]@{ registry = $key.Name; value = $valueName; path = $relative; bytes = $data.Length })
                }
            }
            catch { $failures.Add("$($key.Name): $($_.Exception.Message)") }
        }
        Write-CaptureJson ([ordered]@{ values = @($records.ToArray()); errors = @($failures.ToArray()) }) (
            Join-Path $script:CaptureRoot ($registrySource.name + '.json'))
        if ($records.Count -eq 0 -or $failures.Count) { throw 'Leitura do registro incompleta; veja o indice JSON desta etapa.' }
    }
}

foreach ($registryColor in @(
    @{ name = 'machine-icm'; key = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM' },
    @{ name = 'user-icm'; key = 'HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM' }
)) {
    if (-not (Test-Path -LiteralPath ('Registry::' + $registryColor.key.Replace('HKLM\', 'HKEY_LOCAL_MACHINE\').Replace('HKCU\', 'HKEY_CURRENT_USER\')))) {
        $script:CaptureSteps.Add([pscustomobject]@{ name = $registryColor.name; status = 'not-present'; error = $null })
        continue
    }
    Invoke-CaptureStep $registryColor.name {
        Invoke-CaptureCommand 'reg.exe' @('export', $registryColor.key,
            (Join-Path $script:CaptureRoot ('colors/' + $registryColor.name + '.reg'))) (
            Join-Path $script:CaptureRoot ('logs/' + $registryColor.name + '.txt'))
    }
}

$copySources = @(
    @{ source = "$env:SystemRoot\System32\spool\drivers\color"; target = 'colors/windows'; patterns = @('*') },
    @{ source = "$env:LOCALAPPDATA\Microsoft\Windows\ICM"; target = 'colors/user'; patterns = @('*.icc', '*.icm') },
    @{ source = "$env:ProgramData\Lenovo"; target = 'colors/ProgramData-Lenovo'; patterns = @('*.icc', '*.icm') },
    @{ source = "$env:ProgramData\X-Rite"; target = 'colors/ProgramData-X-Rite'; patterns = @('*.icc', '*.icm') },
    @{ source = "$env:SystemRoot\System32\DriverStore\FileRepository"; target = 'drivers/DriverStore/FileRepository'; patterns = @('*') },
    @{ source = "$env:SystemRoot\System32\drivers"; target = 'drivers/System32-drivers'; patterns = @('*') },
    @{ source = "$env:SystemRoot\System32"; target = 'firmware/System32'; patterns = @('*.mbn', '*.elf', '*.jsn', '*.bin', '*.fw', '*.tplg') }
)
foreach ($copy in $copySources) {
    $script:CaptureSources.Add([pscustomobject]$copy)
    if (-not (Test-Path -LiteralPath $copy.source)) {
        $script:CaptureSteps.Add([pscustomobject]@{ name = $copy.target; status = 'not-present'; error = $null })
        continue
    }
    Invoke-CaptureStep ('copy-' + $copy.target) {
        # /LEV:1 keeps the loose System32 scan away from unrelated Windows data.
        if ($copy.target -eq 'firmware/System32') {
            $target = Join-Path $script:CaptureRoot $copy.target
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Invoke-CaptureCommand 'robocopy.exe' (@($copy.source, $target) + $copy.patterns + @(
                '/LEV:1', '/COPY:DAT', '/R:1', '/W:1', '/XJ', '/NP'
            )) (Join-Path $script:CaptureRoot 'logs/loose-firmware.txt') 7
        }
        else {
            Copy-CaptureTree $copy.source (Join-Path $script:CaptureRoot $copy.target) (
                Join-Path $script:CaptureRoot ('logs/copy-' + ($copy.target -replace '[/\\]', '-') + '.txt')) $copy.patterns
        }
    }
}
Invoke-CaptureStep 'export-driver-packages' {
    $folder = Join-Path $script:CaptureRoot 'drivers/exported'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Invoke-CaptureCommand 'pnputil.exe' @('/export-driver', '*', $folder) (
        Join-Path $script:CaptureRoot 'logs/export-drivers.txt')
}

Write-CaptureJson @($script:CaptureSources.ToArray()) (Join-Path $script:CaptureRoot 'copy-sources.json')
Write-CaptureJson @($script:CaptureSteps.ToArray()) (Join-Path $script:CaptureRoot 'steps.json')
$failed = @($script:CaptureSteps | Where-Object status -eq 'incomplete')
$summary = @(
    'COLETA LENOVO YOGA SLIM 7 14Q8Y11',
    "Destino: $script:CaptureRoot", "Etapas incompletas: $($failed.Count)",
    'Arquivos ausentes em pastas opcionais aparecem como not-present.',
    'ACPI via API nao garante todos os SSDTs; indice do registro complementa a coleta.',
    'Nao e backup de recuperacao do Windows nem prova de compatibilidade Linux.',
    'Drivers/ACPI/EDID podem conter identificadores e numeros de serie. Compartilhe de forma privada.',
    'Chave OEM de ativacao (MSDM/SLIC), senhas, perfis Wi-Fi e documentos pessoais nao sao alvos da coleta.',
    '', 'ETAPAS:'
) + @($script:CaptureSteps | ForEach-Object { "$($_.status) : $($_.name) : $($_.error)" })
$summary | Set-Content -LiteralPath (Join-Path $script:CaptureRoot 'RESUMO.txt') -Encoding UTF8
Write-Host 'Calculando SHA-256 de todos os arquivos coletados. Esta etapa pode demorar.'
$hashErrors = Write-CaptureManifest $script:CaptureRoot
if ($failed.Count -or $hashErrors) {
    Write-Warning 'Coleta parcial preservada. Envie RESUMO.txt e hash-errors.json para avaliarmos as lacunas.'
    Write-Host "Pasta: $script:CaptureRoot"
    exit 2
}
Write-Host "Coleta finalizada: $script:CaptureRoot" -ForegroundColor Green
Write-Host 'Envie primeiro RESUMO.txt e inventory\identification.json. Preserve a pasta inteira.'
