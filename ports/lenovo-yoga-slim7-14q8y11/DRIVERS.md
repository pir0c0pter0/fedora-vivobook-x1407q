# Drivers, firmware e ports — 2026-11-13

> **Histórico (13/11/2026).** Este documento descreve o planejamento e os testes anteriores ao bring-up físico de 16/11. O estado atual está no [README do porte](/ports/lenovo-yoga-slim7-14q8y11/README.md) e em [docs/ESTADO-ATUAL.md](/ports/lenovo-yoga-slim7-14q8y11/docs/ESTADO-ATUAL.md).

Pausado até a retomada pelo usuário. R2 demonstrou execução Linux e seis CPUs em EL2 por transcrição parcial; live estável e periféricos não validados. USB R3-CONS pronto, ejetado e ainda sem teste físico. Ver [retomada](RETOMADA.md) e [análise R3](iso/RESULTADO-R3-CONS.md). Fonte existente não equivale a driver funcionando neste aparelho; binários .sys não são drivers Linux.

## Base e diferenças entre variantes

Na rodada da [ISO experimental](iso/README.md), o kernel Qualcomm fixado foi
compilado para aarch64, incluindo Kalambo e suporte ao live EROFS. Niri 26.04
foi instalado do Fedora; Noctalia 5.5.0 foi compilado e empacotado para aarch64,
com versão executada no chroot. A ISO R2 inclui um DTB mínimo Kalambo, sem descrição completa da placa.
O teste físico que mostrou os seis núcleos usou ACPI. Isso não demonstra que os
drivers Qualcomm liguem aos dispositivos descritos pelas tabelas Windows.

O DSDT coletado foi decompilado com ACPICA 20260930. Foram identificados os
barramentos GENI e os IDs QTEC0001 (teclado), ELAN06FA (touchpad) e GXPT7936
(touch), confirmados no inventário PnP ativo. A carga conjunta DSDT/SSDT
reportou `AE_ALREADY_EXISTS` em `\\_SB.SOID`; não tratar o namespace combinado
nem os GPIOs virtuais do Windows como wiring físico já validado.

Referências verificadas:

