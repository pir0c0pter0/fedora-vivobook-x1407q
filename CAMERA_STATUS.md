# Camera Fix — Status e Progresso

## O que foi feito

### Módulo DKMS: `vivobook-cam-fix`

Criado módulo DKMS que aplica um **DT overlay em runtime** via `of_overlay_fdt_apply()` para adicionar os nós de câmera que faltam no DTB do Zenbook A14.

**Arquivos criados em `/usr/src/vivobook-cam-fix-1.0/`:**

| Arquivo | Função |
|---------|--------|
| `vivobook_cam_overlay.dts` | DT overlay source com todos os nós de câmera |
| `vivobook_cam_fix.c` | Módulo kernel que embute e aplica o overlay |
| `Makefile` | CPP+DTC → .dtbo → xxd → .h → kbuild .ko |
| `dkms.conf` | Configuração DKMS padrão |

### O que o overlay adiciona

| Nó DT | Endereço | Driver in-tree | Status probe |
|-------|----------|---------------|-------------|
| CAMCC (Camera Clock Controller) | 0xade0000 | `camcc-x1e80100` | **OK** — todos os clocks registrados (MCLK0-7, CCI, CSIPHY, etc.) |
| CCI0 (Camera I2C) | 0xac15000 | `i2c-qcom-cci` | **OK** — 2 buses I2C criados (i2c-9, i2c-10) |
| CCI1 (Camera I2C) | 0xac16000 | `i2c-qcom-cci` | **OK** — 2 buses I2C criados (i2c-11, i2c-12) |
| CAMSS (ISP pipeline) | 0xacb7000 | `qcom-camss` | **OK** — CSID, VFE, CSIPHY registrados, IOMMU group 15 |
| OV02C10 sensor | CCI0 bus 0, 0x36 | `ov02c10` | **FALHA** — I2C timeout, sensor não responde |

### O que funciona

- `of_overlay_fdt_apply()` aplica overlay com sucesso
- DTB tem `__symbols__` — referências simbólicas (`&gcc`, `&tlmm`, `&rpmhpd`, etc.) resolvidas automaticamente
- CAMCC proba e registra ~80 clocks (MCLK4 a 19.2MHz confirmado)
- CCI0 e CCI1 probam — 4 buses I2C CCI operacionais
- CAMSS proba com IOMMU, interconnects, power domains
- `videodev` e `mc` (media controller) carregam automaticamente
- Module unload funciona (`of_overlay_remove()`)

## O que NÃO funciona

### Sensor OV02C10 não responde no I2C

**Erro:** `i2c-qcom-cci ac15000.cci: master 0 queue 0 timeout` → `ov02c10 9-0036: Error reading reg 0x300a: -110`

**Scan completo dos 4 buses CCI:** todos vazios — nenhum device em nenhum endereço.

### Causa raiz: sensor sem energia + overlay falha

**Descoberta 1: pm8010 camera PMIC não existe fisicamente neste Vivobook.**

| Evidência | Detalhe |
|-----------|---------|
| SPMI bus scan | Devices 0-00 a 0-09 presentes. **0-0c (pm8010) ausente** |
| DTB original | pm8010 com `status = "disabled"` — fabricante sabia que não está presente |
| Reguladores RPMH | Registraram (`vreg_l1m` a `vreg_l7m`) mas são fantasma — RPMH envia comandos para PMIC que não existe |

**Descoberta 2: Reguladores RPMH do pm8010 registram via overlay.**

Adicionando nós `qcom,pm8010-rpmh-regulators` sob `&apps_rsc` no overlay, os reguladores RPMH registram e reportam voltagens corretas. Porém, RPMH é "fire-and-forget" — os comandos vão para firmware ARM TF-A que repassa ao pm8010 via SPMI. Como o pm8010 não existe fisicamente, a tensão nunca é entregue ao sensor.

**Descoberta 3: Overlay falha com -22 (EINVAL) nos nós CCI i2c-bus.**

O changeset notifier do overlay retorna -22 ao processar os child nodes `i2c-bus@0`/`i2c-bus@1` dentro de CCI0/CCI1. Os adaptadores CCI I2C são criados (i2c-0 a i2c-3), mas o overlay apply falha. Mesmo quando falha, os CCI adapters **persistem** porque o rollback do OF overlay não remove devices que já probaram.

**Descoberta 4: CCI adapters quebram numeração I2C de outros módulos.**

Os 4 adaptadores CCI (i2c-0 a i2c-3) são criados ANTES dos Geni I2C, empurrando `b94000.i2c` (teclado) de bus 4 para bus 8. O módulo `vivobook_kbd_fix` foi corrigido para buscar adapter por DT path (`/soc@0/geniqup@bc0000/i2c@b94000`) ao invés de bus number fixo.

**Tentativa com reguladores do PMIC principal:**
- Usados `vreg_l9b_2p9` (AVDD), `vreg_l12b_1p2` (DVDD), `vreg_l15b_1p8` (DOVDD)
- Estes reguladores existem e funcionam, MAS provavelmente não estão fisicamente conectados ao módulo de câmera

