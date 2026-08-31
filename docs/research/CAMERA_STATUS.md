# Camera Fix — Status e Progresso (atualizado em 2026-08-31)

## Status Atual

| Câmera | Status | Detalhes |
|--------|--------|---------|
| RGB #1 (OV02C10) | **FUNCIONANDO** | CCI1 bus 1 (AON), addr 0x36; still XRGB8888 1080p e vídeo XRGB8888 720p30 validados. Imagem na orientação correta via `rotation = <180>`. Sem warnings de libcamera/CAMCC no kernel 7.2 patchado |
| IR (HM1092) | **FUNCIONANDO** (2026-08-31) | Streaming real pelo camss: 560×360 Y10 (`V4L2_PIX_FMT_Y10P`), ~29,7 fps, caminho `hm1092 → csiphy0 → csid0 → vfe0_rdi0 → /dev/video0`. Driver próprio `modules/vivobook-ir-cam-1.0` (`himax,hm1092`). Sensor em i2c-9 (CCI0 bus 0), addr 0x24, model ID `0x1091`. Iluminador PM8550 de 700 mA (fontes 1+4) liga e desliga automaticamente com o stream. Captura: `tools/ir-camera-capture.sh` |

## Módulo DKMS: `vivobook-cam-fix` v2.0

**Arquivos em `/usr/src/vivobook-cam-fix-2.0/`:**

| Arquivo | Função |
|---------|--------|
| `vivobook_cam_phase1.dts` | DT overlay: CAMCC, CCI0, CCI1 (disabled), CAMSS, reguladores, pinctrl |
| `vivobook_cam_phase2.dts` | DT overlay: habilita CCI0 e CCI1 (triggers probe) |
| `vivobook_cam_fix.c` | Módulo kernel: two-phase overlay + pm_runtime hold no CAMCC |
| `Makefile` | CPP+DTC para 2 overlays → .dtbo → xxd → .h → kbuild .ko |
| `dkms.conf` | DKMS config com PRE_BUILD para ambos overlays |
| `ov02c10.yaml` | Tuning IPA simple compatível com libcamera 0.7.1 |
| `vivobook-camera.service` | Loader habilitado em `graphical.target`, após módulos core e display manager; carrega `system_heap` |
| `vivobook-camera` | Comando seguro `start\|status` |

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

### 4. Sensor sem energia
**Causa:** faltava provisionar as rails da câmera; o DTB do Zenbook traz o pm8010 com
`status = "disabled"`. Isto ficou anos documentado como "pm8010 não existe fisicamente" —
errado, ver a seção da IR: o LDO7 só registra em 2.912 V.
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

## Operação segura e pendências

### RGB concluída, com autostart gráfico tardio

- `cam -l`, captura libcamera, vídeo 720p30 e PipeWire/Snapshot funcionam.
- O serviço inicia em `graphical.target`, depois de módulos core e display
  manager, carrega `system_heap`, reinicia WirePlumber e mantém CAMCC/CAMSS/CCI
  ativos antes do primeiro stream.
- A regra udev concede uaccess apenas ao DMA heap `system`; não altera outros
  heaps.
- `systemctl stop vivobook-camera` é intencionalmente no-op: os módulos ficam
  carregados. **Nunca usar `rmmod`**; reboot é o único unload seguro.
- Fedora libcamera 0.7.1 patchado (`0.7.1-1.fc44.x1407qa`) registra `ov02c10`
  em `camera_sensor_properties.cpp` e o gain helper, então os avisos de static
  properties e sensor helper sumiram. Patch em `libcamera/`.
- Kernel 7.2 é construído com `kernel/linux-7.2-camera-warning-fix.patch`
  (aplicado sempre por `kernel/build-linux-7.2-x1407qa.sh`): `.get_selection`
  no `ov02c10` e skip do voto `cpas_ahb` no camss `x1e80100`. O journal do boot
  já não traz `cam_cc_slow_ahb_clk_src`, `Lucid PLL latch failed` nem
  `cam_cc_pll8 failed to enable`, e a captura conclui sem Oops/soft lockup.
