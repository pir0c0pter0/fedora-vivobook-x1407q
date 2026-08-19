[CmdletBinding()]
param(
    [string]$BuildRoot = 'C:\LinuxBuild',
    [string]$Source = "$env:SystemRoot\System32\DriverStore\FileRepository"
)

$ErrorActionPreference = 'Stop'
$sourceResolved = (Resolve-Path -LiteralPath $Source).Path
$backupRoot = Join-Path $BuildRoot 'driverstore-backup\FileRepository'
$catalogRoot = Join-Path $BuildRoot 'firmware-catalog'
$cameraRoot = Join-Path $BuildRoot 'camera-ir-research'
$logRoot = Join-Path $BuildRoot 'logs'

New-Item -ItemType Directory -Force -Path $backupRoot, $catalogRoot, $cameraRoot, $logRoot | Out-Null

$copyLog = Join-Path $logRoot 'driverstore-robocopy.log'
& robocopy.exe $sourceResolved $backupRoot /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NP /TEE "/LOG:$copyLog"
$robocopyCode = $LASTEXITCODE
if ($robocopyCode -ge 8) {
    throw "DriverStore backup failed with robocopy exit code $robocopyCode. See $copyLog"
}

$packagePatterns = @('qcadsp*', 'qccdsp*', 'qcdx*', 'qcwlan*', 'qcbt*', 'qcsubsys*')
$cameraTerms = @(
    'HM1092', 'QCOM0C99', 'CameraAuxSensor', 'Spectra', 'Camera Front Sensor',
    'Camera Always On Sensing', 'MipiCsi', 'Purwa', 'x1p42100', '13041043'
)
$linuxExtensions = @('.mbn', '.elf', '.jsn', '.bin', '.fw', '.zst', '.xz', '.dat', '.cal', '.cfg', '.conf', '.tplg')

$allPackages = @(Get-ChildItem -LiteralPath $backupRoot -Directory)
$selectedPackages = @($allPackages | Where-Object {
    $name = $_.Name
    [bool]($packagePatterns | Where-Object { $name -like $_ })
})

$cameraPackageMap = @{}
foreach ($package in $allPackages) {
    $matchedTerms = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($package.Name -match 'camera|spectra|sensor|qccam|qcisp|aos') {
        [void]$matchedTerms.Add('package-name')
    }
    $textFiles = @(Get-ChildItem -LiteralPath $package.FullName -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.inf', '.txt', '.ini', '.xml', '.json', '.jsn', '.cfg') })
    foreach ($file in $textFiles) {
        foreach ($term in $cameraTerms) {
            if (Select-String -LiteralPath $file.FullName -SimpleMatch -Pattern $term -Quiet -ErrorAction SilentlyContinue) {
                [void]$matchedTerms.Add($term)
            }
        }
    }
    if ($matchedTerms.Count -gt 0) {
        $cameraPackageMap[$package.FullName] = @($matchedTerms)
        $cameraDestination = Join-Path $cameraRoot $package.Name
        Copy-Item -LiteralPath $package.FullName -Destination $cameraDestination -Recurse -Force
    }
}

$usableRoot = Join-Path $catalogRoot 'linux-usable'
New-Item -ItemType Directory -Force -Path $usableRoot | Out-Null
$candidatePackages = @($selectedPackages + ($allPackages | Where-Object { $cameraPackageMap.ContainsKey($_.FullName) }) | Sort-Object FullName -Unique)
$catalog = foreach ($package in $candidatePackages) {
    foreach ($file in Get-ChildItem -LiteralPath $package.FullName -File -Recurse -ErrorAction SilentlyContinue) {
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName
        $relative = $file.FullName.Substring($backupRoot.Length).TrimStart('\')
        $isLinuxUsable = $file.Extension.ToLowerInvariant() -in $linuxExtensions
        if ($isLinuxUsable) {
            $destination = Join-Path $usableRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        }
        [pscustomobject]@{
            package = $package.Name
            relative_path = $relative
            size = $file.Length
            sha256 = $hash.Hash.ToLowerInvariant()
            linux_usable = $isLinuxUsable
            camera_terms = @($cameraPackageMap[$package.FullName])
        }
    }
}

$catalogPath = Join-Path $catalogRoot 'firmware-catalog.json'
$catalog | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $catalogPath

$manifestPath = Join-Path $BuildRoot 'manifest-sha256.txt'
$manifestFiles = @(Get-ChildItem -LiteralPath $catalogRoot, $cameraRoot -File -Recurse)
$manifestLines = foreach ($file in $manifestFiles) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName
    $relative = $file.FullName.Substring($BuildRoot.Length).TrimStart('\') -replace '\\', '/'
    "$($hash.Hash.ToLowerInvariant())  $relative"
}
$manifestLines | Sort-Object | Set-Content -Encoding ASCII -LiteralPath $manifestPath

[pscustomobject]@{
    Source = $sourceResolved
    Backup = $backupRoot
    PackagesCopied = $allPackages.Count
    QualcommPackagesCataloged = $selectedPackages.Count
    CameraPackagesCataloged = $cameraPackageMap.Count
    CatalogEntries = @($catalog).Count
    LinuxUsableFiles = @($catalog | Where-Object linux_usable).Count
    Catalog = $catalogPath
    Manifest = $manifestPath
} | Format-List
