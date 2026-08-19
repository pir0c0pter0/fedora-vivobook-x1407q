$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $root 'tools/build-personal-maximal-iso.sh'
if (-not (Test-Path -LiteralPath $builder)) { throw "Missing personal ISO builder: $builder" }
$text = Get-Content -Raw -LiteralPath $builder
foreach ($token in '7.2.0-x1407qa','Fedora recovery','devicetree','dracut','firmware-catalog','xorriso','-update_r','mksquashfs','fsck.erofs','--no-preserve-perms','mkfs.erofs','-L Fedora-WS-44','162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef','verify-linux-7.2-x1407qa.sh','rd.live.image','clk_ignore_unused','pd_ignore_unused') {
    if ($text -notmatch [regex]::Escape($token)) { throw "Personal ISO builder missing required behavior: $token" }
}
Write-Output 'PASS: personal maximal ISO builder has kernel, recovery, firmware and verification stages'