- O sensor é montado 180°. `rotation = <180>` no overlay é o que faz o
  libcamera dirigir `HFLIP`/`VFLIP` do OV02C10; com `<0>` a imagem sai de ponta
  cabeça.

### Câmera IR — FUNCIONANDO (2026-08-31)

Streaming real, 560×360 Y10 a ~29,7 fps. O bloqueio de abril era **software**,
não ausência de hardware.

#### As cinco coisas que faltavam

**1. Tensão do AVDD fora da grade do RPMh.** O teste de abril pediu
2.900.000 µV para o pm8010 LDO7, valor tirado do `CAMI_RES_MTP.bin` (referência
genérica). O binário que o Windows de fábrica desta máquina carrega é o
`CAMI_RES_QRD.bin` — o INF `qccamauxsensor_extension8380.inf` liga
`SUBSYS_13041043&REV_0001` a `QRD_Pw` — e ele pede **2.912.000 µV**. O
`pmic5_pldo` anda de 8 em 8 mV: 2.912.000 cai num seletor exato, 2.900.000 não.
Com `min == max` fora da grade o core não aplica a constraint,
`regulator_register()` falha e derruba o bloco inteiro. Foi isso que virou
"`-ENOTRECOVERABLE`, pm8010 não existe fisicamente". O pm8010 sempre esteve lá:
`vreg_l3m_1p8` e `vreg_l4m_1p8` já registravam antes.

**2. O sensor não auto-incrementa o ponteiro de registrador.** Ler 2 bytes de
0x0000 devolve `0x10,0xff` em vez de `0x10,0x91`. Nada de `CCI_REG16`: todo
registrador de 16 bits vira duas metades de 8, escritas byte baixo primeiro,
como na sequência de fábrica.

**3. Região do CSIPHY0 mapeada pela metade.** O overlay dava `0x1000` para
csiphy0/1/2, mas o passo entre as bases é `0x2000` e `csiphy_reset()` escreve em
`base+0x1000` — Oops de paging no primeiro stream. O csiphy4 da RGB nunca sofreu
porque já tinha `0x4000`.

**4. O Purwa não tem IFE1 nem CSID1.** `cam_cc_ife_1_gdsc status stuck at 'off'`.
Confirmado pelo dump: o `IRP3.bin` (variante Purwa do pacote `qccamisp_ext8380`)
lista só `IFE0`, `IFELITE0`, `IFE_CSID0`, `IFELITE_CSID0`; o `IRS3.bin` genérico
tem IFE1, CSID1 e SFE. O caminho é obrigatoriamente csid0 → vfe0_rdi0 — o mesmo
que a RGB usa, então as duas câmeras disputam o CSID0.

**5. É 1 lane, não 2.** A PLL do init dá `24 MHz ÷ 0x030D(12) × 0x030F(90) =
180 MHz`; 180 MHz DDR = 360 Mbps, que a 10 bpp são exatamente os 36 Mpix/s do
modo. Com 2 lanes sobrava o dobro de banda e não chegava frame nenhum. O CSIPHY
certo é o 0: o `C1PG.bin`, ligado ao `CameraMipiCsi_Device_Pw`, declara só
CSIPHY0 e CSIPHY4.

#### Configuração final

| Peça | Valor |
|------|-------|
| I2C | i2c-9 (CCI0 bus 0, GPIO 101/102), addr 0x24, reg 16 bits / dado 8 bits |
| Model ID | `0x1091` em 0x0000/0x0001 (lidos separados) |
| AVDD | `vreg_l7m_2p9` — pm8010 LDO7, **2.912.000 µV**, bloco `regulators-10` |
| DOVDD | `vreg_l4m_1p8` — pm8010 LDO4, 1.8 V |
| MCLK | MCLK0 @ 24 MHz, GPIO 96 |
| Reset | GPIO 109, active-low |
| CSI-2 | 1 lane, link frequency 180 MHz, DT 0x2B (RAW10) |
| Modo | 560×360, `MEDIA_BUS_FMT_Y10_1X10`, HTS 1616, VTS 750, ~29,7 fps |
| Pipeline | `hm1092 → csiphy0 → csid0 → vfe0_rdi0 → /dev/video0` (`Y10P`) |
| Iluminador | PM8550 `leds-qcom-flash`, fontes 1+4, `ir:torch`, teto de 700 mA |

