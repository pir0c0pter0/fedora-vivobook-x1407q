# Fedora no Lenovo Yoga Slim 7 14Q8Y11 — Snapdragon X2 Plus

Porte do Fedora 45 aarch64 para o Lenovo Yoga Slim 7 14Q8Y11 (DMI 83QR), Snapdragon X2 Plus **X2P-42-100**, SoC Qualcomm **Kalambo**, GPU Adreno X2-45, painel OLED eDP 1920x1200.

Esta pasta é independente do projeto ASUS Vivobook X1407QA que ocupa o resto do repositório. Nada daqui se aplica ao ASUS, e os scripts e módulos `vivobook_*` não devem ser executados no Lenovo.

**Estado em 17/11/2026:** o Fedora está instalado no SSD interno e liga sozinho em um desktop utilizável. É um trabalho em andamento, feito num único aparelho; não há ISO pronta para instalar.

A integração `gwnx2d1` passou no slot `try` e no boot normal pelo `current`,
com vídeo, EC, RTC e USB automáticos.
O Wi-Fi conecta em paralelo ao desktop, sem espera por link online.
O USB agora exige apenas a placa Wi-Fi ativa e os trilhos em uso, sem
associação a uma rede. O teste offline e o gatilho udev `add|move` no slot
`try` e no boot normal pelo `current` passaram: o USB subiu antes da conexão
Wi-Fi, preservando vídeo, bateria e NVMe.

**USB3 permanente validado em 17/11:** direita a **5 Gbit/s** e as duas
esquerdas a **10 Gbit/s**, nas duas orientações. A direita precisou do patch
Qualcomm de calibração do QMP combo e do limite Gen1: 16 GiB lidos em cada
orientação a 296/288 MB/s, sem resets/erros e com hashes de amostras iguais.
USB2 na direita também passou. As esquerdas foram revalidadas com o novo módulo.

