# Contexto limpo — Lenovo Yoga Slim 7 14Q8Y11 / Snapdragon X2 Plus

Atualizado em 2026-11-17 (perfil RGB do Windows instalado, reabertura recuperada e sincronismo IR ensaiado em quadro único). Fonte de verdade para retomada; históricos e snapshots não substituem este estado. As seções a partir de "Objetivo confirmado" vêm da consolidação de 13/11 e continuam válidas onde não conflitam com as seções abaixo.

## COMECE AQUI — estado em 17/11/2026 (fonte de verdade)

Caminhos: `R` = `<workspace>`; `P` = `R/fedora-vivobook-x1407q/.worktrees/lenovo-yoga-slim7-14q8y11-x2plus/ports/lenovo-yoga-slim7-14q8y11`; `B` = `P/local/iso-build`; `OUT` = `P/local/dtb-bisect-r5`; `D` = `P/local/physical-2026-11-16` (logs históricos); os testes de 17/11 ficam em `P/local/physical-2026-11-17/`.

### Calibração Windows e recuperação de reabertura — 17/11/2026

**Instalado e validado no boot normal `current`.** A RGB usa quatro
matrizes de correção de cor extraídas do Chromatix Windows associado ao
módulo deste Yoga, em `/etc/libcamera/ipa/simple/ov08x40.yaml`.
O [extrator e a revisão](../install/camera/WINDOWS-CALIBRATION.md) verificam
estrutura, CRC, vínculo pelo perfil/HWID e equivalência CHI/LVI. O perfil
conserva intervalos CCT, mas fixa os demais eixos do ISP; não representa
calibração individual nem todo o processamento Windows. Coeficientes e
blobs permanecem privados em `local/`.

| Validação final no Yoga | Resultado |
|---|---|
| Boot normal | 23,897 s; câmera em 23,871674 s, antes do GDM em 23,897372 s |
| RGB direta como usuário | 90 quadros RGB888 1920×1080; CCM original confirmada nos metadados, blacklevel4096 |
| PipeWire RGB | 1.800 buffers 1080p até EOS em 60,181 s |
| PipeWire IR | 1.800 buffers GRAY8 640×480 até EOS em 29,016 s, após RGB |
| WirePlumber | PID1718/NRestarts0 antes/depois; CPU e MDWE preservados; RGB padrão |
| Reabertura no ensaio anterior | 10 aberturas RGB×15 quadros e 10 IR×30, todas completas |
| Iluminador no boot normal | OFF físico em ee46/ee4e; ee67 bit0=1 |

O CCI ainda pode travar a primeira escrita de reset numa reabertura rápida.
As correções fazem reset na retomada, drenam a IRQ anterior e repetem
**somente** o reset inicial OV08X40 uma vez após ETIMEDOUT. O CAMSS desfaz
os subdispositivos já iniciados quando um start falha. Foram recuperados nove
timeouts no ensaio rápido e um no teste PipeWire normal, sem WARN/Oops/falha
de stream; o contorno pode acrescentar cerca de 100 ms na abertura.

Módulos permanentes atualizados em `updates/`:

| Módulo | SHA256 |
|---|---|
| CCI | `b7f3f921a932fb8e342d2949896def292e615a88e307d90fc857e023f5dd291c` |
| OV08X40 | `4ae757a56100c1d93529e1200aba6fe590b2f0efe25beadeed86bf47e6741c9d` |
| CAMSS | `31a4efbe2542c455799a6dd0dc0a4b220a44c2835c5299e6b67e4c7b3534308c` |

São sete módulos de câmera em updates, com o CAMSS corrigido; o stock
permanece em kernel/. O script agora exige também CAMSS vindo de updates;
20 testes offline passaram, incluindo recusa do stock antes de carregar.
Essa guarda adicional foi instalada após o boot de validação, com caminho
real conferido; não foi feito outro reboot só para a guarda.

**Sincronismo IR:** dois ensaios privados de um quadro usaram a rota do
Windows GPIO0 do VD55G0 → strobe do PMIC, a 50 mA totais/10 ms e exposição
manual1166 linhas (~9,994 ms). A versão final entregou 384.000 bytes,
faults0, canais/módulo OFF e ee67 restaurado a1, sem erros de cleanup.
Houve aumento de sinal compatível com iluminação adicional, mas a cena mudou
entre boots; isso não mede precisão fotométrica, largura elétrica ou rearme
contínuo. [Diagnóstico e evidências](../install/camera/ir/SYNCHRONIZATION.md).
Os módulos de quadro único, wrapper V4L2, DT com st,leds, opções, bind mounts
e unidades temporárias foram retirados. O iluminador não é automático nos apps.

**Limites:** sem carta de cores não foi medido erro colorimétrico. AWB/LSC
proprietários não foram portados. ExposureTime da libcamera0.7.2 mantém a
escala do modo inicial ao mudar para binning (59,217 ms publicados versus
33,315 ms reais no exemplo); AGC usa linhas/limites corretos. Ambas as rotas
Simple selecionam CSID0/VFE0; os testes são sequenciais, sem sincronização
RGB↔IR de exposição demonstrada. Suspensão/privacidade em apps não testadas.

DTB, kernel, initramfs e argumentos de current/good continuam intactos;
try foi restaurado de current, saved_entry=current, sem next_entry.
Vídeo, USB2/3, SoCCP, EC e RTC ativos; eDP, PCIe e bateria presentes.
A única unidade em falha continua sendo firewalld por falta de nf_tables.
Backups: `/root/camera-calibration-20261117/modules-before/`, estado anterior
do tuning e dos slots no mesmo diretório. Para reverter as correções, restaurar
CCI/OV08X40, remover somente o CAMSS acrescentado em updates, executar depmod
e reiniciar; para o perfil, remover/restaurar apenas o YAML do sensor.
Logs, fotos, RAWs e laudos: `local/physical-2026-11-17/camera-calibration/`,
principalmente `normal-*.txt`, `final-*.sha256`, `sync-v2*.txt` e `review/`.

### Integração inicial das câmeras — antes da calibração, 17/11/2026

**RGB, IR e iluminador responderam no Yoga.** A configuração passou no
`try` e foi promovida e repetida no boot normal `current`, sem carga manual.
O iluminador inicia desligado; somente um pulso manual foi emitido nesta rodada.

| Item | Evidência física |
|---|---|
| RGB OV08X40 | Quatro quadros RAW 3856×2416 a ~30 fps; imagem colorida inspecionada. Libcamera como usuário: 90 quadros 1920×1080 ABGR8888 a ~30 fps. No boot normal, PipeWire entregou 90 buffers 1080p até EOS |
| IR VD55G0 | Oito quadros RAW10 640×480 a ~60 fps; imagem inspecionada. Libcamera/GStreamer entregaram GRAY8; no boot normal, PipeWire entregou 60 buffers 640×480 até EOS |
| Iluminador PMH0101 | Um pulso de 50 mA totais/10 ms nos canais 1+4 durante 120 quadros IR com exposição/ganhos fixos. Quadros 23/24 coincidiram com o pulso; pico +22,54% global e +66,34% no centro, retorno ao basal no quadro 25. OFF físico confirmado em ee46/ee4e |

**Configuração instalada:** DTB compilado de
`install/camera/ir/yoga-camera-all-test.dts`, SHA256
`8283c271a15ebb3397338a0b1ce1a61f9c41e5fe328898ee3a7cc85f9b8a2544`,
em `current` e `try`. Kernel/initramfs permanecem os da base USB3;
kernel `7.4.0-rc1-yoga-kalambo+`. `saved_entry=current`, sem `next_entry`.
`good` permanece intacto. Backup completo dos slots anteriores e manifestos
em `/root/camera-workflow-20261117/{current-before,good-before,try-before}`.
Não substituir `good` pelo experimento de câmeras.

Seis módulos em `updates/`: PM8010 MFD/regulador, CCI corrigido, OV08X40,
VD55G0 e flash corrigido. `yoga.camera=1` e `cma=128M` nos argumentos;
blacklists de modprobe/initramfs impedem a carga antecipada. O serviço
`yoga-camera` depende de vídeo/USB3 e do gatilho udev existente, prepara
sensores/heaps antes do CAMSS e termina antes do GDM. Não espera associação
Wi-Fi. A regra dos DMA heaps concede acesso à sessão local nos heaps
`system`/`default_cma_region`. Não foi acrescentada permissão ao heap `reserved`.

No boot normal: câmera concluiu em 23,810963 s, GDM iniciou em 23,813315 s,
boot total 23,838 s. Vídeo, USB2/3, SoCCP, EC, RTC e GDM ativos; eDP conectado,
bateria presente, Wi-Fi/raiz NVMe acessíveis. Só a falha preexistente do
`firewalld` por falta de `nf_tables`. Não foram repetidas leituras de discos
externos: nesta rodada foram conferidos os controladores USB e seus serviços.

**Desktop:** dois dispositivos/fontes libcamera aparecem automaticamente;
RGB selecionada como padrão. Drop-in por usuário do WirePlumber define
`LIBCAMERA_SOFTISP_MODE=cpu`, mantendo `MemoryDenyWriteExecute=yes`.
O modo EGL/llvmpipe original caiu no JIT LLVM ao capturar pelo WirePlumber;
o modo CPU passou. No boot normal o PID ficou 1712 e `NRestarts=0` antes e
depois das duas capturas. A reserva CMA anterior de 32 MiB falhava em 1080p;
128 MiB passou. Não usar índices numéricos de `cam`: a ordem muda entre boots;
IDs completos e receitas em [install/camera](../install/camera/README.md).

**Travamento inicial:** o CCI stock deu segmentation fault e o aparelho
precisou de reboot forçado pelo usuário. O journal terminou antes da falha e
pstore estava vazio, portanto não há backtrace desse travamento. A auditoria
reproduziu uma completion não inicializada: reset usa master 0 mesmo quando
só o master 1 está habilitado. O patch inicializa todos os masters; reprodutor,
carga física e boots posteriores passaram. Não recarregar o CCI stock.
O flash também recebeu correção de teardown e de timeout: código 0 equivale
a 10 ms; o original programava 20 ms ao solicitar 10 ms.