#### Iluminador IR e segurança

O overlay cria o flash PM8550 e o módulo `vivobook_cam_fix` corrige o parent
dinâmico para o dispositivo SPMI `0-01` antes do probe de `leds-qcom-flash`.
O `hm1092` acende o IR somente depois de iniciar o sensor e sempre tenta apagá-lo
antes de parar o sensor. Falhas transitórias de desligamento são repetidas sem
soltar prematuramente a referência de runtime PM; o cleanup diferido roda em
workqueue freezable. Suspend/resume, shutdown e remove têm caminhos explícitos
de apagamento. Em shutdown/remove, uma falha persistente da LED class cai para
um fallback síncrono no regmap do PM8550: ele limpa fontes 1+4 e module-enable
e exige readback desligado antes de considerar o fallback concluído.

No teste físico final de 2026-08-31, 30 frames por etapa produziram média
`7,98 → 14,17 → 7,98` e p95 `9 → 36 → 9` em escuro → iluminado → escuro.
Durante o stream iluminado, o regmap do PM8550 mostrou `ee46=80` e `ee4e=09`;
após fechar, ambos voltaram a `00`, o LED class ficou em `0` e o HM1092 entrou
em runtime suspend. O boot limpo não registrou Oops nem erro do driver.

#### Sequência de init

185 escritas, todas 16 bits de endereço e 8 bits de dado, sem delays, extraídas
de `com.qti.sensormodule.hm1092.bin` (formato "QTI Chromatix Header /
Parameter Parser V3.4.0": tabela de 56 bytes por entrada a partir de 0xCC, seção
de dados em 0x9A5C; cada escrita é um registro de 10 u32 —
`slaveAddr, regAddr, registerData, addrType, dataType, op, delayUs`). Tabela em
`modules/vivobook-ir-cam-1.0/hm1092_regs.h`, conferida byte a byte.

#### Controles medidos

- **Exposição** (0x0202/0x0203, em linhas): escala monotônico. Com a cena fixa,
  190 → 400 → 700 leva o máximo do frame de 18 → 24 → 35.
- **Ganho digital** (0x020E/0x020F, formato 8.8): campo de **10 bits**. De
  `0x100` (1×) até `0x3ff` (~4×) o brilho sobe; a partir de `0x400` o sensor
  emite frame constante no nível de preto. Exposto como `V4L2_CID_ANALOGUE_GAIN`
  porque o libcamera trata esse ID como obrigatório e descarta o sensor inteiro
  sem ele — não há ganho analógico separado para pôr no lugar.
- **Ganho analógico SMIA (0x0204/0x0205) não existe** — lê `0xff` nas duas
  metades, como qualquer registrador não implementado.
- Toda escrita de controle vai dentro de grouped parameter hold (0x0104 = 1 … 0).

#### O que ainda falta

- **libcamera.** A IR **aparece** no `cam -l` (`camera 1`,
  `/base/soc@0/cci@ac15000/i2c-bus@0/camera@24`) desde que o driver exponha
  `V4L2_CID_ANALOGUE_GAIN` — sem ele o libcamera descarta o sensor. Mas capturar
  por ele ainda não funciona: o soft-ISP responde `Unsupported input format
  R10_CSI2P`, porque o debayer não lida com RAW10 monocromático. A captura útil
  é via `v4l2-ctl` no nó do camss (`tools/ir-camera-capture.sh`). O erro do
  debayer aparece no log mesmo ao usar a RGB — é da enumeração da IR e é inócuo.
- **Convivência com a RGB.** As duas disputam CSID0/VFE0_RDI0, e o script de
  captura solta o link da RGB antes de montar o da IR. Streaming simultâneo não
  foi testado e provavelmente exige RDI diferentes no mesmo VFE.

### Câmera IR — histórico do bloqueio (superado)

> Os itens abaixo preservam a investigação e suas conclusões intermediárias,
> inclusive hipóteses depois refutadas. O estado confirmado atual é o da seção
> **Câmera IR — FUNCIONANDO (2026-08-31)** acima.