## Descobertas de hardware

| Item | Valor | Fonte |
|------|-------|-------|
| Kernel 6.19 tem suporte x1e80100 CAMSS | Sim | `modinfo qcom-camss` → `qcom,x1e80100-camss` |
| Kernel 6.19 tem CAMCC x1e80100 | Sim | `modinfo camcc-x1e80100` |
| Kernel 6.19 tem OV02C10 driver | Sim | `modinfo ov02c10` → `ovti,ov02c10` |
| `CONFIG_OF_OVERLAY=y` | Sim | `/boot/config-*` |
| `of_overlay_fdt_apply()` exportado | Sim | `/proc/kallsyms` |
| DTB tem `__symbols__` | Sim | `/sys/firmware/devicetree/base/__symbols__/` |
| GPIO 100 | Function `cam_aon` (não `cam_mclk`) | TLMM pinmux-functions |
| GPIOs 105/106 | `cci_i2c` (CCI1 bus 0) | TLMM |
| GPIOs 235/236 | `aon_cci` (CCI1 bus 1 AON) | TLMM |
| GPIOs 101-104 | `cci_i2c` (CCI0 bus 0/1) | TLMM |
| GPIO 110 | `cam-indicator-en` (LED da câmera) | DTB pinctrl |
| Reserved memory | `camera@8e100000` (8MB) | DTB |
| pm8010 SPMI | **NÃO PRESENTE** no barramento | `/sys/bus/spmi/devices/` |

## Lições aprendidas

### CCI adapters quebram I2C bus numbering

**NUNCA auto-carregar `vivobook_cam_fix` via `modules-load.d`** enquanto o overlay usa CCI nodes. Os CCI adapters criam I2C buses dinâmicos que deslocam TODOS os outros bus numbers, quebrando módulos que dependem de bus number fixo (ex: teclado).

**Fix aplicado:** `vivobook_kbd_fix` agora busca adapter por DT path ao invés de bus number. Arquivo `/etc/modules-load.d/vivobook-cam-fix.conf` removido. Carregar câmera somente via `sudo insmod`.

## Próximos passos

### Opção 1: Descobrir o power rail correto (mais provável de funcionar)

O módulo de câmera do Vivobook provavelmente tem um **enable GPIO** ou usa um **regulador fixo** que não identificamos. Possibilidades:

1. **GPIO de power enable** — algum GPIO não mapeado que liga o módulo de câmera
2. **Regulador fixo controlado por GPIO** — tipo `VREG_CAM_3P3` em algum GPIO
3. **Regulador always-on** do PMIC principal que já alimenta a câmera, mas o sensor precisa de reset/MCLK específico

**Como investigar:**
- Extrair ACPI/DSDT do Windows (reinstalar Windows ou usar outro X1407QA)
- Inspecionar fisicamente o flex cable da câmera e os pinos
- Comparar com schematic do Zenbook A14 (se disponível)
- Verificar com `alexVinarskis` repo se o Purwa tem power topology diferente

### Opção 2: Esperar upstream

Bryan O'Donoghue (Linaro) tem patches v8 para CAMSS x1e80100. O readme dele diz **"not fully working on Purwa (X1P)"** — pode ser exatamente este problema de power.

- Patches: [LKML v8](https://lkml.org/lkml/2026/2/25/1157)
- Estimativa: kernel ~6.21/6.22
- Quando houver suporte upstream para Purwa, adaptar os nós DT deles para o nosso overlay

### Opção 3: Extrair info do Windows

Se Windows for reinstalado:
1. Exportar DSDT/SSDT via `acpidump`
2. Verificar driver de câmera Windows para pinout
3. Extrair camera firmware (se existir)

## Como testar

```bash
# Build (após mudanças no .dts)
cd /usr/src/vivobook-cam-fix-1.0
make vivobook_cam_overlay.dtbo.h
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules

# Testar (requer reboot entre tentativas — CAMCC não suporta re-probe)
sudo insmod vivobook_cam_fix.ko
sudo dmesg | tail -30

# Scan I2C
sudo i2cdetect -y 9   # CCI0 bus 0
sudo i2cdetect -y 10  # CCI0 bus 1
sudo i2cdetect -y 11  # CCI1 bus 0
sudo i2cdetect -y 12  # CCI1 bus 1

# Unload
sudo rmmod vivobook_cam_fix
```

## Resumo

| Etapa | Status |
|-------|--------|
| Módulo DKMS com DT overlay | **Feito** — funciona perfeitamente |
| CAMCC (camera clocks) | **Feito** — proba OK |
| CCI0 + CCI1 (camera I2C) | **Feito** — 4 buses funcionais (mas overlay falha -22 nos nós i2c-bus) |
| CAMSS (ISP pipeline) | **Feito** — proba OK com IOMMU |
| pm8010 RPMH regulators | **Feito** — registram via overlay, mas pm8010 não existe fisicamente |
| OV02C10 driver probe | **Bloqueado** — sensor sem energia (pm8010 ausente, power rail correto desconhecido) |
| Câmera funcionando | **Bloqueado** — precisa descobrir power topology |