PM8010 foi identificado por tipo 0x51/subtipo 0x41 em 0x08/0x09, após
BOB1=3,416 V e GPIO106 alto. RGB usa reset239/MCLK4/CCI1 bus1/CSIPHY4;
IR usa reset109/MCLK0/CCI0 bus0/CSIPHY0. LDOs e ligações estão descritos
em [power](../install/camera/power/README.md). Revisões separadas cobriram
DTS, drivers, pulso e inicialização; 19 cenários do serviço passaram com a
estrutura sysfs real (mídia em `/sys/bus/media/devices`, não `class/media`).

**Limites:** calibração genérica de imagem, avisos de metadados dos sensores,
ensaios curtos e sequenciais. Não foram testadas captura simultânea,
suspensão, reconhecimento facial, bloqueio nos aplicativos pela chave de
privacidade nem sincronização automática do iluminador. O evento
`flash-timeout-exceeded` apareceu após o pulso; emissão e OFF foram provados,
mas a largura elétrica exata não foi medida. Não usar torch para contornar
o timer nem aumentar a corrente a partir do valor encontrado no Windows.

Evidências privadas em `P/local/physical-2026-11-17/camera-workflow/`:
`current-final-validation.txt` inclui comandos, serviços, capturas e
manifestos; `integration-try-v2.txt`, `pipewire-cpu-test.txt`,
`cci-independent-review.md`, `power/promotion-evidence-review.md` e
`ir/ir-pulse-validation.md` completam a revisão. Fotos, RAWs e dumps ficam
somente em `local/`. Build, instalação e rollback em
[install/camera](../install/camera/README.md).

### USB3 permanente — estado antes das câmeras, 17/11/2026

**Direita funcionando em USB3 Gen1 (5 Gbit/s); esquerdas em Gen2 (10 Gbit/s).**
O usuário priorizou corrigir a direita. A solução validada combina o
patch Qualcomm de 27 ajustes do QMP combo com o limite Gen1 em `usb_2`.
O patch sozinho ainda apresentou resets em Gen2; desabilitar LPM para o
enclosure também não resolveu. O quirk temporário foi retirado.

| Porta | Validação de leitura, sem montar ou gravar |
|---|---|
| Direita / a000000 | 5000M nas duas orientações, 16 GiB por orientação a 296/288 MB/s, quatro hashes de amostras de 256 MiB iguais; nenhum reset ou erro. Após outro boot com instalação permanente, nova conexão normal e 1 GiB a 297 MB/s, mais dois hashes iguais |
| Esquerda junto à dobradiça / a600000 | 10000M nas duas orientações; 32 GiB na invertida e 1 GiB a 600 MB/s na normal; hashes iguais e nenhum reset/erro. A leitura de 32 GiB não registrou taxa exata |
| Esquerda dianteira / a800000 | 10000M nas duas orientações; 1 GiB a 571/548 MB/s, hashes iguais e nenhum reset/erro |
| USB2 na direita | Pendrive via adaptador a 480M; 256 MiB a 32,5 MB/s, dois hashes de 16 MiB iguais aos de 16/11; sem erro de leitura |

**Promovido e comprovado no boot normal:** `current` e `try` usam o DTB
`gwnx2d1-usb3` com direita Gen1, SHA256
`0a5f45a995b39af9c27b4ce05438abdb3119cd740cbb44ec4ac4d21ef0331551`.
`good` permanece `gwnb1` USB2, com manifesto intacto. `saved_entry=current`,
sem tentativa pendente. Backup completo do `current` USB2 anterior em
`/root/usb3-phy-20261117/current-before`; backup do `try` anterior no mesmo diretório.

O módulo calibrado está em `/usr/lib/modules/7.4.0-rc1-yoga-kalambo+/updates/`,
SHA256 `7b319dd1bf03d8739d69d60e82874ac8b602956ed927d2801f3fa63cff8d269c`,
build-id `e52a2da3c5cde89b5bee1dc9621f0b7d52a0b09c`, conferido em sysfs.
O original permanece em `kernel/` e no initramfs. As blacklists evitam a
carga antecipada; `yoga-usb3.service` carrega pelo nome após as guardas,
seguido de UCSI. O drop-in experimental foi retirado. O `try` com os
argumentos permanentes e depois o `current` passaram, sem carga manual.

Boot normal em 23,491 s; vídeo, USB2/3, SoCCP, EC, RTC e GDM ativos/sucesso,
eDP conectado e bateria presente. Wi-Fi/NVMe preservados; sem espera por
associação à rede. Os ~10 s extras frente à base USB2 antecedem a unidade
USB3, na espera de vídeo/GPU/SMMU já observada em 16/11. Só `firewalld`
permanece em falha por falta de `nf_tables` no kernel. `udisks2` voltou ao
estado habilitado no boot normal; os discos estavam desconectados.

Fontes: DTS `dts/kalambo-lenovo-yoga-slim7x-gwnx2d1-usb3{,p0}.dts`, unidade e
regra em `install/usb/`, patch em `patches/phy-qcom-qmp-combo-glymur-usb3-settings.patch`.
Receita de build/instalação e rollback em `install/usb/README.md`.
Evidências privadas: `D17 = P/local/physical-2026-11-17/usb3-right/`, incluindo
revisões independentes, leituras, `gen1-all-ports-journal-full.txt`,
`integration-try-boot.txt`, `integration-right-read.txt` e `current-final-boot.txt`.

Limites: Gen2 na direita continua reprovado; a causa completa permanece
aberta. Não foram alteradas tensões dos reguladores, retimers ou SoCCP. USB4, DP alt-mode,
suspensão e escrita em disco externo não foram testados. USB2 nas esquerdas
não foi repetido nesta rodada; a base anterior já havia passado. Os hashes
cobrem amostras, não os 16/32 GiB completos. Não houve nova confirmação
visual humana depois da promoção, somente estado DRM/serviços. Os avisos
de device-link e aux-bridges DP adiados continuam presentes.


### Histórico — pausa após os testes USB3 em 16/11, 19:57 UTC

**Decisão final do usuário: manter a porta direita em USB2 por enquanto e continuar em 17/11.** As duas portas da esquerda passaram em USB3; a direita enumerou, mas falhou em leitura. Nenhuma configuração USB3 foi promovida ao boot normal.