- [Linux Linus](https://github.com/torvalds/linux/tree/7e1392a42ea288d70a266f6553fe06f57f8647ea), revisão de 2026-11-12.
- [Qualcomm for-next](https://kernel.googlesource.com/pub/scm/linux/kernel/git/qcom/linux/+/6a876df4686788cd39128b62d7fcbff62f39278f/), revisão de 2026-11-12.
- [Série Kalambo v9, 16/out](https://lkml.iu.edu/2610.2/00931.html): partes de SoC e CRD; binding, SCM e UBWC já haviam seguido separadamente.
- [DTS Kalambo](https://kernel.googlesource.com/pub/scm/linux/kernel/git/qcom/linux/+/6a876df4686788cd39128b62d7fcbff62f39278f/arch/arm64/boot/dts/qcom/kalambo.dtsi): inclui Mahua, remove CPUs/cluster, corrige mapa de CPUs, domínio SCMI, IMEM, mailbox e intervalos PDC.
- [DTS Yoga Elite](https://github.com/torvalds/linux/blob/7e1392a42ea288d70a266f6553fe06f57f8647ea/arch/arm64/boot/dts/qcom/glymur-lenovo-yoga-slim7x.dts): referência para periféricos da placa, condicionada a comparação com ACPI/IDs do Plus.

O DTS da CRD descreve a placa de referência Qualcomm. Não é um DTB de notebook Lenovo. Trocar apenas `compatible` no DTS Elite também não resolve CPU, memória reservada, alimentação, GPU ou conexões dos periféricos.

## Matriz de trabalho

| Área | Driver/artefato a usar ou investigar | Estado e trabalho necessário no Plus |
|---|---|---|
| Boot UEFI | EFI arm64, kernel, DTB da placa e initramfs correspondentes | Fedora aarch64 disponível; execução do kernel observada; faltam DTS completo e boot estável |
| SoC/CPU | `kalambo.dtsi` sobre `mahua.dtsi`/`glymur.dtsi`; PSCI, SCMI, clocks, interconnects, RPMh, pinctrl, PDC, SMMU | Base Kalambo em `for-next`; seis CPUs iniciadas na R2; cpufreq, estabilidade e energia ainda pendentes |
| Placa Lenovo | Novo DTS Kalambo do Yoga e binding de variante, seguindo revisão upstream | Principal port ainda não localizado; usar a coleta ACPI/PnP preservada e validar IRQs, GPIOs, reguladores e memória reservada |
| NVMe/PCIe | NVMe, PCIe Qualcomm, PHYs e SMMU | Confirmar controlador/PHY presentes em Kalambo; descrições PCIe de Glymur não são todas preservadas em Mahua |
| USB-C/boot por USB | DWC3/xHCI, QMP PHY, PMIC GLINK, UCSI/power delivery conforme hardware | Validar cada porta, armazenamento USB e carregamento; firmware remoto pode afetar a disponibilidade da raiz live |
| GPU/OpenGL/Vulkan | Kernel DRM/MSM + Adreno; Mesa Freedreno/Turnip; firmware GMU/SQE/ZAP solicitado pelo driver | Determinar chip ID real e suporte correspondente. Não deduzir GPU/firmware do nome X2; Niri requer aceleração funcional |
| OLED/eDP | DRM/MSM DPU/DP, PHY, panel-edp e EDID correto | PSREF oferece WUXGA 60 Hz e 2.8K 120 Hz, touch opcional; não fixar painel Samsung do Elite sem identificação |
| Teclado/touchpad/touch | I2C GENI, I2C-HID, HID-multitouch, GPIO/IRQ | Há quirk de reset do teclado Yoga G11 no [i2c-hid-core](https://github.com/torvalds/linux/blob/7e1392a42ea288d70a266f6553fe06f57f8647ea/drivers/hid/i2c-hid/i2c-hid-core.c); confirmar VID/PID e wiring no Plus |
| EC/teclas Fn/temperatura | `CONFIG_EC_LENOVO_YOGA_SLIM7X_GEN11`, driver `lenovo-yoga-slim7x-gen11-ec.c` | Driver já presente em Linus; confirmar se o Plus usa o mesmo EC/endereços/IRQ antes de habilitar seu nó |
| Bateria/carregador | Qualcomm battmgr/PMIC GLINK e/ou interfaces do EC conforme placa | Medir estado, corrente, tensão, carga e hotplug; leitura disponível não prova política térmica segura |
| Wi-Fi | ath12k/pwrseq se confirmado WCN7850; firmware e board data correspondentes | Elite descreve WCN7850; identificar PCI/subsystem IDs do Plus antes de escolher `board-2.bin` |
| Bluetooth | btqca/hci_uart e firmware NVM/rampatch correspondente | Confirmar UART, alimentação, endereço e revisão do controlador |
| DSP/energia | QCOM Q6V5 PAS/remoteproc, GLINK, SMEM, SoCCP e imagens/DTBs de subsistemas | Extrair firmware do próprio Lenovo quando ausente upstream; caminhos devem coincidir com o DTS final |
| Áudio | ALSA SoC Qualcomm/AudioReach, SoundWire, codecs/amplificadores, topologia `.bin`, alsa-ucm-conf, PipeWire/WirePlumber | Topologia e UCM específicos da placa são necessários; não usar mapeamento do ASUS ou do ThinkPad como produto final |
| Suspensão/térmica | cpuidle/PSCI, SCMI, TSENS/thermal, RPMh, wake IRQs e EC | Validar inicialmente em bancada com carregador e recuperação disponíveis; não importar política de ventoinha nem limites do ASUS |
| Webcam RGB/IR | CAMSS/CCI, sensores, reguladores, clocks, libcamera e integração PipeWire | Suporte não demonstrado no Plus; identificar sensores. Iluminador IR depende da placa, não reaproveitar calibração ASUS |
| USB4/DP externo | Host router Qualcomm/Thunderbolt, PHYs/retimers, altmode e DRM conforme placa | Funcionalidade adicional a validar separadamente de USB3 e carga; nenhuma promessa baseada na presença física de USB-C |
| NPU | FastRPC/CDSP e runtime compatível com esta geração | Fora do caminho crítico da instalação; sem spoof de SoC e sem runtime X1 aplicado automaticamente |
| Vídeo acelerado | Iris/V4L2, firmware de codec e integração Mesa/GStreamer/FFmpeg conforme suporte | Não bloqueia primeiro boot; requer teste específico de decode/encode |
| Cores | ICC/ICM de fábrica, EDID, compositor e aplicativos com gestão de cor | Requisito do usuário; ver [CORES.md](CORES.md). Preservação dos arquivos e aplicação efetiva são critérios distintos |
| Desktop | Fedora 45 aarch64, Niri, Noctalia **5.5.0**, portais, PipeWire, agente de autenticação | Instalação do desktop depois de GPU/DRM; Noctalia 5.5.0 aarch64 já construído/verificado em VM; sessão física pendente |

## Firmware: origem e contrato de arquivos

Os arquivos do aparelho já foram obtidos pelo [coletor Windows deste porte](windows/LEIA-ME.md): pacotes completos, DriverStore, firmware solto e correspondência das origens, preservados em `local/windows/2026-11-13/`. Ver o [relatório de integridade e limites](COLETA-WINDOWS-2026-11-13.md). Ainda falta selecionar e validar o conjunto Linux conforme o DTS real.

Fontes: [Lenovo para o modelo exato](https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/yoga-series/yoga-slim-7-14q8y11/downloads/driver-list), Windows original e [linux-firmware/WHENCE](https://gitlab.com/kernel-firmware/linux-firmware/-/blob/main/WHENCE). Consultar licenças no WHENCE antes de redistribuir blobs.

No WHENCE consultado havia firmware genérico Glymur, ZAP `qcom/glymur/gen80100_zap.mbn` e topologias de algumas placas. Não foram encontradas entradas com `kalambo`, `mahua` ou `83QR`. Isso não demonstra que nenhum firmware compartilhado serve: a necessidade é derivada do kernel/DTS escolhido e dos pedidos reais do driver.

O **Elite**, por exemplo, solicita estes caminhos no DTS; são uma referência de contrato e **não o manifesto validado do Plus**:

```text
qcom/glymur/LENOVO/83QR/qcadsp8480.mbn
qcom/glymur/LENOVO/83QR/adsp_dtbs.elf
qcom/glymur/LENOVO/83QR/qccdsp8480.mbn
qcom/glymur/LENOVO/83QR/cdsp_dtbs.elf
```

O [extrator qcom-firmware-extract 21](https://sources.debian.org/src/qcom-firmware-extract/21/qcom-firmware-extract) reconhece o Yoga Gen 11 como Glymur. No Plus, revisar essa seleção antes de executar. O fallback de `extract-qcom-firmware.sh` deste repositório achata caminhos e foi feito para ASUS: não serve como extrator Lenovo sem adaptação.

Manifesto exigido para cada arquivo efetivamente usado: origem Windows/pacote/commit, caminho de origem, caminho Linux exato, tamanho, SHA-256, licença e driver/DTS que o solicita. Não renomear firmware de outra placa só para eliminar `ENOENT`.

## Outros ports como referência

- [Lenovo Diagnostics ARM 5.2.1 — análise local](ISO-LENOVO-DIAGNOSTICS-5.2.1.md): mídia oficial com Stubble e DTBs X1/anteriores; não contém o DTB Yoga Kalambo nem os perfis LEN88AE. Não fecha os bloqueios deste porte.
- [Qualcomm Linux kernel](https://github.com/qualcomm-linux/kernel) e [qcom-deb-images](https://github.com/qualcomm-linux/qcom-deb-images): referência oficial da preview Debian; comparar patches e firmware, mantendo Fedora como userspace alvo.
- [Ubuntu Concept 26.10](https://discourse.ubuntu.com/t/ubuntu-concept-26-10-snapdragon-edition/88518): referência de integração Snapdragon, extração de firmware e boot. A existência da imagem não comprova suporte a este Yoga Kalambo.
- [Omarchy aarch64](https://github.com/omacom/omarchy-pkgs/blob/master/pkgbuilds/linux-omarchy-aarch64/README.md): catálogo comunitário de backports e DTBs; inclui Yoga Glymur. Usar para rastrear patches até seus autores, sem instalar pacotes Arch em Fedora.
- [linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology) e [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf): buscar a combinação de card/model/topologia confirmada no Lenovo, não apenas o nome do SoC.

Não há versão mínima única de kernel ou Mesa certificada por esta pesquisa para o Plus. A baseline de bring-up é a revisão Qualcomm registrada, seguida da revisão dos drivers e do novo DTS de placa. Selecionar versões por artefatos presentes e resultados, não por promessa de uma versão futura.
