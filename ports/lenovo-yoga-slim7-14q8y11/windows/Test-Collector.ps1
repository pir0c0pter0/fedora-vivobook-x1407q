$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'Collect-Yoga14Q8Y11.ps1'
$parseErrors = $null
$tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $sourcePath

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-True $thrown $Message
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('yoga-collector-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $fakeWindows = Join-Path $temp 'Windows'
    New-Item -ItemType Directory -Path $fakeWindows | Out-Null
    Assert-Throws { New-CaptureDirectory $fakeWindows $fakeWindows } 'Windows root accepted as destination'
    Assert-Throws { New-CaptureDirectory (Join-Path $fakeWindows 'nested') $fakeWindows } 'Windows child accepted'
    Assert-Throws { New-CaptureDirectory '' $fakeWindows } 'Empty destination accepted'
    Assert-Throws { New-CaptureDirectory '\\server\share' $fakeWindows } 'Network destination accepted'
    $first = New-CaptureDirectory (Join-Path $temp 'captures with spaces') $fakeWindows
    $second = New-CaptureDirectory (Join-Path $temp 'captures with spaces') $fakeWindows
    Assert-True ($first -ne $second) 'Collection folders must be unique'
    Assert-True ((Get-ChildItem -LiteralPath $fakeWindows).Count -eq 0) 'Windows fixture was changed'

    $table = New-Object byte[] 36
    [Text.Encoding]::ASCII.GetBytes('DSDT').CopyTo($table, 0)
    [BitConverter]::GetBytes([uint32]36).CopyTo($table, 4)
    $table[8] = 2
    $sum = ($table | Measure-Object -Sum).Sum
    $table[9] = (256 - ($sum % 256)) % 256
    $tableFile = Join-Path $first 'DSDT.dat'
    Assert-True (Save-AcpiTable $table $tableFile) 'Valid DSDT not saved'
    Assert-True ((Get-Item -LiteralPath $tableFile).Length -eq 36) 'DSDT size changed'
    $bad = $table.Clone(); $bad[9] = ($bad[9] + 1) % 256
    Assert-Throws { Save-AcpiTable $bad (Join-Path $first 'bad.dat') } 'Corrupt ACPI checksum accepted'
    $bad = $table.Clone(); [BitConverter]::GetBytes([uint32]1000).CopyTo($bad, 4)
    Assert-Throws { Save-AcpiTable $bad (Join-Path $first 'truncated.dat') } 'Truncated ACPI accepted'
    $secret = $table.Clone(); [Text.Encoding]::ASCII.GetBytes('MSDM').CopyTo($secret, 0)
    $secretFile = Join-Path $first 'MSDM.dat'
    Assert-True (-not (Save-AcpiTable $secret $secretFile)) 'Activation key table accepted'
    Assert-True (-not (Test-Path -LiteralPath $secretFile)) 'Activation key table written'
    $facs = New-Object byte[] 64
    [Text.Encoding]::ASCII.GetBytes('FACS').CopyTo($facs, 0)
    [BitConverter]::GetBytes([uint32]64).CopyTo($facs, 4)
    Assert-True (Save-AcpiTable $facs (Join-Path $first 'FACS.dat')) 'FACS incorrectly required a checksum'
    [BitConverter]::GetBytes([uint32]36).CopyTo($facs, 4)
    Assert-Throws { Save-AcpiTable $facs (Join-Path $first 'short-FACS.dat') } 'Short FACS accepted'

    $copySource = Join-Path $temp 'source tree'
    New-Item -ItemType Directory -Path (Join-Path $copySource 'nested') | Out-Null
    'copy fixture' | Set-Content -LiteralPath (Join-Path $copySource 'nested/firmware.bin')
    $global:FixtureRoboExit = 1
    function global:robocopy.exe {
        $global:FixtureRoboArgs = @($args)
        foreach ($file in Get-ChildItem -LiteralPath $args[0] -Recurse -File) {
            $relative = $file.FullName.Substring($args[0].Length).TrimStart([char[]]'\/')
            $target = Join-Path $args[1] $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.File]::Copy($file.FullName, $target)
        }
        $global:LASTEXITCODE = $global:FixtureRoboExit
        'fixture robocopy output'
    }
    $copyTarget = Join-Path $first 'copied tree'
    Copy-CaptureTree $copySource $copyTarget (Join-Path $first 'copy.log')
    Assert-True (Test-Path -LiteralPath (Join-Path $copyTarget 'nested/firmware.bin')) 'Copy lost directory structure'
    Assert-True ($global:FixtureRoboArgs[0] -eq $copySource -and $global:FixtureRoboArgs[1] -eq $copyTarget) 'Copy changed source/destination arguments'
    Assert-True ('/XJ' -in $global:FixtureRoboArgs -and '/E' -in $global:FixtureRoboArgs) 'Copy omitted recursion or junction exclusion'
    Assert-True ('/MIR' -notin $global:FixtureRoboArgs -and '/PURGE' -notin $global:FixtureRoboArgs -and '/MOVE' -notin $global:FixtureRoboArgs) 'Copy requested destructive flags'
    $global:FixtureRoboExit = 8
    Assert-Throws { Copy-CaptureTree $copySource (Join-Path $first 'failed-copy') (Join-Path $first 'copy-error.log') } 'Failed robocopy accepted'
    Remove-Item Function:\robocopy.exe

    $script:CaptureRoot = $second
    $script:CaptureSteps = [Collections.Generic.List[object]]::new()
    Invoke-CaptureStep 'failed-probe' { throw 'fixture failure' } -WarningAction SilentlyContinue
    Invoke-CaptureStep 'next-probe' { Write-CaptureJson @{ recovered = $true } (Join-Path $second 'recovered.json') }
    Assert-True ($script:CaptureSteps[0].status -eq 'incomplete') 'Failure reported as success'
    Assert-True ($script:CaptureSteps[1].status -eq 'ok') 'Collection did not continue after failure'
    Assert-True ((Get-Content -Raw (Join-Path $second 'steps.json') | ConvertFrom-Json).Count -eq 2) 'Step journal missing'

    foreach ($folder in @('driverstore/package-a', 'driverstore/package-b', 'colors')) {
        New-Item -ItemType Directory -Path (Join-Path $second $folder) | Out-Null
    }
    'first firmware' | Set-Content -LiteralPath (Join-Path $second 'driverstore/package-a/same.bin')
    'second firmware' | Set-Content -LiteralPath (Join-Path $second 'driverstore/package-b/same.bin')
    [IO.File]::WriteAllBytes((Join-Path $second 'colors/LEN88AE_Default.icm'), [byte[]](0, 1, 2, 255))
    Assert-True ((Write-CaptureManifest $second) -eq 0) 'Manifest generation failed'
    $manifest = @(Import-Csv -LiteralPath (Join-Path $second 'manifest-sha256.csv'))
    foreach ($entry in $manifest) {
        $p = Join-Path $second $entry.path
        Assert-True ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -eq $entry.sha256) "Hash mismatch: $p"
    }
    $duplicates = @($manifest | Where-Object path -like '*/same.bin')
    Assert-True ($duplicates.Count -eq 2) 'Same-named firmware from different packages was collapsed'
    Assert-True ($duplicates[0].sha256 -ne $duplicates[1].sha256) 'Different firmware hashes lost'
    Assert-True (@($manifest | Where-Object path -eq 'colors/LEN88AE_Default.icm').Count -eq 1) 'Color profile missing'

    if ($env:OS -ne 'Windows_NT') {
        $link = Join-Path $temp 'linked-destination'
        New-Item -ItemType SymbolicLink -Path $link -Target $fakeWindows | Out-Null
        Assert-Throws { New-CaptureDirectory $link $fakeWindows } 'Linked destination accepted'
        Invoke-CaptureCommand '/bin/sh' @('-c', 'exit 7') (Join-Path $first 'native-ok.log') 7
        Assert-Throws { Invoke-CaptureCommand '/bin/sh' @('-c', 'exit 8') (Join-Path $first 'native-bad.log') 7 } 'Robocopy failure exit code accepted'
    }
    $nativeSource = $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains('public static class YogaFirmwareReader')
    }, $true)[0].Value
    Add-Type -TypeDefinition $nativeSource
    Assert-True ($null -ne ('YogaFirmwareReader' -as [type])) 'Embedded firmware API wrapper did not compile'

    # Run the actual registry-key selection against a provider fixture with protected Properties.
    $selector = $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$keys'
    }, $true)[0].Extent.Text
    $registrySource = @{ name = 'edid-registry'; key = 'Registry::DISPLAY' }
    $global:EdidDenied = $false
    function Get-Item {
        [CmdletBinding()]
        param([string]$LiteralPath)
        if ($LiteralPath -eq 'Registry::DISPLAY\MONITOR\INSTANCE\Device Parameters' -and $global:EdidDenied) {
            Write-Error 'EDID key access denied' -Category PermissionDenied
            return
        }
        [pscustomobject]@{ PSPath = $LiteralPath; Name = $LiteralPath }
    }
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Recurse)
        if ($Recurse) {
            Write-Error 'Protected Properties key access denied' -Category PermissionDenied
            [pscustomobject]@{ PSPath = 'Registry::DISPLAY\MONITOR\INSTANCE\Device Parameters'; Name = 'Device Parameters' }
            return
        }
        switch ($LiteralPath) {
            'Registry::DISPLAY' { [pscustomobject]@{ PSPath = 'Registry::DISPLAY\MONITOR' } }
            'Registry::DISPLAY\MONITOR' { [pscustomobject]@{ PSPath = 'Registry::DISPLAY\MONITOR\INSTANCE' } }
            default { throw "Unexpected traversal: $LiteralPath" }
        }
    }
    function Test-Path {
        [CmdletBinding()]
        param([string]$LiteralPath)
        return $LiteralPath -eq 'Registry::DISPLAY\MONITOR\INSTANCE\Device Parameters'
    }
    try {
        $registryErrors = @()
        . ([scriptblock]::Create($selector))
        Assert-True (@($registryErrors).Count -eq 0) 'EDID traversal entered protected Properties keys'
        Assert-True (@($keys).Count -eq 1 -and $keys[0].PSPath -like '*\Device Parameters') 'EDID key not selected directly'
        $global:EdidDenied = $true
        $registryErrors = @()
        . ([scriptblock]::Create($selector))
        Assert-True (@($registryErrors).Count -gt 0) 'Actual EDID read denial was hidden'
        Assert-True (@($keys).Count -eq 0) 'Unreadable EDID key reported as captured'
    }
    finally { Remove-Item Function:\Get-Item, Function:\Get-ChildItem, Function:\Test-Path }
    Write-Output 'PASS: parser, output boundaries, ACPI checksums/FACS/key exclusion, partial collection, copy arguments/paths, ICC hashes, EDID protected-key traversal/read-denial regression, native exit codes and C# compilation'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