- **DSDT HID:** QCOM0C99 = "Qualcomm Spectra 695 ISP Camera Auxiliary Sensor Device" (WOA-Project BOM)
- **Modelo sensor:** Hynix HM1092, confirmado pelo pacote Qualcomm/ASUS; QCOM0C99 é o device ISP auxiliar, não o identificador direto do sensor
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
# Após boot limpo, confirmar o autostart tardio
systemctl is-enabled vivobook-camera.service  # enabled
systemctl is-active vivobook-camera.service   # active

# Fallback manual, se necessário
vivobook-camera start

# Verificar probe
sudo dmesg | grep -E '(vivobook_cam|ov02c10|Error|fail)' | grep -v overlay

# Verificar devices
ls /dev/video* /dev/media*
ls /sys/bus/i2c/drivers/ov02c10/

# Testar câmera RGB
cam -l
cam -c 1 --capture=1 --stream role=still,width=1920,height=1080,pixelformat=XRGB8888 --file=/tmp/ov02c10-still.bin
cam -c 1 --capture=60 --stream role=video,width=1280,height=720,pixelformat=XRGB8888 --file=/tmp/ov02c10-video-#.bin

# Verificar IR (se probou)
sudo i2cdetect -y 9   # CCI0 bus 0
sudo i2cdetect -y 10  # CCI0 bus 1

# GUI: o serviço já reinicia WirePlumber
snapshot
```

### Validação física pós-reboot — 2026-08-24

- service `enabled/active` e módulo carregado automaticamente após o display
  manager; teclado e touchpad registraram antes do overlay;
- still XRGB8888 1920×1080: 8.294.400 bytes;
- vídeo XRGB8888 1280×720: 60/60 frames, aproximadamente 30 fps;
- PipeWire publicou `ov02c10 [libcamera]` e `Built-in Front Camera`;
- `systemctl stop` manteve o módulo carregado, como projetado; unload só por
  reboot.
- o tuning YAML foi usado; com o kernel 7.2 patchado e o libcamera
  `0.7.1-1.fc44.x1407qa` os avisos de metadata/helper do libcamera e os avisos
  CAMCC sumiram, e a captura concluiu sem Oops/soft lockup.

## NUNCA FAZER

- `sudo rmmod vivobook_cam_fix` — CAMCC corrompe GDSCs ao recarregar, kernel crasha, shutdown trava
- `sudo rmmod camcc_x1e80100` — mesmo problema
- Trocar `ExecStop=/bin/true` por `modprobe -r`/`rmmod` sem antes provar um
  teardown completo de sensor → CAMSS/CCI → CAMCC em um kernel descartável.
  O estado `inactive` da unit **não significa módulos descarregados**.
- Adicionar em `/etc/modules-load.d/` — CCI cria I2C buses que podem deslocar numeração (vivobook_kbd_fix já usa DT path, mas outros módulos podem quebrar)
- Mudar GPIO5 DIG_OUT_SOURCE_CTL para 0x00 — mata a tela

## Handoff — próxima sessão

- O autostart gráfico tardio foi validado após reboot físico: serviço
  `enabled/active`, auditoria 16/16, still/vídeo e fonte PipeWire funcionais,
  sem Oops ou soft lockup.
- Uma captura `cam` direta pode disputar `/dev/media0` enquanto o WirePlumber
  reconstrói o grafo. Reiniciar apenas `wireplumber.service` republica a fonte;
  não é necessário recarregar módulos.
- Manter `ExecStop=/bin/true`; descarregar somente por reboot.

## Referências

- [alexVinarskis Zenbook A14 patches](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14)
- [alexVinarskis ACPI tables PR](https://github.com/aarch64-laptops/build/pull/134)
- [Bryan O'Donoghue CAMSS v9 patches](https://lkml.org/lkml/2026/2/26/1172)
- [Bryan O'Donoghue Hamoa camera DTSI](https://lkml.org/lkml/2026/2/26/1238)
- AeoB firmware: `/lib/firmware/qcom/CAMF_RES_MTP_Pw.bin`, `CAMI_RES_MTP.bin`, `CAMP_RES_MTP.bin`
