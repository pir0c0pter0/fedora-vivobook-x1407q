$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\provenance\sources.json'
if (-not (Test-Path -LiteralPath $path)) { throw "Source provenance missing: $path" }
$sources = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
foreach ($source in $sources) {
    if ($source.url -notmatch '^https://') { throw "Non-HTTPS source: $($source.name)" }
    if ([string]::IsNullOrWhiteSpace($source.provenance)) { throw "Missing provenance: $($source.name)" }
    if ([string]::IsNullOrWhiteSpace($source.local_path)) { throw "Missing local path: $($source.name)" }
}
foreach ($name in 'Fedora 44 Workstation aarch64 ISO','Fedora signed checksum','Linux 7.2','Linux 7.2 signed checksums','pir0c0pter0 X1407QA project','FreyDragon X1407QA research') {
    if ($name -notin $sources.name) { throw "Required source missing: $name" }
}
Write-Output "PASS: $($sources.Count) source provenance records validated"
