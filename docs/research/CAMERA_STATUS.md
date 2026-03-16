# Camera Fix — Status e Progresso (2026-03-16)

## Status Atual

| Câmera | Status | Detalhes |
|--------|--------|---------|
| RGB #1 (OV02C10) | **FUNCIONANDO** | CCI1 bus 1 (AON), addr 0x36, libcamera OK, Snapshot mostra imagem |
| IR (modelo TBD) | **BLOQUEADA** | AVDD (pm8010 LDO7_M 2.9V) inacessível — pm8010 ausente no SPMI, LDO7 não provisionado no RPMH. Sensor -ENXIO no I2C. Precisa patch RPMH ou ACPI power seq. |
| RGB #2 | **DESCONHECIDA** | Sem info de AeoB, possivelmente mesma lente que IR |
| IR #2 | **DESCONHECIDA** | Sem info |

## Módulo DKMS: `vivobook-cam-fix` v2.0

**Arquivos em `/usr/src/vivobook-cam-fix-2.0/`:**

| Arquivo | Função |
|---------|--------|
| `vivobook_cam_phase1.dts` | DT overlay: CAMCC, CCI0, CCI1 (disabled), CAMSS, reguladores, pinctrl |
| `vivobook_cam_phase2.dts` | DT overlay: habilita CCI0 e CCI1 (triggers probe) |
| `vivobook_cam_fix.c` | Módulo kernel: two-phase overlay + pm_runtime hold no CAMCC |
| `Makefile` | CPP+DTC para 2 overlays → .dtbo → xxd → .h → kbuild .ko |
| `dkms.conf` | DKMS config com PRE_BUILD para ambos overlays |

**Cópia no repo:** `modules/vivobook-cam-fix-2.0/`

## Arquitetura: Two-Phase DT Overlay

```
Phase 1: CAMCC + CCI0(disabled) + CCI1(disabled) + CAMSS + reguladores + pinctrl
         → CAMCC proba, CAMSS proba, reguladores registram
         → pm_runtime_get_sync(CAMCC) mantém PLLs configurados

Phase 2: CCI0 status="okay" + CCI1 status="okay"
         → CCI proba, cria I2C buses
         → ov02c10 driver proba no sensor
```

## Problemas Resolvidos

### 1. Overlay -22 (EINVAL) nos nós CCI i2c-bus
**Causa:** CCI driver proba durante overlay apply, criando I2C adapters que conflitam com changeset notifier.
**Fix:** Two-phase overlay — CCI com `status="disabled"` na phase 1, habilitado na phase 2 depois que subsistemas probaram.

### 2. CCI crash: `list_add corruption. prev is NULL`
**Causa:** CCI node só tinha `i2c-bus@1` (sensor no bus 1 AON). `cci_reset()` usa `master[0].irq_complete` que nunca recebeu `init_completion()`.
**Fix:** Adicionar `i2c-bus@0` vazio em todos os CCI nodes para que master[0] seja inicializado.

### 3. `Failed to get supply 'avdd'` — regulador não registrava
**Causa:** `vreg_l7b_2p8` adicionado como filho do bloco `regulators-0` (PM8550B) que já probou no boot. O driver RPMH não re-proba para pegar filhos novos do overlay.
**Fix:** Criar bloco RPMH separado `regulators-9` com `compatible = "qcom,pm8550-rpmh-regulators"` e `qcom,pmic-id = "b"`. O driver proba como instância nova.

### 4. Sensor sem energia — pm8010 ausente
**Causa:** pm8010 camera PMIC não existe fisicamente (SPMI scan confirma, DTB tem `status = "disabled"`).
**Fix:** Power topology extraída do patch alexVinarskis (AeoB decompiled):
- AVDD + DVDD: `vreg_l7b_2p8` (PM8550B LDO7, 2.8V via RPMH) — módulo câmera tem LDO interno pra DVDD 1.2V
- DOVDD: `vreg_l3m_1p8` (pm8010 RPMH LDO3, 1.8V) — fire-and-forget funciona mesmo sem pm8010 físico

### 5. Sensor no bus errado
**Causa:** v1 colocava sensor em CCI0 bus 0. Patch alexVinarskis mostra que está em CCI1 bus 1 (AON, GPIOs 235/236).
**Fix:** Movido para CCI1 bus 1 (AON).

### 6. `cam_cc_pll8 failed to enable!` — streaming falha
**Causa:** CAMCC usa `use_rpm = true`. Depois do probe, runtime PM suspende CAMCC (power domain MMCX desliga). Todos os registradores PLL perdem configuração (L=0). Quando VFE tenta habilitar clock, PLL8 não consegue lockar → timeout -110.
**Fix:** `pm_runtime_get_sync(camcc_dev)` no módulo mantém CAMCC acordado permanentemente, preservando config dos PLLs.