O carregamento automático passou no `try` e no boot normal pelo `current`;
`good` permanece intacto e a base USB2 anterior tem backup. Vídeo, Wi-Fi,
NVMe, bateria, EC e RTC preservados. Boot normal em 23,491 s; a espera extra
antecede o serviço USB3, no caminho de vídeo/GPU/SMMU já observado antes.
Gen2 na direita continua instável. A Lenovo especifica três portas
[USB4 de 40 Gbit/s](https://psref.lenovo.com/Product/Yoga_Slim_7_14Q8Y11?tab=spec),
capacidade ainda não habilitada neste porte Linux.
Detalhes em [ESTADO-ATUAL](docs/ESTADO-ATUAL.md) e receita de build/instalação
em [install/usb](install/usb/README.md).

## O que funciona

Sobe sozinho no boot normal:

| Item | Observação |
|---|---|
| Boot por Device Tree, 6 núcleos | ACPI não é viável neste modelo (ver causas abaixo) |
| Vídeo real 1920x1200 a 60 Hz e brilho | `msm`/eDP com o PHY corrigido; brilho pelo painel, 2047 níveis |
| GNOME | Render por software; a GPU ainda não é usada |
| Teclado, touchpad, tela de toque | I2C-HID |
| Wi-Fi e Bluetooth | WCN7850, `ath12k` |
| NVMe | Raiz btrfs no SSD interno |
| Bateria | `pmic-glink`, anexando ao coprocessador que o firmware já iniciou |
| Frequência do processador | SCMI, 355 MHz a 4,03 GHz |
| Sensores, ventoinha, luz do teclado e teclas de função | EC embutido, com interrupção no `gwnx2d1` |
| USB2 / USB3 | Direita Gen1 (5 Gbit/s), esquerdas Gen2 (10 Gbit/s), nas duas orientações; serviços protegidos por PCIe/trilhos ativos, sem esperar associação Wi-Fi |
| Orientação USB-C (UCSI) | Automática nas três portas; carga e troca de papel não testadas |
| Tampa e chave de privacidade da câmera | `gpio-keys`; tampa ignorada pelo logind, suspensão mascarada |
| Relógio de hardware | `rtc1` + offset em arquivo, serviço automático |
| Proteção térmica | 24 zonas de CPU com trip passivo de 105 °C; carga anterior atingiu 61 °C |

Provado em boot de teste, ainda não promovido ao boot normal:

| Item | Observação |
|---|---|
| Som nos 4 alto-falantes | ADSP + LPASS + 4 amplificadores WSA884x; microfones e fone não testados |

## O que falta

- **GPU:** o kernel sobe a Adreno X2-45, mas o Mesa 26.2.3 não reconhece o chip. Há um Mesa recompilado em `install/mesa-x2-45/`, não testado. Sem isso não há Niri.
- **Kernel novo:** o R4 (`install/kernel-r4/`, base v7.4-rc3) traz firewall, zram e o módulo de som que falta; nunca deu boot e ainda precisa do patch completo do vídeo.
- **Câmeras (RGB e infravermelha):** só a chave de privacidade. Falta o driver do PMIC das câmeras e a confirmação de três GPIOs.
- **Suspensão:** mascarada; não testada.
- **Gen2 na direita:** ainda apresenta resets/erros; mantida em Gen1 estável. USB4, saída de vídeo USB-C, microfones e fone seguem pendentes.
- **Firewall:** o kernel em uso não tem `nf_tables`.

## Causas-raiz encontradas

1. **Boot ACPI reinicia:** o driver SMMUv2 genérico não tem o quirk Qualcomm para esta tabela IORT. O porte usa Device Tree.
2. **Boot por Device Tree travava:** o TLMM precisa de `gpio-reserved-ranges = <4 4>, <10 2>, <27 1>, <44 4>, <65 1>, <90 2>, <139 1>`.
3. **A tela apagava ao subir o Wi-Fi:** ciclo de liga/desliga do PCIe em adiamento de probe; resolvido com ordem de carga (pwrctrl/pwrseq antes do PHY).
4. **Tela preta com o driver de vídeo real:** dois defeitos no PHY eDP v8 (Glymur) do kernel, presentes também no upstream. A tabela de PLL estava errada e o link não fechava; e o divisor do relógio de pixel em 5,4 Gbit/s deixava o vídeo a 30 Hz. Correção em [`patches/phy-qcom-edp-glymur-pll-v2.patch`](patches/phy-qcom-edp-glymur-pll-v2.patch). Só a taxa de 5,4 Gbit/s foi comprovada no hardware.

## Onde está cada coisa

| Caminho | Conteúdo |
|---|---|
| [`docs/ESTADO-ATUAL.md`](docs/ESTADO-ATUAL.md) | Estado completo, mecanismo de cada item, armadilhas e próximos passos. Comece pela seção "COMECE AQUI" |
| [`docs/ROTEIRO-TESTE-GWNX2.md`](docs/ROTEIRO-TESTE-GWNX2.md) | Roteiro do boot de teste combinado de 16/11 |
| `dts/` | Device Trees do porte. Em uso: `gwnx2d1`, validado no `try` e no boot normal; reserva `gwnb1` |
| `dts/fragments/` | Um fragmento por subsistema (som, USB, EC, RTC, tampa, térmica, câmera, toque, Bluetooth) |
| `patches/` | Correção do PHY eDP para a árvore do kernel |
| `install/install-yoga.sh` | Instalador usado no SSD interno (apaga o disco de destino) |
| `install/video/` | Instalação do vídeo real e script de diagnóstico do eDP |
| [`install/usb/`](install/usb/) | USB com a placa Wi-Fi ativa, por regra udev; sem associação nem espera de rede |
| `install/audio/` | Subida da cadeia de som e ajuste do mixer |
| `install/ec-rtc/`, `install/power/`, `install/camera/` | Teclas de função e relógio, tampa e térmica, câmera |
| `install/kernel-r2/`, `kernel-r3/`, `kernel-r4/` | Configuração, patches e scripts dos kernels candidatos |
| `install/mesa-x2-45/` | Patch e build do Mesa para a Adreno X2-45 |
| `iso/` | Menu GRUB e scripts da mídia de diagnóstico usada no bring-up |
| `windows/` | Coletor PowerShell de drivers, firmware, ACPI e perfis do Windows original |
| [`CORES.md`](CORES.md), [`COLETA-WINDOWS-2026-11-13.md`](COLETA-WINDOWS-2026-11-13.md), [`ISO-LENOVO-DIAGNOSTICS-5.2.1.md`](ISO-LENOVO-DIAGNOSTICS-5.2.1.md), [`sources.json`](sources.json) | Referência: perfis de cor Lenovo, coleta do Windows, ISO oficial, fontes |
| [`WORKFLOW.md`](WORKFLOW.md) | Processo atual para USB3 no topo; planejamento de 13/11 preservado abaixo |
| [`DRIVERS.md`](DRIVERS.md), `iso/RESULTADO*.md` | Histórico do planejamento de 13/11 |

A pasta `local/` não é versionada: guarda a árvore e os builds do kernel, firmware e ACPI coletados do aparelho, os DTBs compilados e os registros dos testes físicos. Binários (`*.dtb`, `*.ko`) também ficam fora; compile a partir das fontes.

## Base de kernel

Qualcomm `for-next`, commit `6a876df4686788cd39128b62d7fcbff62f39278f`, release `7.4.0-rc1-yoga-kalambo+`. O `kalambo.dtsi` existe nessa árvore; não há DTS upstream para este notebook. O `glymur-lenovo-yoga-slim7x.dts` (variante X2 Elite do mesmo chassi) serve de referência, mas não pode ser usado diretamente.

Os DTBs são compilados fora do kbuild, com `cpp` e o `dtc` da árvore do kernel; a receita está em `docs/ESTADO-ATUAL.md`.

## Avisos

- Tudo aqui foi validado em **um** aparelho. Os Device Trees dirigem reguladores e GPIOs; usar em outro modelo pode danificar o hardware.
- `install/install-yoga.sh` apaga o disco de destino.
- Firmware do ADSP, da GPU e do Bluetooth vem do Windows original ou do `linux-firmware` e não é distribuído neste repositório.