A [especificação oficial Lenovo](https://psref.lenovo.com/Product/Yoga_Slim_7_14Q8Y11?tab=spec) confirma **três portas USB4 de 40 Gbit/s**, inclusive neste modelo Plus. Os resultados abaixo descrevem o suporte Linux experimental ao caminho USB3; não são limites físicos das portas. USB4/DP alt-mode não foram ativados.

| Porta / controlador | Resultado físico, sem gravar |
|---|---|
| Esquerda junto à dobradiça / usb_0, a600000 | Variante de uma porta: folha JMicron 152d:0583 a 10000M nas duas orientações; 1 GiB lido a 615/587 MB/s. Quatro hashes de 256 MiB iguais. Pendrive via adaptador na mesma porta: 480M, 256 MiB a 33,5 MB/s, dois hashes de 16 MiB iguais |
| Esquerda dianteira / usb_1, a800000 | Boot automático da variante de três portas: 10000M normal e invertido; 1 GiB a 548/590 MB/s, hashes de 256 MiB iguais ao teste de usb_0 |
| Direita / usb_2, a000000 | 10000M nas duas orientações, porém resets e erros de leitura já durante o scan do udev. Ensaio limitado a 5000M também falhou em leitura na orientação invertida. Reduzir a geração não resolveu; não foi feito benchmark nesse caminho com erro |

Os discos externos não foram montados nem receberam escrita de dados: `udisks2` ficou mascarado só no `try`, e os discos dos testes bem-sucedidos foram identificados e colocados em RO após cada conexão. Os erros da direita ocorreram nas leituras de identificação do udev, antes de qualquer `dd` nosso. Nas portas que passaram, `Synchronize Cache(10) failed` apareceu ao remover fisicamente o cabo, após concluir as leituras. O fallback USB2 comprovado foi do pendrive, não do próprio enclosure M.2.

**Boot seguro para a pausa:** `current` permanece `gwnx2d1` (a48b6c543bb0b40be7b4590a4cec36675713be29dffb85b9a34449f943fb4875), `good` permanece `gwnb1`, e `try` foi restaurado como cópia do `current`, com seus argumentos USB2 originais. `saved_entry=current`, sem `next_entry`; os manifestos de `current/good` foram conferidos intactos. O próximo boot normal é USB2 nas três portas. No instante da pausa ainda estava em execução o último boot experimental, com M.2 retirado, eDP conectado e SoCCP anexado; restaurar arquivos do slot não troca o DT em execução. Não foram iniciados novos testes após o pedido de pausa.

A unidade candidata `yoga-usb3.service` e a regra udev foram instaladas no aparelho e permanecem preparadas apenas para experimentos: sem `yoga.usb3=1` nos slots restaurados, a unidade USB3 não executa. As fontes experimentais de DTS/unidade/regra continuam locais e **não são publicadas nesta passagem documental**. Backups: `/root/usb3-auto-all/current-before`, `try-before`, `try-gen1p2-paused` e regra anterior; primeira tentativa também em `/root/usb3-m2-p0/try-before`. O `try` final seguro está registrado em `D/usb3-m2/pause-safe-final.txt`.

**O que foi preparado e revisado separadamente:** variante `gwnx2d1-usb3p0` (hash 3c2375984e9f6e4ddc09746ba6903dd7429332ba3c94475861bd49fac51a0b6b), variante automática das três portas (2de7fd0e8edceb2ce576358aad9d48002647f6d8eb97f71aa1655dfbc96788c7) e ensaio Gen1 só na direita (0a5f45a995b39af9c27b4ce05438abdb3119cd740cbb44ec4ac4d21ef0331551), em `OUT/` e nas cópias de `D/usb3-m2/`. Comparações estruturais, argumentos GRUB, unidade e regra udev passaram; 60 casos das guardas/espera passaram. O schema completo não estava disponível. Isso não substitui os resultados físicos, que reprovaram a direita.

A automação carrega combo QMP e depois UCSI, após USB2, SoCCP, eDP e PCIe Wi-Fi/NVMe ativos, verificando uso positivo de l3f0/l4h0/l2f0/l1f1/l2f1/l4f1. Na variante de três portas, `regulator-always-on` diretamente no RPMh `vreg_l3f0` mantém um voto real, sem mudar os 912 mV existentes; o fixed `HOLD_L3F0` sozinho não protege. Supplies do combo0 são l3f0/l4h0/**l2f0 (refgen)**; combo1 usa l1h0/l4h0/l2f0; combo2 usa l4c1/l4f1/l4f1. A unidade terminou active/success/0 no boot automático e todos os hosts subiram, sem carga manual nem espera por associação Wi-Fi.

O boot automático mediu 23,507 s, contra 13,196 s da base anterior. Os ~10 s adicionais antecedem o serviço USB3: o vídeo esperou probes GPU/SMMU, e o serviço USB3 completou em ~0,1 s. Não alterar dependências de vídeo para compensar isso nesta pausa. `NetworkManager-wait-online` continua desabilitado; a rede conecta em paralelo.

DSDT identifica três retimers PS8830; permaneceram sob controle do firmware. Não foram alterados GPIOs, tensões, retimers ou SoCCP; `pmic_glink_altmode` não foi carregado. Permaneceram avisos de device-link (0x180) e aux-bridges DP adiados, sem perda de vídeo, rede, NVMe ou bateria. A causa da falha da direita continua aberta.

Há uma [série proposta de atualização dos ajustes USB3 Glymur](https://lore.kernel.org/linux-phy/20261102-topic-usb3_sequence-v1-1-5b144f5e6865@oss.qualcomm.com/), de Konrad Dybcio/Qualcomm, com 27 valores de tabelas PHY. O patch foi baixado em `D/usb3-m2/upstream-konrad-glymur-usb3-settings.patch` e passou em `git apply --check`; **não foi aplicado, compilado nem testado**. Não há confirmação de merge nesta sessão; não tratar como cura comprovada. Afeta os três combos e exigiria revalidar também a esquerda. O segundo patch da série é SC8280XP e fica fora deste porte.

**Retomada em 17/11:** preparar a variante com USB3 automático somente nas duas portas da esquerda e direita preservada em USB2; revisar, testar no `try` e só depois promover. Preservar a base e não reutilizar o ensaio de 5 Gbit/s como solução. A investigação do PHY/retimer da direita fica para depois, conforme a decisão do usuário.

Evidências privadas em `D/usb3-m2/`: `baseline-readonly.txt`, `orientation-normal-read.txt`, `orientation-reverse-read.txt`, `usb2-fallback-read.txt`, `all-auto-try-boot-full.txt`, `all-auto-port1-{normal,reverse}-read.txt`, `all-auto-port2-{normal,reverse,gen1}-failure.txt`, laudos estruturais e `pause-safe-final.txt`.

### Preparação anterior — USB3 SuperSpeed

**Prioridade do usuário após limpar o contexto: USB3**, antes de som, GPU e R4. O suporte USB2 permanente foi publicado na `main` em `f8a334f`; esta passagem só atualiza documentação, sem iniciar teste USB3. Seguir o [processo atual em WORKFLOW.md](../WORKFLOW.md#atual--usb3-permanente); o restante daquele documento continua como histórico de 13/11.

A linha de base somente de leitura foi capturada em 16/11 às 19:21 UTC em `D/handoff-usb3/baseline-readonly.txt`: `gwnx2d1`, vídeo real, USB ativo, SoCCP anexado, `NetworkManager-wait-online` desabilitado/inativo, só `7760000.pinctrl` adiado, hashes/argumentos dos slots preservados e `next_entry` vazio. `lsusb -t` mostrou seis root hubs a `480M`/`10000M`, **sem periféricos externos**: isso não comprova link USB3. O último boot normal mediu 13,196 s pelo systemd.

**Limitação atual confirmada no FDT em execução:** os três hosts estão com `maximum-speed = "high-speed"`, só `phy-names = "usb2-phy"` e `qcom,select-utmi-as-pipe-clk`. Isso vem de `dts/fragments/yoga-usb.dtsi` e `yoga-usb-typec.dtsi`. Os três QMP combos continuam `disabled`; remover apenas `maximum-speed` não habilita SuperSpeed.

| Combo no SoC | Endereço | Supplies herdados de `glymur-cob.dtsi`, a auditar nesta placa |
|---|---|---|
| `usb_0_qmpphy` | `0x00fd5000` | l3f0 / l4h0 |
| `usb_1_qmpphy` | `0x00fde000` | l1h0 / l4h0 |
| `usb_2_qmpphy` | `0x088e1000` | l4c1 / l4f1 |

Todos usam `qcom,glymur-qmp-usb3-dp-phy` em `glymur.dtsi`. O driver correto é `drivers/phy/qualcomm/phy-qcom-qmp-combo.c`; `CONFIG_PHY_QCOM_QMP_COMBO=m` e o módulo `phy-qcom-qmp-combo.ko` já estão presentes no kernel em uso. `CONFIG_PHY_QCOM_QMP_USB=m` também existe, mas o driver standalone/"uni" não deve ser confundido com esse combo. A referência `glymur-lenovo-yoga-slim7x.dts` do Elite liga combos e endpoints `pmic_glink_ss`; isso é fonte de comparação, sem validar a fiação do Plus.

Antes de uma variante DTB para **uma porta** no `try`, auditar driver/bindings, supplies compartilhados, clocks/PIPE, os dois PHYs, orientação, mux, retimer e DSDT desta placa. Preservar USB2, eDP, Wi-Fi, NVMe, SoCCP e slots `current`/`good`; usar uma tentativa e revisão separada. Aprovação exige um dispositivo externo folha a `5000M` ou `10000M` nas duas orientações, fallback USB2 e leitura sem gravar, com logs. Não carregar `pmic_glink_altmode` nem tocar no SoCCP; UCSI só registrou portas, carga e papéis não foram comprovados, e sua necessidade para USB3 segue em investigação. Nenhum PHY foi carregado, DTB alterado ou reboot feito nesta passagem documental.

### Como acessar e operar

- Notebook: `root@<ip-do-notebook>` (IP fixado no roteador), chave `~/.ssh/id_ed25519`, hostname `<hostname>`, usuário `<usuario>` (autologin no GDM, sem senha definida). Usar `ssh ... < /dev/null` com `ConnectTimeout`; `pkill -f` com o nome de algo que está na própria linha de comando mata a sessão SSH.
- O usuário autorizou reiniciar sem avisar. Travamento duro exige ele no botão de energia (segurar ~10 s).
- Fedora 45 aarch64 no SSD interno (Windows apagado com autorização). Raiz btrfs em `nvme0n1p4`, `/boot` ext4 em `p2`, ESP em `p1`. Kernel em uso: `7.4.0-rc1-yoga-kalambo+` (qcom for-next 6a876df46), sem nf_tables (firewalld falha; única unidade em falha), sem zram, sem firmware `.xz`.
- Boot por slots em `/boot/yoga/{current,good,try}` (vmlinuz, board.dtb, initramfs.img, args.cfg), menu em `/boot/efi/EFI/BOOT/grub.cfg`. `yoga-boot-once try` arma UMA tentativa; qualquer reboot volta ao `current`. O `args.cfg` do slot só ACRESCENTA à cmdline base (que bloqueia `qcom_q6v5_pas,msm,dispcc_glymur,gpucc_glymur,camcc_glymur,videocc_glymur,evacc_glymur,av1ecc_glymur` e usa `rd.driver.pre=simpledrm`); blacklist só impede carga por alias, `modprobe` pelo nome carrega.
- Slots agora: `current` e `try` = `gwnx2d1-usb3` (0a5f45a9…), esquerda Gen2/direita Gen1; `good` = `gwnb1` USB2 intacto. `current` usa `yoga.video=1 yoga.usb=1 yoga.usb3=1`, sem failreboot, phytest ou máscara udisks. Backup completo da base USB2 anterior em `/root/usb3-phy-20261117/current-before`; ver a seção atual acima.
- Build de módulo fora da árvore: `podman exec yoga-iso-build bash -c 'make -C /work/kernel O=/work/kernel-out-edp M=/work/<dir> ARCH=arm64 LLVM=1 -j4 modules'` (`B` montado em `/work`). Build de DTB: `cpp` + `dtc` de `B/kernel-out/scripts/dtc` (receita na seção "DTS e DTBs").
- Regras do usuário: usar a ferramenta Workflow para edição de código/testes (quem edita não verifica); nesta sessão, com Workflow indisponível, o usuário autorizou agentes separados para edição e revisão; Wi-Fi deve conectar em paralelo, sem espera por link online no boot; respostas em português direto; não mexer nos M.2 do PC; pendrive de recuperação serial <serial-do-pendrive> (menu R8, entrada `N1`, pelo F12); nunca imprimir a senha do Wi-Fi (`local/live-updates/` a contém em texto puro: não publicar).

### Funciona no boot normal (slot `current`), sem intervenção

| Item | Como |
|---|---|
| Vídeo real 1920x1200 a 60 Hz + brilho | `yoga-video.service` → `/usr/local/sbin/yoga-video-up` (ligado por `yoga.video=1`): carrega pelo nome `dispcc_glymur`, `phy_qcom_edp` (corrigido, em `/usr/lib/modules/<ver>/updates/`), painel, `msm separate_gpu_kms=1`, e faz um ciclo blank/unblank antes do GDM. `phy_qcom_edp` fica na blacklist do slot porque o initramfs ainda tem o módulo antigo. Brilho `dp_aux_backlight` (0–2047) funciona pelo GNOME (confirmado pelo usuário) |
| GNOME | sobre msm-kms, render por software (llvmpipe) |
| Teclado, touchpad, tela de toque | i2c-hid (toque Goodix 27C6:0183) |
| Wi-Fi (WCN7850/ath12k), SSH | `<rede Wi-Fi>` salvo; ordem de carga pwrctrl antes do PHY PCIe |
| Bluetooth | `hci0`, firmware `qca/hmtbtfw20.tlv` + `hmtnv20.b112` descomprimidos |
| Bateria | pmic-glink + `yoga-soccp.service` (anexa ao SoCCP iniciado pelo UEFI; nunca reiniciar/parar o SoCCP; recovery desabilitado) |
| cpufreq | SCMI, 355 MHz–4,03 GHz, schedutil |
| EC com IRQ | Driver embutido dá probe no nó DT em I²C 0x70, TLMM 66 com pull-up, sem `initcall_blacklist`: 4 temperaturas, RPM, `platform::kbd_backlight` (0–2) e teclas de função. `yoga-ec.service` permanece habilitado para os slots antigos e não recria o dispositivo que já existe; escapes `$$` corrigidos na unidade |
| USB2/USB3 host | Direita Gen1, esquerdas Gen2, com combo calibrado em `updates` e `yoga-usb3.service`; três controladores (a600000, a800000, a000000), seis root hubs; `90-yoga-usb.rules` pede `yoga-usb.service` ao surgir a interface do driver PCIe, sem exigir associação a uma rede. PHYs eUSB2 ficam na blacklist por alias e são carregados pelo nome após as guardas |
| RTC plano B | `yoga-rtc.service`, condicionado ao alias DT `rtc1`, aplica o offset de `/var/lib/yoga-rtc/offset`; só `rtc1` registrado |
| Tampa, chave da câmera e térmica | `gpio-keys` para TLMM 92/99; 24 zonas de CPU com trip passivo de 105 °C e cdev de cpufreq. Suspensão mascarada; tampa ignorada pelo logind |
| Autologin, tela apaga em 60 s sem bloqueio, papel de parede, Claude Code instalado | — |

### Integração permanente gwnx2d1 (16/11, retomada)

O `gwnx2d1` passou no `try` e depois em boot normal pelo `current`, sem trocar o kernel ou firmware. `yoga-video`, `yoga-usb`, `yoga-rtc`, `yoga-ec` e GDM terminaram ativos, com resultado de sucesso. eDP conectado, SoCCP anexado e bateria presente (90% no registro da promoção inicial); três xHCI e seis root hubs; apenas `firewalld` em falha e `7760000.pinctrl` em `devices_deferred`. O usuário confirmou imagem normal no primeiro `try`; após a promoção foram conferidos serviços e DRM, sem nova confirmação visual. A enumeração física nas três portas já havia sido provada no `gwnx2`, sem repetir inserções nesta integração.

**USB sem associação à rede:** `install/usb/90-yoga-usb.rules`, instalada em `/etc/udev/rules.d/`, reage à criação e renomeação (`add|move`) da interface de rede cujo ancestral usa `ath12k_wifi7_pci`. A regra usa `TAG+="systemd"` e `SYSTEMD_WANTS=yoga-usb.service`, sem depender do nome antes ou depois da renomeação da interface. O dispatcher anterior do NetworkManager foi removido. A unidade respeita apenas `After=yoga-video.service`, sem dependência do NetworkManager nem espera online. Antes de carregar repetidor e PHY eUSB2, exige `DRIVER=ath12k_wifi7_pci` no PCIe `0004:01:00.0`, `power/runtime_status=active` e uso maior que zero dos trilhos l1f1/l2f1/l4f1. A política `power/control=on` já existente não foi alterada. Placa completamente desligada ou suspensa em runtime não foi testada e fica bloqueada pelas guardas. `NetworkManager-wait-online.service` permanece desabilitado: a conexão de rede continua em paralelo.

O teste offline comprovou a carga com NetworkManager desconectado (estado 30), `operstate=down`, PCIe ativo e PHYs inicialmente ausentes. Após iniciar a unidade, permaneceram desconectados e foram registrados três xHCI/seis root hubs, eDP conectado, SoCCP anexado, bateria em 88% e raiz no NVMe. O log de encerramento confirmou que não houve reconexão automática durante o teste. O boot automático pela regra `add|move` passou no slot `try`: a unidade terminou ativa/sucesso/0, com `SYSTEMD_WANTS` presente no banco udev. Os três xHCI/seis root hubs subiram entre 13,125 e 13,187 s, antes de a associação Wi-Fi ocorrer em 20,858 s. O systemd mediu 13,093 s totais (185 ms de kernel, 1,999 s de initrd, 10,908 s de userspace). eDP conectado, SoCCP anexado, bateria em 87% e apenas o firewall em falha. Nenhum DTB, argumento ou kernel foi alterado; os manifestos dos três slots permaneceram intactos. O boot normal pelo `current` também passou: USB, vídeo, RTC, EC e GDM ativos, `SYSTEMD_WANTS` presente e os três xHCI/seis root hubs registrados entre 13,205 e 13,266 s, antes da associação Wi-Fi em 20,873 s. PCIe ativo, eDP conectado, SoCCP anexado e bateria em 87%; só `firewalld` em falha. `NetworkManager-wait-online` permaneceu desabilitado/inativo, sem ter iniciado. O systemd mediu 13,196 s totais (181 ms de kernel, 2,036 s de initrd, 10,977 s de userspace). Os manifestos de DTBs e argumentos dos slots `current`, `good` e `try` seguiram intactos. Esta rodada conferiu guardas offline, controladores e boot; não repetiu confirmação visual nem inserção de pendrive em cada porta.

O boot normal anterior, ainda com dispatcher, mediu 13,154 s pelo systemd (184 ms de kernel, 2,019 s de initrd, 10,950 s de userspace). No `try` com dispatcher foram 13,190 s, contra 21,409 s na variante com espera online, removida a pedido do usuário. Tampa segue ignorada e suspensão mascarada; a tecla de modo avião conserva o comportamento rfkill e pode derrubar o SSH.

Evidências privadas: `D/usb-hardware-active/offline-results.txt` para o teste sem associação e `try-udev-v2-results.txt` e `current-udev-final-results.txt` para o gatilho automático antes da conexão; `D/resume-gwnx2d1/current-final-results.txt` e `try-dispatcher-results.txt` para a integração anterior com dispatcher. A revisão separada cobriu a unidade, 21 casos das guardas e o dispatcher; os boots reais comprovaram sua integração. O próximo trabalho agora é USB3 SuperSpeed; som permanente fica para depois.

### Resultados originais do gwnx2 (16/11 à noite)

EC, USB, RTC, tampa, chave e térmica abaixo foram integrados ao `gwnx2d1`; som e UCSI ainda dependem dos testes manuais descritos aqui.

Logs em `D/gwnx2/` e `D/gwnx2-live-dmesg.txt`. Fragmentos em `P/dts/fragments/`; DTB `OUT/kalambo-gwnx2.dtb` (sem vídeo) e `OUT/kalambo-gwnx2d1.dtb` (a48b6c54…, gwnx2 + vídeo; validado no `try` e promovido ao `current`). Roteiro e revisão final: `D/gwnx2/gwnx2-runbook.txt` e `D/gwnx2/gwnx2-final-review.txt`; projetos de cada frente no journal do workflow `wf_b1a3bd27-044` em `<sessao-claude>/f247ff19-fc71-41d0-8a7b-335b801e041d/subagents/workflows/wf_b1a3bd27-044/journal.jsonl`.

- **Tampa:** gpio-keys SW_LID no TLMM 92; logind registra "Lid closed/opened". Suspensão segue mascarada.
- **Chave de privacidade da câmera:** TLMM 99 com pull-up, IRQ funciona.
- **EC com IRQ (TLMM 66, borda de descida, pull-up):** módulo de teste `P/install/ec-rtc/extmod-ec/yoga-ec-test.ko`; eventos 0x15 (tampa), 0x29 (chave da câmera), 0x18 (mudo do mic), 0x19 (modo avião → rfkill, **derruba o Wi-Fi/SSH**; a mesma tecla religa), 0x0f (Fn-Lock), 0x16 (Fn+Espaço), e 0x54 periódico a cada 6 s (não identificado). Precisa de `initcall_blacklist=slim7x11_ec_driver_init` enquanto usar o módulo de teste; no uso final o driver embutido dá probe pelo DT.
- **RTC plano B:** `rtc_pm8xxx` como `rtc1` (alias no DT) não desloca o relógio; `P/install/ec-rtc/rtc-fallback/yoga-rtc save` gravou o offset em `/var/lib/yoga-rtc/offset`. O serviço instalado exige o alias `rtc1`; não carregar `rtc_pm8xxx` manualmente em DTB sem esse alias (viraria rtc0 → 1970).
- **Térmica:** 24 zonas de CPU com trip passivo 105 °C + cdev de cpufreq; carga total 3 min a 4,03 GHz = 61 °C máx, ventoinha 2700→5400 RPM sozinha.
- **USB:** os três xHCI (a600000, a800000, a000000 = porta da direita) enumeram pendrive em USB2. Guarda: só carregar os PHYs eUSB2 com o Wi-Fi de pé (trilhos l1f1/l2f1/l4f1 compartilhados com o eDP; os `HOLD_*` não seguram nada neste kernel).
- **Som:** ADSP (firmware da coleta Windows em `/var/lib/yoga-fw`, fora do caminho de busca) → pd-mapper/GPR → macros LPASS → 4 amplificadores WSA884x "Attached" → placa `GLYMUR-LENOVO-Yoga-Slim7x` → **melodia audível e limpa** (usuário confirmou). Script `P/install/audio/yoga-audio.sh` (etapas adsp, svc, macros, amps, card). Armadilhas: volumes sobem no MÁXIMO por padrão (PA 6, Digital 81); controles da wsa_macro dão `-EBUSY` (registrador 0x480) com o bloco em runtime-suspend → `echo on > .../6c90000.codec/power/control` e `.../6cb0000.codec/power/control` antes de ajustar, e ajustar por `numid` (o `amixer cset name=` reporta "Cannot find the given element"); script que funcionou: `D/gwnx2/mix.sh` (DV 66, PA 6). Topologia e UCM emprestados do CRD (já instalados em `/usr/lib/firmware/qcom/glymur/` e `/usr/share/alsa/ucm2/conf.d/glymur/`). Microfones (pinos DMIC) e fone não testados. `snd_q6apm` só carrega com `modprobe --ignore-install snd-pcm` neste kernel (falta `snd-seq`).
- **UCSI/Type-C:** `modprobe ucsi_glink` registra port0–2 sem derrubar o SoCCP nem a bateria. Teste de carregador por porta e de role-switch ficou POR FAZER (usuário não chegou a plugar). Não carregar `pmic_glink_altmode` nem plugar dock/monitor.

### Pronto no PC, não testado no hardware

- **Kernel R4** (`B/kernel-r4`, `B/kernel-out-r4/dist`, release `7.4.0-rc3-yoga-kalambo-r4+`; scripts em `P/install/kernel-r4/`): for-next + v7.4-rc3, nf_tables, zram, firmware comprimido, snd-seq, Bluetooth LE, CAMSS/sensores =m, depuração. **Tem só a correção de PLL do PHY eDP; falta aplicar `OUT/phy-qcom-edp-glymur-pll-v2.patch` (PLL + divisor) e recompilar antes de usar com vídeo.** Nunca deu boot. R2/R3 (`kernel-out-r2`, `kernel-out-r3`) são anteriores.
- **Mesa para a Adreno X2-45** (`P/install/mesa-x2-45/`, build em `B/mesa-build/`): o Mesa 26.2.3 do Fedora rejeita o chip (`unsupported GPU id 0x0 / chip id 0xc144060020`); pacote recompilado para `/opt/mesa-x2-45` com wrapper de ambiente. O kernel já sobe a GPU (gpucc, gxclkctl, SMMU 3da0000, firmware `gen80100_*` descomprimido, GMU v5.2.38, `renderD128`). Recomendações do revisor: limitar `devfreq` da GPU a um OPP baixo antes do primeiro draw; `timeout` em cada teste. Hoje o `yoga-video-up` grava `driver_override=none` na GPU: o teste de GPU precisa conviver com isso.
- **Câmeras (registro histórico de 16/11, superado):** naquela etapa só a chave de privacidade funcionava. Em 17/11, PM8010, RGB, IR e iluminador foram validados e as câmeras promovidas ao boot normal; ver o topo deste documento.
- **Suspensão s2idle:** só avaliação (`P/install/power/`); revisores recomendam não testar no kernel em uso.

### Causas-raiz encontradas (não reinvestigar)

1. Boot ACPI reinicia: SMMUv2 genérico sem quirk Qualcomm (`initcall_blacklist=arm_smmu_init`); ACPI não serve para entrada. Caminho adotado: Device Tree.
2. Boot DT travava: TLMM sem `gpio-reserved-ranges = <4 4>, <10 2>, <27 1>, <44 4>, <65 1>, <90 2>, <139 1>`.
3. Tela apagava ao subir o Wi-Fi: ciclo liga/desliga do PCIe por EPROBE_DEFER; corrigido com ordem de carga (pwrctrl/pwrseq antes do PHY).
4. Tela preta com msm: PHY eDP v8 (Glymur) do kernel com tabela de PLL errada (link não fechava) E `DP_PHY_VCO_DIV` errado em 5,4 G (código 2 → 30 Hz; o certo é 0 → 60 Hz; código 1 → 40 Hz). Fonte corrigida `B/extmod-edp3/`, patch `OUT/phy-qcom-edp-glymur-pll-v2.patch`. Taxas 1,62/2,7/8,1 G não comprovadas. Vale também para o kernel upstream.
5. Em `multi-user.target` o `kmscon` vira DRM master e bloqueia `fb0/blank` e `/dev/fb0`.

### Próximos passos, em ordem sugerida

1. **USB3 concluído em 17/11:** direita Gen1 e esquerdas Gen2, promovido e validado no boot normal. Manter o limite Gen1; Gen2 na direita/USB4/DP alt-mode continuam pendentes.
2. Som permanente: serviço que sobe a cadeia na ordem do `yoga-audio.sh`, mantém as macros com `power/control=on`, baixa os volumes antes de liberar a placa ao PipeWire/WirePlumber; depois microfones e fone.
3. GPU: testar o Mesa de `/opt/mesa-x2-45` (destrava Niri).
4. Kernel R4 com o patch v2 do PHY (traz firewall, zram, snd-seq) no slot `try`.
5. UCSI: terminar o teste de carregador nas três portas e troca de papel. Sua necessidade para USB3 ainda deve ser investigada, sem pressupor que seja obrigatório; não carregar `pmic_glink_altmode` nesta rodada.
6. Câmeras (após decisão sobre os GPIOs), suspensão, evento 0x54 do EC.
7. `P/README.md`, `docs/ESTADO-ATUAL.md`, `RETOMADA.md` e o topo de `WORKFLOW.md` refletem 17/11. O restante de `WORKFLOW.md`, `DRIVERS.md` e `iso/RESULTADO-*.md` preserva o histórico de 13/11.

## Detalhe cronológico da sessão de 16/11 (onde conflitar, vale "COMECE AQUI")

- **FEDORA INSTALADO NO SSD INTERNO em 16/11/2026, com autorização explícita do usuário ("pode apagar"). O Windows e a recuperação Lenovo foram apagados.** O Yoga liga sozinho no Fedora, sem F12 e sem pendrive: boot em 4,9 s (kernel 0,17 s + initrd 1,9 s + userspace 2,8 s), raiz btrfs em `nvme0n1p4` (subvol `root`), Wi-Fi `<rede Wi-Fi>` e `sshd` automáticos, GDM/GNOME, usuário `<usuario>` ("<nome>", sem senha, wheel), hostname `<hostname>`. `systemctl reboot` funciona e volta sozinho. Claude Code instalado para `<usuario>` (persistente).
- Layout do SSD: p1 ESP 1 GiB (`YOGA-ESP`, PARTUUID da ESP antiga preservado), p2 `/boot` ext4 4 GiB, p3 swap 8 GiB, p4 btrfs 463,9 GiB (subvols `root`, `home`, `var_log`, `snapshots`; snapshot `root-recovery`). Boot: shim+GRUB em `EFI/BOOT` (cópias em `EFI/Microsoft/Boot` e `EFI/fedora`), slots em `/boot/yoga/{current,good,try}` com `vmlinuz`, `board.dtb` (= `gwn1`), `initramfs.img` e `args.cfg`; `try` roda uma vez via grubenv e volta para `current`. `good` ainda é cópia de `current`.
- Acesso: `ssh -i ~/.ssh/id_ed25519 root@<ip>` (IP fixado no roteador pelo usuário em 16/11: <ip-do-notebook>). Logs do primeiro boot pelo SSD: `local/physical-2026-11-16/ssd-boot1-dmesg.txt` e `ssd-boot1-journal.txt`; log da instalação: `install-log.txt`; menu instalado: `installed-grub.cfg`.
- **Bateria funciona (16/11):** DTB `gwnb1` (gwn1 + nó `/pmic-glink`) no slot `current`; `yoga-soccp.service` faz `modprobe qcom_q6v5_pas`, que apenas ANEXA ao SoCCP já iniciado pelo UEFI (sem firmware; `attaching to soccp` → `attached`); `qcom_battmgr` expõe `qcom-battmgr-bat` (96 %, Charging, Sunwoda L25D4PH1, 70 Wh) e UPower/GNOME mostram o percentual. Proteções: regra udev `90-yoga-soccp.rules` (`recovery=disabled`, para um watchdog do SoCCP não levar o kernel a desligá-lo), `ucsi_glink` e `pmic_glink_altmode` bloqueados (cmdline do slot e `/etc/modprobe.d/yoga-soccp.conf`), nenhum `soccp.mbn` instalado. O slot `good` continua com o `gwn1`. Risco residual apontado na revisão: uma falha logo após o attach faria o kernel desligar o SoCCP até o próximo boot.
- Ajustes do usuário em 16/11: autologin do GDM para `<usuario>`; tela apaga após 60 s sem uso, sem bloqueio (gsettings; confirmado pelo usuário que apaga e volta); o usuário autorizou reiniciar o notebook sem aviso.
- O mecanismo de slot `try` (uma tentativa via grubenv) foi exercitado e funciona.
- **Rodada de 16/11 à tarde (DTB `gwnx1` = gwnb1 + fragmentos em `dts/fragments/`; agora no slot `current`, com `gwnb1` no `good`).** Testado num boot com carga manual de módulos, logs em `local/physical-2026-11-16/gwnx1/`:
  - **cpufreq funciona:** SCMI com polling (`arm,no-completion-irq`, `arm,max-rx-timeout-ms=200`) + `qcom_cpucp_mbox`; `policy0` com 355 MHz–4,03 GHz, schedutil.
  - **Bluetooth funciona:** `hci_uart`/`btqca` em `uart14`, firmware `qca/hmtbtfw20.tlv` + `hmtnv20.b112` descomprimidos, `hci0` com endereço real; Wi-Fi não é afetado. Confirmado pelo usuário no GNOME.
  - **Tela de toque funciona:** Goodix `27C6:0183` hid-over-i2c em `i2c8` 0x14. Confirmado pelo usuário.
  - **EC funciona em modo "bus":** `i2c9` 0x70 criado por sysfs (`yoga-ec.service`); hwmon com 4 temperaturas e RPM da ventoinha, LED `platform::kbd_backlight` (0–2). Sem hotkeys (o nó com IRQ no TLMM 66 não foi provado). O GNOME apaga a luz do teclado por inatividade.
  - **USB2 host funciona em uma porta:** `a800000.usb` (usb_1) detectou e leu um pendrive numa USB-C da esquerda; `a600000.usb` (usb_0) sobe mas não detectou dispositivo na outra porta testada. VBUS vem do firmware. `ucsi_glink` continua bloqueado.
  - **ADSP sobe:** `qcadsp8480.mbn` da coleta Windows (staging em `/var/lib/yoga-fw`, fora do caminho de firmware) → `running`, canais glink e serviços GPR; `snd_q6apm` não carrega porque falta `snd-seq` neste kernel. Sem placa de som. Módulos de áudio seguem bloqueados no slot `current`.
  - **GPU sobe no kernel:** `gpucc_glymur`, `gxclkctl`, SMMU `3da0000`, `msm separate_gpu_kms=1` → `renderD128`, firmware `gen80100_*` carregado, GMU v5.2.38. **Mesa 26.2.3 não conhece o chip** (`unsupported GPU id 0x0 / chip id 0xc144060020`; `speed-bin 193` sem suporte no kernel). GNOME segue em software.
  - **RTC registra mas dá data de 1970** e desloca o relógio do sistema; `rtc_pm8xxx` fica bloqueado.
  - O slot `current` com `gwnx1` ainda não deu boot automático (só carga manual) no fechamento deste texto.
- **Vídeo real (msm/eDP) FUNCIONA em teste (T2, 16/11):** dois defeitos no PHY eDP v8 do kernel: tabela de PLL errada (link não fechava) e `DP_PHY_VCO_DIV` errado em 5,4 G (código 2 → relógio de pixel pela metade, 30 Hz, tela preta). Com `vco_div=0` deu 60 Hz e imagem (console, barras), com e sem wide bus, 30 bpp; `vco_div=1` deu ~40 Hz. **Brilho por `dp_aux_backlight` (0–2047) funciona**, visto pelo usuário. 0x332/0x333 não foram necessários. Armadilhas: em multi-user o `kmscon` (`kmsconvt@tty1`) é DRM master e impede `fb0/blank` e a pintura por `/dev/fb0`; parar o serviço antes. Teste feito com DTB `gwnd1` (sem pmic-glink) e módulos `extmod-edp2`/`extmod-panel-atna`/`extmod-msm-diag` + `local/dtb-bisect-r5/t2-edp.sh`; logs em `local/physical-2026-11-16/t2/`. **Permanente desde 16/11 à noite:** slot `current` = DTB `gwnxd1` (gwnx1 + vídeo, sha 87d1a723…), `phy-qcom-edp.ko` corrigido em `/usr/lib/modules/<ver>/updates/` (fonte `local/iso-build/extmod-edp3`, patch para a árvore `local/dtb-bisect-r5/phy-qcom-edp-glymur-pll-v2.patch`), `yoga-video.service` + `/usr/local/sbin/yoga-video-up` (ligado por `yoga.video=1` no args.cfg; carrega dispcc, PHY, painel e `msm separate_gpu_kms=1` pelo nome antes do GDM e faz um ciclo blank/unblank), `phy_qcom_edp` na blacklist do slot porque o initramfs ainda tem o módulo antigo. GNOME sobre msm-kms (render por software), 60 Hz, brilho pelo GNOME confirmado pelo usuário. Reserva: slot `good` (gwnb1, simpledrm) e cópia do gwnx1 em `/root/slot-backup`. Instalador: `local/dtb-bisect-r5/kalambo-gwnxd1.install.sh`. Rodada paralela 2 (kernel R4, Mesa X2-45 em `install/mesa-x2-45`, som, USB-C, câmera, EC/RTC, tampa/térmica): fragmentos em `dts/fragments/`, DTB `gwnx2` e `gwnx2d1` (= gwnx2 + vídeo), resultados no journal do workflow `wf_b1a3bd27-044`; ainda não testada no hardware.
- **Kernels compilados e ainda não instalados:** R2 (`local/iso-build/kernel-out-r2`, mesma base, com nf_tables, FW_LOADER_COMPRESS, zram, CPUCP_MBOX=y, RNDIS, pwrseq builtin) e R3 (`kernel-rc3` = for-next + v7.4-rc3 sem conflitos, `kernel-out-r3`, release `7.4.0-rc3-yoga-kalambo-r3+`). Nenhum inclui a correção do PHY eDP nem `snd-seq`.
- O pendrive (menu R8 + `N1`) continua sendo o meio de recuperação, pelo F12.
- **As seções abaixo descrevem o caminho até aqui (boot por pendrive); onde falam em live em RAM ou em "não instalar", valem como histórico.**

- **Fedora 45 live sobe até o GNOME** no Lenovo, em Device Tree, carregado em RAM pelo pendrive. Teclado interno, touchpad e botão de energia funcionam. Entrada do menu: `G3`.
- **Vídeo:** só o framebuffer do firmware (GOP) exposto como `simple-framebuffer` + `simpledrm`, renderização por software. GNOME funciona; **Niri não roda sem GPU** (`Error::DeviceMissing`, não abre `/dev/dri/card0`). Os módulos de vídeo reais (`msm`, `dispcc_glymur`, `gpucc_glymur` etc.) ficam bloqueados por `modprobe.blacklist`, porque sem painel no DT eles apagam a tela.
- **Wi-Fi interno e SSH sobem sozinhos** (entrada `W6`, comprovado num boot do zero em 16/11): WCN7850 em pcie4, `PCIe Gen.3 x2 link up` aos 5,5 s, `ath12k` com firmware `WLAN.HMT.1.1.c7-00108`, `board_id 0xff`, interface `wlP4p1s0`, conexão automática em `<rede Wi-Fi>` aos ~21 s, `sshd` ativo, login root do PC com a chave `id_ed25519`. O IP muda entre boots (<ip-do-notebook>, depois .232). `firewalld.service` e `geoclue.service` falham no live; **não há firewall ativo**.
- **SSD interno funciona** (entrada `N1`, DTB `gwn1`, 16/11): `PCIe Gen.4 x4 link up` em pcie5, Samsung MZAMX512HDLV serial preservado somente nos logs privados, SMART sem alertas, 3 GiB lidos a 1,3–2,5 GB/s sem erro, tela e Wi-Fi intactos. Nada foi escrito nele. Layout encontrado: ESP 450 MiB, MSR 16 MiB, Windows com BitLocker 474,5 GiB, WinRE 2 GiB. Backup da tabela, do primeiro 1 MiB e da ESP do Windows em `local/physical-2026-11-16/nvme-backup/`.
- Bluetooth e USB ainda não funcionam em Device Tree. Logs completos desse boot: `local/physical-2026-11-16/w6-dmesg.txt` e `w6-journal.txt`.
- **Sensores térmicos do SoC leem valores plausíveis** (35–40 °C em repouso, shell do initrd). Único dispositivo em `devices_deferred` no shell: `7760000.pinctrl` (LPASS).
- Secure Boot desativado desde o primeiro teste. Windows/NVMe não foram alterados; nenhuma instalação Linux foi feita. O único dispositivo gravado é o pendrive, e nele só a ESP de 30 MB.

## Causas encontradas hoje

1. **Reset em ACPI (~0,57 s de kernel):** o driver SMMUv2 genérico (`arm_smmu_init`). A IORT tem `oem_revision` 0x8480 e o quirk Qualcomm em ACPI só casa 0x8180; o caminho genérico apaga os mapeamentos do UEFI. Comprovado por bisseção: `initcall_blacklist=arm_smmu_init` passa, bloquear só o SMMUv3 não. Com o contorno o live sobe em ACPI até multi-user, mas sem teclado nem USB (nenhum driver casa os HIDs ACPI). ACPI serve só como referência.
2. **Travamento em Device Tree (~0,93 s):** probe do pinctrl TLMM sem `gpio-reserved-ranges`. Comprovado por bisseção de DTB (B1–B4, C1–C5). Corrigido com `<4 4>, <10 2>, <27 1>, <44 4>, <65 1>, <90 2>, <139 1>` (união das placas irmãs no kernel; a lista exata deste modelo não é conhecida).
3. **Tela preta ao habilitar o PCIe do Wi-Fi:** o que apaga a tela (kernel vivo) é o ciclo liga/desliga do PCIe: sem `pci-pwrctrl-pwrseq` carregado, `pcie-qcom` liga PHY, clocks e GDSC, recebe `-EPROBE_DEFER` e desliga tudo. Comprovado em 16/11 (entrada `W5`): com `insmod pci-pwrctrl-pwrseq.ko` antes de `modprobe phy-qcom-qmp-pcie` a tela se mantém e o log mostra `PCIe Gen.3 x2 link up` e `0004:01:00.0 [17cb:1107]`. **O que exatamente o desligamento derruba junto com o vídeo não foi identificado**; o contorno é garantir a ordem de carga (`rd.driver.blacklist=phy_qcom_qmp_pcie` no initrd + `softdep` em `/etc/modprobe.d/yoga-wifi.conf` via `yoga-updates.cpio`).

## Pendências conhecidas (levantadas por SSH em 16/11)

- **cpufreq:** SCMI responde ao protocolo base (`Qualcomm:PDP1`) mas dá timeout no protocolo de desempenho 0x13; `scmi-cpufreq` falha com -110. O driver `arm-scmi` é built-in e não aceita bind/unbind; só dá para tentar de novo num boot (suspeita registrada na pesquisa: `CONFIG_QCOM_CPUCP_MBOX=m` em vez de `=y`).
- **Firewall:** o kernel não tem `CONFIG_NF_TABLES`; `firewalld` sai com status 3. Exige rebuild do kernel.
- **Bateria:** resolvida em 16/11 (ver estado atual).
- **Brilho:** na referência Elite o painel não tem nó de backlight próprio (só `edp_bl_en`); o brilho vem do eDP via driver de display real. Com `simpledrm` não há controle de brilho.
- **RTC:** `rtc-pm8xxx` falha no `request_irq` (-EPERM); a hora vem por NTP.
- **Áudio:** ADSP sobe (ver estado atual); falta placa de som no DT e `snd-seq` no kernel.
- **Câmeras (RGB e IR, informado pelo usuário em 16/11; chave física de privacidade ligada por ele):** nenhum `/dev/video*`. Não são USB: usam o ISP Spectra/CAMSS. O DT atual só tem `qcom,glymur-camcc`; a referência Elite não descreve câmera, só `switch-camera-privacy`. A coleta Windows tem os drivers (`qccamfrontsensor8480`, `qccamauxsensor8480` = sensor frontal e auxiliar/IR, `qccamflash8480`, `qccammipicsi8480`, `qccamisp8480`, `qccamplatform8480`, com `*_ext*`), de onde saem sensor, alimentação e sequência de init. Frente não iniciada.
- **Overlay em execução:** `CONFIG_OF_OVERLAY=y`, mas sem interface configfs; aplicar overlay ao vivo exigiria um módulo como `modules/vivobook-cam-fix-2.0` compilado para este kernel. Não feito.

## Próximo passo

1. Com SSH disponível, investigar ao vivo: USB host (para tirar o sistema da RAM), o que o desligamento do PCIe derruba junto com o vídeo, e GPU/painel. O `yoga-updates.cpio` leva: sessão GNOME, `sshd` via preset, `yoga-wifi.service` (remove `/run/modprobe.d/initramfsblacklist.conf` herdado do initrd e carrega pwrctrl antes do PHY), `softdep`, firmware ath12k sem `.xz`, chave SSH do root e o perfil NetworkManager `<rede Wi-Fi>` com a senha (copiada do perfil do PC a pedido do usuário). Claude Code é reinstalado por SSH a cada boot (não está no pacote).
2. USB em modo host (`U2`, `U3`, `G4`) está pronto e revisado, **nunca testado**. Riscos apontados na revisão: primeira escrita em PMIC (repetidor eUSB2 SMB2370, não confirmado pelo DSDT), possível desligamento de trilhos compartilhados em caminho de falha, VBUS depende do firmware. Só cobre as duas portas USB-C da esquerda (pela referência Elite; não verificado no Plus).
3. Tethering USB de celular: `CONFIG_USB_NET_RNDIS_HOST` e `USB_IPHETH` não estão compilados; só adaptador USB-Ethernet ou celular com NCM/ECM.
4. Depois de rede: reconstruir o live com SSH e Claude Code já instalados (pedido do usuário), GPU/painel de verdade, NVMe.

## Fatos de hardware lidos hoje

- efifb: `framebuffer at 0xf9a20000`, 1920x1200x32, `linelength=7680`, `shift=24:16:8:0`; `/proc/iomem`: `f9a20000-fa2e9fff`.
- Teclado `048D:8388` em `i2c@b80000` 0x3a, IRQ TLMM 67 (funciona com borda e com nível). Touchpad ELAN `04F3:3378` em 0x2c, IRQ TLMM 3. Sem supplies no DT (reguladores dummy).
- `gpio94 : out high func0 16mA no pull` deixado pelo firmware (na referência Elite é o enable dos 3,3 V do WCN7850).
- Wi-Fi WCN7850 `17cb:1107` subsystem `17aa:e0e9` em pcie4 (`pcie@1bf0000`); NVMe em pcie5 (não tocado). GPIOs confirmados em DSDT e referência: WLAN_EN 117, BT_EN 116, PERST 146, CLKREQ 147, WAKE 148.
- O kernel não lê firmware `.xz` (`CONFIG_FW_LOADER_COMPRESS` desligado); o firmware ath12k descomprimido vai no `yoga-updates.cpio`.
- A leitura do initrd/live via LoadFile2 acontece depois de "BOOT - entregando controle ao kernel": ≥58 s para o initrd de 209 MB; vários minutos para o live de 3,8 GB.

## Mídia atual (pendrive)

- USB DISK 3.0, serial **<serial-do-pendrive>**. O nome `/dev/sdX` muda entre conexões; localizar sempre pelo serial. ISO R2 intacta em `sda1`; só a ESP (`sda2`, vfat `BOOT`, 30 MB) é alterada.
- Menu **R8** (`iso/grub-yoga.cfg`), 10 entradas: `G3` GNOME + SSH; `W6` GNOME + SSH + Wi-Fi; `N1` idem + SSD interno (driver `nvme` bloqueado, carregar à mão); `G4` GNOME + SSH + USB; `G1` shell rápido; `W5` shell de teste do Wi-Fi; `U2`/`U3` shell de teste de USB; `L1` ACPI de referência; recuperação Fedora. Teste: `python3 iso/test-grub-diagnostic.py` e `grub2-script-check`.
- Menu R8 gravado na ESP em 16/11/2026, relido e conferido. O menu anterior (40 entradas) está em `local/physical-diag-r2/grub-yoga-r7-antes-da-limpeza.cfg`. A ESP ainda guarda DTBs de bisseção que o R8 não usa (`b1`–`b4`, `c1`–`c5`, `e1`, `k1`, `k1b`, `u1`).
- Arquivos que o menu R8 usa na ESP (`EFI/BOOT/`), SHA256:
- `iso/grub-yoga.cfg`: `62ec55f10acb7e3e9a2cd2caa0ee2db76f308571a183087a28c6403a7288912c`
- `local/dtb-bisect-r5/kalambo-g1.dtb`: `e0c6f5ab9929de9ad238043bd7c5e21ca7452d07dfe6c7e8fd9432d87a35410b`
- `local/dtb-bisect-r5/kalambo-gu2.dtb`: `50584e1449e2c826806d4d7428e45a24560c975360a0c41aed891a15a2899e28`
- `local/dtb-bisect-r5/kalambo-gw1a.dtb`: `3d51dd053a80e8610b20018584cf4a261e90fc0d7a101ae961e21aad91bec2a5`
- `local/dtb-bisect-r5/kalambo-u2.dtb`: `a31d4051a3a8fe945ef8cea20715fbedaf3a1a95207c70802e7ee8e72efbbcba`
- `local/dtb-bisect-r5/kalambo-u3.dtb`: `1e280de5ad2c87423d82b4da3e7fc07d5935f6ff6c9409794bfd22f5e654b7cd`
- `local/live-updates/yoga-updates.cpio`: `e3cc7267a9386e1bea2ec4af864a6b39640416fa7c873fb01e6cacb322395402` (gravado na ESP em 16/11; contém a senha do Wi-Fi em texto puro, não publicar)
- `local/wifi-extra/yoga-wifi-extra.cpio`: `1ff0e59dd737ed3fa0317f1aa4691824c4ec785021f551e74d5a4950e038ffb4`
- `yoga-updates.cpio` é aplicado pelo dracut (`20-apply-live-updates.sh`, diretório `/updates`): sessão GNOME para `liveuser`, `sshd` habilitado, `authorized_keys` do root, firmware ath12k WCN7850 sem `.xz`. `yoga-wifi-extra.cpio` só leva `/yoga/pci-pwrctrl-pwrseq.ko` ao initramfs.
- Backups de menus anteriores: `local/physical-diag-r2/usb-grub-before-r3.cfg`, `usb-grub-before-r4.cfg`.

## DTS e DTBs

Fontes em `ports/lenovo-yoga-slim7-14q8y11/dts/`, binários em `local/dtb-bisect-r5/`. Build fora do kbuild: `cpp -E -nostdinc -I <kernel>/arch/arm64/boot/dts/qcom -I <kernel>/scripts/dtc/include-prefixes -I dts -undef -D__DTS__ -x assembler-with-cpp`, depois `local/iso-build/kernel-out/scripts/dtc/dtc -I dts -O dtb -b 0`.

| DTS | Conteúdo | Estado |
|---|---|---|
| `diag` | só `kalambo.dtsi` | trava no TLMM |
| `k1` | diag + `gpio-reserved-ranges` + teclado/touchpad | testado, funciona |
| `g1` | k1 + `simple-framebuffer` | testado, funciona (GNOME) |
| `u1`/`u2`/`u3` | k1 + USB2 host (1 porta / 2 portas / reserva) | revisado, não testado |
| `gu2` | u2 + framebuffer | composição, não testado |
| `gw1a` | g1 + Wi-Fi em pcie4 sem dirigir o GPIO 94 | revisado; apaga a tela ao carregar o PHY |
| `gw1b` | gw1a + GPIO 94 como enable | revisado, não gravado, não testado |
| `gwn1` | gw1a + NVMe em pcie5 (3,3 V declarativo, PERST TLMM 152) | testado; base do sistema instalado (slot `good`) |
| `gwnb1` | gwn1 + `/pmic-glink` (bateria) | testado; slot `good` |
| `gwnu2` | gwn1 + USB2 host em 2 portas + `HOLD_L3F0` | revisado e aprovado, não testado |
| `gwnd1` | gwn1 + vídeo real (mdss/eDP/painel) | testado (T1/T2); imagem com o PHY corrigido |
| `gwnx1` | gwnb1 + fragmentos (toque, EC-bus, Bluetooth, áudio-base, cpufreq/RTC, USB) | testado; base do `gwnxd1` |
| `gwnxd1` | gwnx1 + vídeo real | anterior; preservado em `/root/resume-gwnx2d1/current-before` |
| `gwnx2` | gwnx1 + placa de som, usb_2, chave da câmera, EC com IRQ, RTC rtc1, tampa, térmica | testado num boot (slot `try`) |
| `gwnx2d1` | gwnx2 + vídeo real | **validado no `try` e no boot normal do `current`; EC, RTC e USB automáticos** |

Variantes de bisseção `b1`–`b4`, `c1`–`c5`, `e1`, `k1b` ficam só em `local/dtb-bisect-r5/`.

## Histórico resumido dos testes

1. 13/11: ISO experimental e R2 em ACPI; Linux executava e reiniciava em ~0,57 s; R3-CONS preparada e não testada.
2. 16/11, ACPI: A1 (initrd pequeno) repete o reset; A2/A3 (sem SMMUv2) passam; A4 (sem SMMUv3) falha; L1 chega ao multi-user sem entrada.
3. 16/11, Device Tree: D1/D2 travam em 0,93 s; B1/B2 passam, B3 trava; C1 e C5 passam (TLMM); E1 com GPIOs reservados passa.
4. 16/11, entrada e vídeo: K1/K2 (teclado), K4 (shell interativo), G1 (simpledrm), G2 (GDM; Niri falha, GNOME sobe após troca manual), G3 (GNOME direto via `/updates`).
5. 16/11, Wi-Fi: W1 e W2 apagam a tela; W3 (sem módulo do PHY) chega ao shell; W5 (pwrctrl antes do PHY) mantém a tela e o link PCIe sobe com o WCN7850 enumerado; W6 sobe o GNOME e, com o PHY carregado à mão, o Wi-Fi conecta e o SSH do PC funciona. Claude Code 2.1.325 instalado para `liveuser` nessa sessão (em RAM, não persiste).

## Objetivo confirmado

Portar e instalar Fedora aarch64 no Lenovo Yoga Slim 7 14Q8Y11, mantendo o Windows até o suporte estar comprovado. Desktop pedido: Niri, Noctalia nativo 5.5.0 e os sete perfis de cor Lenovo do painel. Não instalar, particionar ou alterar o NVMe antes de um boot diagnóstico estável com armazenamento, energia e térmica validados.

## Hardware real coletado no Windows

- Lenovo Yoga Slim 7 14Q8Y11, tipo/DMI 83QR.
- Snapdragon X2 Plus X2P-42-100 (`X2P42100`), ARM64, seis núcleos/threads, até 4.032 MHz.
- Variante Linux usada para o SoC: Qualcomm Kalambo. O ID SMEM ainda não foi lido no Linux.
- 16 GB de RAM; BIOS TCCN37WW.
- GPU Adreno X2-45, driver Windows 32.0.152.6.
- Painel LEN88AE / LEN140WUXGA, 1920×1200 a 60 Hz; outro EDID SDC4208 também foi coletado.
- FastConnect 7800 Wi-Fi/Bluetooth.
- SSD Samsung MZAMX512HDLV-00BL2, aproximadamente 512 GB, GPT.
- Windows 11 Home ARM64 build 28000.

## Repositório e isolamento

- Repositório real: `<workspace>/fedora-vivobook-x1407q`.
- Worktree Lenovo: `<workspace>/fedora-vivobook-x1407q/.worktrees/lenovo-yoga-slim7-14q8y11-x2plus`.
- Branch: `port/lenovo-yoga-slim7-14q8y11-x2plus`, base `9b0c28c`.
- Porte: `ports/lenovo-yoga-slim7-14q8y11/` dentro do worktree.
- Nada foi commitado, enviado ou publicado. `README.md` do worktree está modificado e `ports/` continua não rastreado.
- Dados privados e builds ficam em `ports/lenovo-yoga-slim7-14q8y11/local/`, ignorado por Git.
- Não usar patches, DTBs, módulos ou o aparelho ASUS para validar este Lenovo.

## Coleta Windows preservada

Pasta principal:

`ports/lenovo-yoga-slim7-14q8y11/local/windows/2026-11-13/Yoga-14Q8Y11-20261113-090057-d44470f5/`

- 6.433 arquivos, 6.783.459.253 bytes.
- 6.430 hashes do manifesto Windows conferidos; todos os 6.433 arquivos locais também comparados com a origem.
- 25 etapas OK, uma incompleta (`edid-registry` por subchaves protegidas), duas opcionais ausentes.
- 188/188 pacotes PnPUtil exportados; DriverStore com 3.275 arquivos.
- O aviso de registro não invalida drivers, ACPI, EDIDs ou cores. Não é necessário repetir a coleta completa.
- Conteúdo original do antigo USB também foi copiado para o PC antes de ele ser sobrescrito pela ISO.
- Não publicar blobs/firmware/DriverStore do Windows sem revisão de licença.

### ACPI

- 22 arquivos, 20 hashes únicos.
- Inclui DSDT, SSDT, MCFG, FACP, APIC, CSRT, PPTT, GTDT, BERT, DBG2, IORT, SDEV, SPCR, TPM2 e BGRT.
- A API Windows retorna somente a primeira tabela para assinaturas repetidas; a cobertura de SSDTs não é garantida.
- DSDT: 495.651 bytes. A decompilação conjunta registrou duplicidade `\\_SB.SOID`; a auditoria completa ainda não foi feita.
- GENI/I²C observados: QUP0 SE0 em `0x00b80000`, QUP0 SE5 em `0x00b94000`, QUP1 SE0 em `0x00a80000`, QUP1 SE1 em `0x00a84000`.
- Dispositivos ativos: teclado QTEC0001 em I²C 0x3a, touchpad ELAN06FA em 0x2c, touch GXPT7936 em 0x14.
- GPIOs informados pelo Windows podem ser virtuais; não transpor números diretamente para o DTS.

### Perfis de cor

Sete arquivos originais, hashes conferidos:

- `TPLCD_88AE_AdobeRGB.icm`
- `TPLCD_88AE_DCIP3.icm`
- `TPLCD_88AE_Default.icm`
- `TPLCD_88AE_DisplayP3.icm`
- `TPLCD_88AE_Native.icm`
- `TPLCD_88AE_REC709.icm`
- `TPLCD_88AE_sRGB.icm`

As descrições internas são `LEN88AE_*`. Default e Native contêm `vcgt`. Eles estão incluídos no sistema live em `/usr/share/color/icc/lenovo/`, mas ainda não foram aplicados nem validados por uma cadeia ICC completa no Niri.

### Firmware

- Candidatos ADSP/CDSP foram preservados; há uma versão ADSP e duas versões CDSP distintas.
- Na imagem eles ficam apenas como candidatos em `/usr/share/yoga-port/firmware-candidates`; não há mapeamento ativo arbitrário.
- Drivers Windows `.sys` não são drivers Linux e não foram instalados como tal.

## ISO Lenovo oficial inspecionada

- Arquivo: `~/Downloads/ldiag_5.2.1_linux_arm64.iso`.
- Tamanho: 3.024.523.264 bytes.
- SHA256: `053a9a276bdd5c3da9d3023a88c6ffa3b24dddab598e166740bb9a1f337a75b8`, igual ao site Lenovo.
- Ubuntu 26.04, kernel 7.0.0-29-generic, wrapper Stubble e 32 DTBs antigos.
- Não contém DTB Kalambo/Mahua/Yoga 14Q8Y11 nem os perfis LEN88AE.
- Ainda é útil como controle de boot UEFI/Stubble; não foi registrado teste físico dela neste notebook.

## Kernel usado na ISO experimental

- Não é 7.4-rc2.
- `kernelrelease`: `7.4.0-rc1-yoga-kalambo+`.
- Árvore Qualcomm `for-next`, commit `6a876df4686788cd39128b62d7fcbff62f39278f`, datado de 2026-11-12.
- O assunto do commit mescla `arm64-fixes-for-7.4`, `clk-fixes-for-7.4`, `drivers-fixes-for-7.4` e várias filas Qualcomm destinadas a 7.5. Por isso, apesar da string rc1, não equivale a um 7.4-rc1 vanilla.
- O 7.4-rc2 mainline foi publicado em 2026-11-09. Ele tem correções posteriores ao rc1, mas sozinho pode não conter as filas Qualcomm/7.5 presentes no `for-next` usado.
- Próxima decisão: comparar um `for-next` Qualcomm atualizado baseado em rc2, ou portar/rebasear somente as correções rc2 necessárias. Não trocar por rc2 vanilla sem conferir Kalambo, clocks, interconnect, GPU, SCMI e DTBs.
- Build arm64 com LLVM/Clang 23.1.5; Secure Boot não é suportado pelo kernel custom não assinado.
- Configuração inclui EFI early console, efifb, framebuffer console, EFI pstore, SELinux, EROFS zstd, overlay/DM e suporte Qualcomm necessário ao teste.

Secure Boot: em 2026-11-13, nesta rodada DIAG-R2, o usuário confirmou que está desativado desde o primeiro teste. Não tratar Secure Boot habilitado como hipótese principal para os três testes anteriores. A R2 já demonstrou a execução Linux; o bloqueio atual é a estabilidade do boot e a causa do reinício.

## Fedora/Niri/Noctalia preparados

- Base Fedora Workstation 45 aarch64, ISO oficial 45-1.4.
- SHA256 da base: `ad73a977709d417f5b7dda4147fc071396b9d8d2bdcca2df615aa3aab7673710`; assinatura Fedora válida.
- Niri 26.04-2.fc45; configuração validada e autostart do Noctalia configurado.
- Noctalia nativo 5.5.0-1.yoga.fc45.aarch64, compilado do tarball oficial.
- SHA256 do tarball Noctalia: `a4ba61392de6024905513d6b070cf40839809f61953468bda7eb8272f7a7aa16`, igual ao digest oficial.
- `noctalia --version` dentro do ARM retorna 5.5.0.
- Em 16/11/2026 o GNOME subiu no Lenovo por `simpledrm`; o Niri não roda sem GPU e o Noctalia não foi validado no hardware.

## DTBs e variantes: não misturar

- O upstream possui `glymur-lenovo-yoga-slim7x.dts` para o mesmo nome/chassi 83QR com Snapdragon X2 Elite/Glymur. Ele não pode ser usado diretamente no X2P-42-100.
- `mahua.dtsi` resultou em 12 nós de CPU; o DTB diagnóstico Mahua foi rejeitado antes de tocar o USB.
- `kalambo.dtsi` remove o primeiro cluster e deixa exatamente seis CPUs (cpu6–cpu11), compatível com o inventário do X2P-42-100.
- A árvore consultada contém `kalambo-crd.dts`, mas CRD não é a placa Lenovo. Não usar o DTB CRD como suporte do Yoga.
- O DTS `diag` não é mínimo: herda de `glymur-cob.dtsi` reguladores RPMh de tensão fixa e deixa ativos SMMUs, tsens, SPMI, TLMM e RSC. Os DTS atuais estão na seção "DTS e DTBs".

## Estado de segurança

- Em 16/11 o Fedora foi instalado no SSD interno do Yoga, apagando o Windows, com autorização explícita do usuário. A coleta do Windows de 13/11 está preservada no PC.
- O único dispositivo sobrescrito foi o pendrive autorizado pelo usuário; a coleta original está preservada no PC.
- Secure Boot desativado desde o primeiro teste, conforme confirmação do usuário. Preservar a chave de recuperação BitLocker.

## Arquivos para retomada

- `MEMORIA-LENOVO-YOGA-14Q8Y11.md`: índice de retomada, sem estados antigos concorrentes.
- No porte, `README.md`, `docs/ESTADO-ATUAL.md`, `RETOMADA.md` e o topo de `WORKFLOW.md` estão atualizados em 16/11. O restante de `WORKFLOW.md`, `DRIVERS.md` e `iso/RESULTADO-*.md` preserva o histórico de 13/11.
- `AUDITORIA-UPSTREAM-YOGA-14Q8Y11.md`: fontes upstream fixadas e limites.
- No porte: `RETOMADA.md`, `README.md`, `WORKFLOW.md`, `DRIVERS.md`, `CORES.md`, `sources.json`.
- Relatórios: `iso/RESULTADO-R3-CONS.md` (atual), `iso/RESULTADO-DIAG-R2.md` e `iso/RESULTADO.md` (históricos).
- Build privado: `local/iso-build/`; container `yoga-iso-build` encerrado ao fim dos testes anteriores. Não iniciado nesta pausa.
- Textos anteriores à consolidação preservados em `local/documentacao-2026-11-13-pre-consolidacao/`, com caminhos relativos ao workspace. Não usar esses snapshots como estado atual.