### 7. Imagem de ponta-cabeça
**Fix:** Adicionado `rotation = <180>;` no nó do sensor OV02C10.

## O que NÃO funciona / Pendente

### Streaming via Pipewire (parcialmente)
- `cam --capture=1` funciona (libcamera direto)
- Pipewire/Snapshot: o PLL8 fix (`pm_runtime_get_sync`) pode não ser suficiente se CAMCC suspendeu ANTES do get_sync
- **Workaround atual:** reboot limpo + insmod + wireplumber restart + Snapshot
- **NUNCA fazer rmmod** do módulo — CAMCC corrompe state de GDSC ao recarregar, kernel crasha, shutdown trava

### Câmera IR — BLOQUEADA
- **DSDT HID:** QCOM0C99 = "Qualcomm Spectra 695 ISP Camera Auxiliary Sensor Device" (WOA-Project BOM)
- **Modelo sensor:** desconhecido — QCOM0C99 é device ISP, não sensor direto
- **AeoB (CAMI_RES_MTP.bin):** MCLK0 24MHz (GPIO 96), reset GPIO 109, LDO4_M (1.8V DOVDD), LDO7_M (2.9V AVDD)
- **AeoB nota:** arquivo sem sufixo `_Pw` (genérico MTP, não Purwa-specific) — pode não refletir hardware real do Vivobook
- **Problema principal:** pm8010 ausente no SPMI. LDO3_M/LDO4_M funcionam fire-and-forget via RPMH, mas LDO7_M retorna `-ENOTRECOVERABLE` — devm_regulator_register() falha no voltage read
- **Teste 1:** substituir AVDD por vreg_l7b_2p8 (PM8550B, 2.8V) → regulador habilitou mas é fio físico diferente → sensor NACK (-ENXIO) em CCI0 bus 0 addr 0x36
- **Teste 2:** RPMH direct write via cmd_db_read_addr("ldom7") + rpmh_write() → write aceito sem erro (addr 0x41600), mas sensor continua sem resposta. pm8010 provavelmente não existe fisicamente — write é no-op
- **Teste 3:** regulator-fixed dummy + RPMH direct write + scan todos CCI buses (9,10,11) → todos vazios em todos endereços
- **Scan:** nenhum device em nenhum CCI bus — sensor sem energia
- **Conclusão:** pm8010 não existe fisicamente. CMD-DB tem a entry (do reference design) mas write não produz voltagem real. Ninguém tem IR camera funcionando no Linux para Snapdragon X (alexVinarskis e Bryan O'Donoghue focam só RGB)
- **Caminho futuro:** (a) esperar upstream com ISP support (Spectra 695), (b) investigar se há LDO alternativo no board, (c) extrair DSDT de laptop Windows com mesmo SoC para comparar power sequencing

## AeoB Firmware — Dados Extraídos

### CAMF_RES_MTP_Pw.bin (RGB Front — Purwa variant)
| Propriedade | Valor |
|-------------|-------|
| Device | `\_SB.CAMF` |
| Power rail AVDD | `PPP_RESOURCE_ID_LDO7_B` = vreg_l7b_2p8 (2.8V) |
| Power rail DOVDD | `PPP_RESOURCE_ID_LDO3_M` = vreg_l3m_1p8 (1.8V) |
| Clock | `cam_cc_mclk4_clk` (MCLK4, GPIO 100) |
| GPIO Reset | 237 (0xED) |
| GPIO CCI SDA | 235 (0xEB) — CCI1 bus 1 AON |
| GPIO CCI SCL | 236 (0xEC) — CCI1 bus 1 AON |
| GPIO LED | 110 (via CAMP) |

### CAMI_RES_MTP.bin (IR Camera)
| Propriedade | Valor |
|-------------|-------|
| Device | `\_SB.CAMI` |
| Power rail AVDD | `PPP_RESOURCE_ID_LDO7_M` = vreg_l7m (2.9V) |
| Power rail DOVDD | `PPP_RESOURCE_ID_LDO4_M` = vreg_l4m (1.8V) |
| Clock | `cam_cc_mclk0_clk` (MCLK0, GPIO 96) |
| GPIO Reset | 109 (0x6D) |
| I2C bus | Desconhecido — testando CCI0 bus 0 |
| I2C addr | Desconhecido — testando 0x36 |
| Sensor modelo | Desconhecido |

### CAMP_RES_MTP.bin (Camera Platform — todos os GPIOs CCI)
| GPIO | Função |
|------|--------|
| 97 (0x61) | MCLK1 |
| 100 (0x64) | MCLK4 (RGB) |
| 101 (0x65) | CCI0 SDA bus 0 |
| 102 (0x66) | CCI0 SCL bus 0 |
| 103 (0x67) | CCI0 SDA bus 1 |
| 104 (0x68) | CCI0 SCL bus 1 |
| 105 (0x69) | CCI1 SDA bus 0 |
| 106 (0x6A) | CCI1 SCL bus 0 |

## DSDT — Dispositivos de Câmera

Fonte: Zenbook A14 UX3407QA DSDT (alexVinarskis PR #134 em aarch64-laptops/build).
SDFE = 0x9A confirma Purwa (X1P42100). Tabelas "should be the same for X1P-42-100".

| Device | HID | Status | Função |
|--------|-----|--------|--------|
| CAMP | QCOM0C32 | 0x0F (ativo) | Camera Platform (CCI0+CCI1, GPIOs) |
| CAMF | QCOM0C06 | 0x0F (ativo) | Camera Front RGB |
| CAMI | QCOM0C99 | 0x0F (ativo) | Camera IR |
| CAMS | QCOM0C26 | 0 (desativado) | Camera Sensor (não usado) |
| CAMT | QCOM0CCE | 0 (desativado) | Camera (não usado) |
| CAMU | QCOM0CCF | 0 (desativado) | Camera (não usado) |
| SEN2 | QCOM0693 | ativo | Sensor via ADSP (Lid=1) |
| SEN3 | QCOM0694 | ativo | Sensor via ADSP (depende SEN2) |

**CAMF e CAMI são os únicos ativos.** = 1 câmera RGB + 1 câmera IR = 2 sensores.
As "4 lentes" físicas podem ser: RGB, IR flood, IR dot projector, e lente auxiliar (mesma PCB, controlador único).

## Hardware — GPIOs de Câmera

```
GPIO 96  — MCLK0 (cam_mclk) — IR camera clock
GPIO 97  — MCLK1 (cam_mclk) — não usado (CAMS desativado)
GPIO 98  — MCLK2 (cam_mclk) — não usado
GPIO 99  — MCLK3 (cam_mclk) — não usado (CAMP ref)
GPIO 100 — MCLK4 (cam_aon)  — RGB camera clock ✓
GPIO 101 — CCI0 SDA bus 0   — CCI I2C ✓
GPIO 102 — CCI0 SCL bus 0   — CCI I2C ✓
GPIO 103 — CCI0 SDA bus 1   — CCI I2C ✓
GPIO 104 — CCI0 SCL bus 1   — CCI I2C ✓
GPIO 105 — CCI1 SDA bus 0   — CCI I2C ✓
GPIO 106 — CCI1 SCL bus 0   — CCI I2C ✓
GPIO 109 — IR camera reset   — active-low
GPIO 110 — Camera indicator LED — output, gpio-leds
GPIO 235 — CCI1 SDA bus 1 (AON) — RGB camera I2C ✓
GPIO 236 — CCI1 SCL bus 1 (AON) — RGB camera I2C ✓
GPIO 237 — RGB camera reset  — active-low, output ✓
```

## Como Testar

```bash
# Reboot limpo (obrigatório — CAMCC não suporta re-probe)
sudo reboot

# Carregar módulo
sudo insmod /lib/modules/$(uname -r)/extra/vivobook_cam_fix.ko.xz

# Verificar probe
sudo dmesg | grep -E '(vivobook_cam|ov02c10|Error|fail)' | grep -v overlay

# Verificar devices
ls /dev/video* /dev/media*
ls /sys/bus/i2c/drivers/ov02c10/

# Testar câmera RGB
cam -l
cam -c 1 --capture=1

# Verificar IR (se probou)
sudo i2cdetect -y 9   # CCI0 bus 0
sudo i2cdetect -y 10  # CCI0 bus 1

# GUI
systemctl --user restart wireplumber
sleep 3
snapshot
```

## NUNCA FAZER

- `sudo rmmod vivobook_cam_fix` — CAMCC corrompe GDSCs ao recarregar, kernel crasha, shutdown trava
- `sudo rmmod camcc_x1e80100` — mesmo problema
- Adicionar em `/etc/modules-load.d/` — CCI cria I2C buses que podem deslocar numeração (vivobook_kbd_fix já usa DT path, mas outros módulos podem quebrar)
- Mudar GPIO5 DIG_OUT_SOURCE_CTL para 0x00 — mata a tela

## Referências

- [alexVinarskis Zenbook A14 patches](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14)
- [alexVinarskis ACPI tables PR](https://github.com/aarch64-laptops/build/pull/134)
- [Bryan O'Donoghue CAMSS v9 patches](https://lkml.org/lkml/2026/2/26/1172)
- [Bryan O'Donoghue Hamoa camera DTSI](https://lkml.org/lkml/2026/2/26/1238)
- AeoB firmware: `/lib/firmware/qcom/CAMF_RES_MTP_Pw.bin`, `CAMI_RES_MTP.bin`, `CAMP_RES_MTP.bin`
