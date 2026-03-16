# Guia: Extrair Firmware Qualcomm do Windows - ASUS Vivobook 14 X1407Q

## Contexto

O Fedora 44 Beta bootou com sucesso usando a opção 1 (Zenbook A14 DTB), mas WiFi, Bluetooth, GPU e áudio não funcionam porque o firmware Qualcomm proprietário precisa ser extraído da partição Windows (BitLocker).

Este guia é para rodar **no Windows do Vivobook** com Claude Code.

---

## Passo 1: Extrair firmware do DriverStore

Abra o PowerShell como Administrador e rode:

```powershell
# Criar pasta de destino no pendrive (ajuste a letra do pendrive)
$USB = "D:"  # TROQUE pela letra do seu pendrive
$DEST = "$USB\qcom-firmware"
New-Item -ItemType Directory -Force -Path $DEST

# Copiar TODOS os firmwares Qualcomm do DriverStore
$DriverStore = "C:\Windows\System32\DriverStore\FileRepository"

# WiFi / WLAN
Get-ChildItem -Path $DriverStore -Recurse -Include "*.bin","*.mbn" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "qcwlan|wlan_th|ath12k|wcn" } |
    ForEach-Object { Copy-Item $_.FullName -Destination "$DEST\" -Force; Write-Host "WiFi: $($_.Name)" }

# Bluetooth
Get-ChildItem -Path $DriverStore -Recurse -Include "*.bin","*.mbn","*.tlv" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "qcbt|bluetooth|BT" } |
    ForEach-Object { Copy-Item $_.FullName -Destination "$DEST\" -Force; Write-Host "BT: $($_.Name)" }

# GPU Adreno
Get-ChildItem -Path $DriverStore -Recurse -Include "*.mbn","*.bin","*.fw" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "qcdx|adreno|qcgpu" } |
    ForEach-Object { Copy-Item $_.FullName -Destination "$DEST\" -Force; Write-Host "GPU: $($_.Name)" }

# Audio DSP (ADSP)
Get-ChildItem -Path $DriverStore -Recurse -Include "*.mbn","*.bin","*.elf","*.jsn" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "qcadsp|adsp" } |
    ForEach-Object { Copy-Item $_.FullName -Destination "$DEST\" -Force; Write-Host "ADSP: $($_.Name)" }

# Compute DSP (CDSP)
Get-ChildItem -Path $DriverStore -Recurse -Include "*.mbn","*.bin","*.elf","*.jsn" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "qccdsp|cdsp" } |
    ForEach-Object { Copy-Item $_.FullName -Destination "$DEST\" -Force; Write-Host "CDSP: $($_.Name)" }

# Subsystem / Sensors / NPU / Battery
Get-ChildItem -Path $DriverStore -Recurse -Include "*.mbn","*.bin","*.elf","*.jsn" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "qcsubsys|qcsensor|qcnpu|battmgr|qcpil" } |
    ForEach-Object { Copy-Item $_.FullName -Destination "$DEST\" -Force; Write-Host "SUB: $($_.Name)" }

# QUPv3 (serial interfaces - I2C, SPI, UART)
Get-ChildItem -Path $DriverStore -Recurse -Include "*.elf","*.mbn" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "qupv3|qup" } |
    ForEach-Object { Copy-Item $_.FullName -Destination "$DEST\" -Force; Write-Host "QUP: $($_.Name)" }

Write-Host "`n--- Contagem ---"
(Get-ChildItem $DEST).Count
Write-Host "arquivos extraidos em $DEST"
```

---

## Passo 2: Copiar estrutura completa de diretórios (método alternativo mais completo)

Se o Passo 1 não encontrar muitos arquivos, rode este que copia **tudo** relacionado a Qualcomm:

```powershell
$USB = "D:"  # TROQUE pela letra do seu pendrive
$DEST = "$USB\qcom-firmware-full"
New-Item -ItemType Directory -Force -Path $DEST

$DriverStore = "C:\Windows\System32\DriverStore\FileRepository"

# Listar TODAS as pastas Qualcomm no DriverStore
Get-ChildItem -Path $DriverStore -Directory |
    Where-Object { $_.Name -match "^qc" } |
    ForEach-Object {
        $dir = $_.Name
        Write-Host "Copiando pasta: $dir"
        $destDir = "$DEST\$dir"
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        Get-ChildItem -Path $_.FullName -Recurse -Include "*.mbn","*.bin","*.elf","*.jsn","*.tlv","*.fw","*.b*" -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName -Destination "$destDir\" -Force }
    }

Write-Host "`n--- Resultado ---"
$total = (Get-ChildItem $DEST -Recurse -File).Count
Write-Host "$total arquivos extraidos em $DEST"
Get-ChildItem $DEST -Directory | ForEach-Object {
    $count = (Get-ChildItem $_.FullName -File).Count
    Write-Host "  $($_.Name): $count arquivos"
}
```

---

## Passo 3: Verificar o que foi extraído

```powershell
$USB = "D:"
Write-Host "=== qcom-firmware ==="
Get-ChildItem "$USB\qcom-firmware" -ErrorAction SilentlyContinue | Format-Table Name, Length
Write-Host "`n=== qcom-firmware-full ==="
Get-ChildItem "$USB\qcom-firmware-full" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $count = (Get-ChildItem $_.FullName -File -Recurse).Count
    Write-Host "  $($_.Name): $count arquivos"
}
```

---

## Passo 4: Informações extras úteis

Rode isso e salve o resultado num arquivo texto no pendrive:

```powershell
$USB = "D:"

# Info do sistema
$info = @()
$info += "=== SISTEMA ==="
$info += (Get-ComputerInfo | Select-Object CsModel, CsManufacturer, BiosVersion, OsVersion | Out-String)

# Listar drivers Qualcomm instalados
$info += "=== DRIVERS QUALCOMM ==="
$info += (Get-WindowsDriver -Online | Where-Object { $_.ProviderName -match "Qualcomm" } |
    Select-Object Driver, ClassName, ProviderName, Version, Date | Format-Table | Out-String)

# IDs de hardware
$info += "=== HARDWARE IDs ==="
$info += (Get-PnpDevice | Where-Object { $_.Manufacturer -match "Qualcomm" } |
    Select-Object Name, DeviceID, Status | Format-Table -Wrap | Out-String)

$info | Out-File "$USB\hardware-info.txt" -Encoding UTF8
Write-Host "Salvo em $USB\hardware-info.txt"
```

---

## Depois de extrair: O que fazer no PC Linux

Traga o pendrive de volta para o PC Linux e instrua o Claude Code:

```
Tenho o firmware Qualcomm extraído do Windows do Vivobook 14 X1407Q no pendrive.
As pastas são qcom-firmware/ e qcom-firmware-full/.
Preciso que você:
1. Monte o pendrive
2. Injete o firmware no squashfs da ISO Fedora 44
3. Reconstrua a ISO: Fedora-44-VivoBook-X1407Q.iso
4. Grave no pendrive de boot
```

---

## Resumo das pastas no pendrive

Após rodar tudo, o pendrive deve ter:

```
D:\
├── qcom-firmware\          ← firmware filtrado por tipo
├── qcom-firmware-full\     ← cópia completa das pastas qc* do DriverStore
├── hardware-info.txt       ← info do hardware e drivers
└── GUIA-EXTRAIR-FIRMWARE.md ← este arquivo
```
