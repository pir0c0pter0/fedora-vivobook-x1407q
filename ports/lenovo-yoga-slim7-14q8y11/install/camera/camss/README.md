# CAMSS e RGB do Yoga

Validado manualmente em **17/11/2026** no Yoga com o kernel
`7.4.0-rc1-yoga-kalambo+` e o CCI corrigido: OV08X40 produziu quatro quadros
RAW 3856×2416 a aproximadamente 30 fps. Libcamera 0.7.2 também produziu
vinte quadros RGB processados 1280×720 a cerca de 30 fps como root.
Com CMA128 e permissões dos heaps, o usuário também capturou 90 quadros
1080p processados. Evidências em [TESTE-RGB-IR.md](../TESTE-RGB-IR.md).
A nova ordem passou no `try` v2 e no boot normal `current`: câmera pronta
antes do GDM e duas fontes WirePlumber automáticas. No boot normal, RGB1080
passou com 90 buffers e IR640×480 com 60 buffers via PipeWire, usando o
[ajuste CPU por usuário](../wireplumber.service.d/README.md), sem reinício do
WirePlumber. Usar o [ID estável RGB](../TESTE-RGB-IR.md#selecionar-o-sensor-pelo-id),
pois os índices de `cam -l` mudaram.

Esses resultados são da integração inicial. As três correções de reabertura
descritas abaixo também passaram no boot normal após a promoção para
`updates/`: `current` iniciou em 23,897 s, com os hashes esperados e sem
módulos diagnósticos. RGB e IR completaram os ensaios adicionais via PipeWire.

`glymur-camera-soc.dtsi` incorpora os nós dos patches 1–3 da
[série Qualcomm DTS v2 de 15/10](https://lore.kernel.org/r/20261015-glymur_camss_dts-v2-0-e7b1f403146f@oss.qualcomm.com).
Os controladores e PHYs permanecem desabilitados até um fragmento de placa
habilitá-los. O kernel usado já contém CAMSS Glymur, CCI e PHY CSI2 standalone;
não é necessário reconstruí-lo para acrescentar os nós.

`yoga-camera-rgb.dtsi` usa os dados desta placa, não os valores do sensor CRD:

| Recurso | Yoga | Evidência |
|---|---|---|
| Sensor | OV08X40, endereço I²C `0x10` | `SCFG_FRONT_QRD.bin`, módulo `Shinetech_ov08x` |
| Controle | CCI1, barramento 1, GPIO235/236 | `CAMP_PCFG_QRD.bin`, `CAMP_RES_QRD.bin`, DTS SoC |
| Reset | GPIO239, ativo baixo | `CAMF_RES_QRD.bin`, corroborado pelo DTS CRD |
| Clock | MCLK4, GPIO100, 19,2 MHz | `CAMF_RES_QRD.bin` |
| Alimentação | L7 2,8 V / L4 1,8 V / L2 1,104 V | `CAMF_RES_QRD.bin`; grade PM8010 |
| Dados | CSIPHY4, quatro lanes | `CAMP_PCFG_QRD.bin`, DSDT KBUF, `laneAssign=0x3210` |
| PHY | L1_F_E1 / L4_F_E1 | `C1KD.bin`; limites existentes preservados |

CCI1/bus0 permanece desabilitado porque seu GPIO106 pertence ao reset do PMIC.
Os estados MCLK3 e CCI1/bus0 definidos no fragmento SoC não são selecionados.
Os GPIO99 da chave e GPIO106 do PMIC não devem ser reutilizados por esses estados.

O driver CCI deste kernel precisa de `qcom-cci-reset-completion.patch`: o reset
do controlador sempre espera pela completion do master 0, mas o probe original
só inicializa completions de barramentos habilitados. Com apenas bus1 ativo,
essa lista permanece nula. O patch inicializa ambos os masters antes de registrar
a IRQ, sem habilitar bus0 nem mudar seus pinos. O teste
`python3 test-cci-completion.py CAMINHO/i2c-qcom-cci.c` executa os trechos reais
de inicialização e reset com cada combinação de barramentos; a fonte original
aborta no caso bus1, enquanto a corrigida passa.

No hardware, `modprobe i2c_qcom_cci` com o módulo original retornou
`Segmentation fault`, seguido de perda de acesso remoto e reinicialização.
A coleta não preservou uma stack completa do Oops; o diagnóstico da
completion foi confirmado pela fonte, pelo reprodutor e pelo reteste com
o módulo corrigido. O reteste registrou `ac15000.cci` e `ac16000.cci`,
adaptadores CCI5/CCI6 nesta enumeração, e ambos os sensores.
Os logs privados são `camss-probe.txt`, `cci-fixed-probe.txt` e
`rgb/cci-completion-check.txt` em `local/physical-2026-11-17/camera-workflow/`.

A sequência de captura vem do driver upstream `ov08x40.c`: quatro lanes,
link de 400 MHz, Bayer GRBG10, primeiro modo 3856×2416. O Windows usa modos e
registros próprios; não misturar seus timings com as tabelas do driver Linux.

## Reproduzir o baseline inicial

Esta receita preserva o baseline usado no primeiro bring-up. Para os módulos
promovidos após o ensaio de reabertura, usar a receita de três módulos abaixo.

Executar a partir da pasta do porte, com o container existente `yoga-iso-build`
ativo e `local/iso-build` montado em `/work`:

```sh
set -eu
mkdir -p local/iso-build/extmod-yoga-cci
cp local/iso-build/kernel/drivers/i2c/busses/i2c-qcom-cci.c \
  local/iso-build/extmod-yoga-cci/
git apply -p4 --directory=local/iso-build/extmod-yoga-cci \
  install/camera/camss/qcom-cci-reset-completion.patch
printf 'obj-m += i2c-qcom-cci.o\n' > local/iso-build/extmod-yoga-cci/Kbuild
podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp \
  M=/work/extmod-yoga-cci ARCH=arm64 LLVM=1 -j4 modules

mkdir -p local/iso-build/extmod-ov08x40
cp local/iso-build/kernel/drivers/media/i2c/ov08x40.c local/iso-build/extmod-ov08x40/
printf 'obj-m += ov08x40.o\n' > local/iso-build/extmod-ov08x40/Kbuild
podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp \
  M=/work/extmod-ov08x40 ARCH=arm64 LLVM=1 -j4 modules
```

O módulo deve apresentar o mesmo `vermagic` do kernel em execução. Ele depende
dos módulos V4L2 existentes e não modifica o kernel nem a sequência do sensor.

Os comandos copiam fontes stock novas antes de aplicar o patch e não
alteram a árvore do kernel. Conferir `modinfo -F vermagic` nos dois `.ko`.
Carregar o CCI corrigido somente em boot limpo; não tentar recuperar um
módulo que já provocou falha. O teste offline usa compilador C do PC e não
acessa hardware:

```sh
# Resultado esperado: falha com assertion no caso enabled buses mask=2.
python3 install/camera/camss/test-cci-completion.py \
  local/iso-build/kernel/drivers/i2c/busses/i2c-qcom-cci.c
# Resultado esperado: passa com masks 2, 1, 3 e 0.
python3 install/camera/camss/test-cci-completion.py \
  local/iso-build/extmod-yoga-cci/i2c-qcom-cci.c
```

Executar os dois testes separadamente, pois o primeiro retorna erro por
projeto. O patch não habilita adaptadores desabilitados no DT.

## Recuperação após reabertura

Em 17/11, após o teste prolongado e uma captura RGB bem-sucedidos, uma
reabertura imediata falhou na escrita inicial `0x0103=1` do OV08X40.
O CCI permaneceu runtime-active entre o desligamento e a retomada do sensor.
Seu diagnóstico mostrou `irq=0`, `cmd=0x01030139`, `cur=1`, `exec=3`,
`report=0`: a fila estava presa na primeira escrita. A rotina de timeout
reseta o controlador antes de devolver `-ETIMEDOUT`.

O erro também revelou um problema separado no CAMSS: os receivers que já
tinham iniciado permaneciam ligados quando o sensor falhava. Na próxima
abertura, o core V4L2 avisava sobre `s_stream_enabled` e pulava a configuração
desses componentes; o processo podia iniciar sem receber quadros.

O conjunto promovido contém três correções distinguíveis:

| Patch | Efeito e limite |
|---|---|
| `qcom-cci-runtime-resume-test.patch` | Reseta o CCI ao retomar, propaga falha e libera clocks; drena a IRQ de reset antes de uma nova transferência. Mantém autosuspend de 1 s. |
| `ov08x40-initial-reset-retry-test.patch` | Repete uma única vez a escrita idempotente inicial de reset, somente em `ETIMEDOUT`. Tabelas, controles e stream-on continuam sem repetição. |
| `camss-start-unwind-test.patch` | Desliga o prefixo de subdevices iniciado antes de um erro, excluindo o que falhou; o teardown continua mesmo se um componente reporta erro. |

A correção CCI inclui a inicialização de completions descrita acima.
O `synchronize_irq()` é necessário porque o ISR completa master0 e depois
master1, enquanto a espera do reset usa master0: o segundo ACK não pode
alcançar uma nova transferência. A rotina IRQ não adquire o lock do adaptador
mantido pelo chamador I²C.

Origem e revisões foram preservadas nos patches. O problema CCI foi discutido
na [série upstream de 20/10](https://lore.kernel.org/all/20261020193946.51478-1-birk.skyum@pm.me/);
o retry restrito ao OV08 é um ajuste local apoiado pelo diagnóstico deste Yoga.
O unwind usa a mudança mínima da
[primeira proposta upstream](https://lists.openwall.net/linux-kernel/2026/10/29/1874),
preservando a API e caminhada de pads existentes. A
[v2 upstream](https://lore.kernel.org/all/20261031041154.308030-3-xiaqinghuan@mail.ustc.edu.cn/)
também refatora essas APIs; essa parte não foi incorporada.

**Ensaio `try` aprovado e módulos promovidos:** dez aberturas RGB de
15 quadros e dez IR de 30 quadros, em sequência rápida, entregaram as contagens
exatas. Nove timeouts CCI no reset inicial RGB foram recuperados; não houve
WARN, Oops ou falha de stream. O timeout físico permanece possível e custa
cerca de 100 ms à abertura recuperada. Um timeout seguido de quadros completos
é diferente de uma falha de stream ou de um processo que retorna sem quadros.
Não contar apenas o código de saída para validar a recuperação.

No boot normal `current` após a promoção, RGB entregou 90 quadros com metadata
e o perfil específico instalado em `/etc`. Os ensaios PipeWire entregaram
1.800 buffers RGB em 60,181 s e 1.800 buffers IR em 29,016 s, ambos até EOS.
WirePlumber permaneceu com PID1718 e `NRestarts=0`. Houve um timeout no reset
inicial RGB, recuperado; não houve WARN/Oops do kernel nem falha de stream.
Os avisos já conhecidos de propriedades e controles dos sensores no libcamera
continuam separados desses erros. Logs privados: `normal-preflight.txt`,
`normal-ccm-metadata.txt`, `normal-pw-rgb.txt`, `normal-pw-ir.txt`,
`normal-wp-final.txt` e `normal-final-kernel.txt` em
`local/physical-2026-11-17/camera-calibration/`.

O ensaio carregou a candidata de CCM do Windows, privada e específica ao sensor,
em `/etc/libcamera/ipa/simple/ov08x40.yaml`. Isso não altera os registradores do
sensor nem comprova calibração colorimétrica completa. Os laudos privados estão
em `local/physical-2026-11-17/camera-calibration/rgb/CCI-RUNTIME-AUDIT.md` e
`CAMSS-OV08-RECOVERY.md`; os diagnósticos anteriores estão em
`cci-reopen-kernel.txt` e `cci-resume-test-kernel.txt` na pasta superior.

Para reproduzir os três módulos, a partir do porte:

```sh
set -eu
mkdir -p local/iso-build/extmod-yoga-cci-resume-v2
cp local/iso-build/kernel/drivers/i2c/busses/i2c-qcom-cci.c \
  local/iso-build/extmod-yoga-cci-resume-v2/
printf 'obj-m += i2c-qcom-cci.o\n' > local/iso-build/extmod-yoga-cci-resume-v2/Kbuild
git apply -p4 --directory=local/iso-build/extmod-yoga-cci-resume-v2 \
  install/camera/camss/qcom-cci-reset-completion.patch
git apply -p4 --directory=local/iso-build/extmod-yoga-cci-resume-v2 \
  install/camera/camss/qcom-cci-runtime-resume-test.patch

mkdir -p local/iso-build/extmod-ov08x40-reset-retry
cp local/iso-build/kernel/drivers/media/i2c/ov08x40.c \
  local/iso-build/extmod-ov08x40-reset-retry/
printf 'obj-m += ov08x40.o\n' > local/iso-build/extmod-ov08x40-reset-retry/Kbuild
git apply -p4 --directory=local/iso-build/extmod-ov08x40-reset-retry \
  install/camera/camss/ov08x40-initial-reset-retry-test.patch

mkdir -p local/iso-build/extmod-yoga-camss-unwind
cp local/iso-build/kernel/drivers/media/platform/qcom/camss/*.[ch] \
  local/iso-build/kernel/drivers/media/platform/qcom/camss/Makefile \
  local/iso-build/extmod-yoga-camss-unwind/
git apply -p6 --directory=local/iso-build/extmod-yoga-camss-unwind \
  install/camera/camss/camss-start-unwind-test.patch

podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp \
  M=/work/extmod-yoga-cci-resume-v2 ARCH=arm64 LLVM=1 -j4 modules
podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp \
  M=/work/extmod-ov08x40-reset-retry ARCH=arm64 LLVM=1 -j4 modules
podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp \
  M=/work/extmod-yoga-camss-unwind ARCH=arm64 LLVM=1 -j4 modules

python3 install/camera/camss/test-cci-completion.py \
  local/iso-build/extmod-yoga-cci-resume-v2/i2c-qcom-cci.c
python3 install/camera/camss/test-cci-runtime.py \
  local/iso-build/extmod-yoga-cci-resume-v2/i2c-qcom-cci.c
python3 install/camera/camss/test-ov08x40-reset-retry.py \
  local/iso-build/extmod-ov08x40-reset-retry/ov08x40.c
python3 install/camera/camss/test-camss-unwind.py \
  local/iso-build/extmod-yoga-camss-unwind/camss-video.c
```

Os testes executam trechos reais das fontes C com falhas injetadas: quatro
máscaras de masters, cinco caminhos de runtime/IRQ, dezoito cenários OV08
(incluindo binning) e doze cenários de unwind/reabertura. A fonte CAMSS original
reproduz a falha; a corrigida passa. Revisão independente e aplicação dos patches
em cópias novas passaram; as fontes resultantes coincidem com as construídas.

Hashes SHA256 dos módulos ensaiados e promovidos, todos com o vermagic do kernel atual:

| Módulo | SHA256 |
|---|---|
| CCI v2 | `b7f3f921a932fb8e342d2949896def292e615a88e307d90fc857e023f5dd291c` |
| OV08X40 | `4ae757a56100c1d93529e1200aba6fe590b2f0efe25beadeed86bf47e6741c9d` |
| CAMSS | `31a4efbe2542c455799a6dd0dc0a4b220a44c2835c5299e6b67e4c7b3534308c` |

Os módulos CCI v2 e OV08X40 substituíram os anteriores em `updates/`; CAMSS
foi acrescentado no mesmo diretório. Os módulos anteriores estão preservados
no Yoga em `/root/camera-calibration-20261117/modules-before`, e os módulos
stock do kernel permanecem intactos. Os overlays, unidades e drop-ins de teste
foram removidos, e o slot `try` foi restaurado de `current`.
A validação de boot normal e PipeWire após essa promoção passou conforme
os resultados acima. O startup exige que `qcom_camss` resolva para `updates/`
antes da primeira carga de módulos, assim como os outros drivers corrigidos.
A receita acima apenas reproduz e testa os arquivos locais.

## Composição e teste

Acrescentar ao DTS do slot de teste, nesta ordem: base atual USB3,
`glymur-camera-soc.dtsi`, `../power/yoga-camera-power.dtsi` e
`yoga-camera-rgb.dtsi`. Manter o bloqueio de carregamento automático dos módulos
experimentais e carregá-los individualmente após conferir a alimentação.
O teste do PMIC vem antes do sensor. O probe do OV08X40 confere o ID
`0x560858` em `0x300a`; não acessar I²C diretamente enquanto o driver possui
o dispositivo. Seguir a [ordem de carga corrigida](../TESTE-RGB-IR.md),
usando `insmod` da cópia CCI revisada ou `modprobe` após instalar a correção
em `updates/` e conferir sua seleção. Não usar o CCI stock deste kernel.

Depois do probe, `media-ctl -p` deve mostrar o sensor, `msm_csiphy4`, `msm_csid0`,
`msm_vfe0_rdi0` e o dispositivo `msm_vfe0_video0`. Usar os nomes e dispositivos
da topologia real; os números de `/dev/video*` e do barramento I²C não são fixos.
Configurar `SGRBG10_1X10/3856x2416` nos pads de entrada e os links
`msm_csiphy4:1 → msm_csid0:0` e `msm_csid0:1 → msm_vfe0_rdi0:0`. A captura usa
`SGRBG10P` (`pgAA` no v4l2-ctl), quatro buffers MMAP, contagem limitada e timeout.

Aceitação: capturas repetidas com conteúdo variável da cena, sem timeout ou
erro CSI/VFE/SMMU, seguidas de parada e nova abertura. Conferir vídeo do painel,
Wi-Fi e USB durante o stream porque L1_F_E1/L4_F_E1 são compartilhados.
Captura RAW não comprova integração libcamera/PipeWire nem calibração de cores.
No teste processado a 720p, libcamera usou o software ISP e llvmpipe com
entrada 1928×1208 GRBG10 e saída ABGR8888. O modo processado de 1080p falhou
por falta de CMA com a reserva de 32 MiB e passou com `cma=128M`.
Avisos de crop, propriedades estáticas e tuning não calibrado
permanecem. Como usuário, confirmar acesso aos DMA heaps e o formato final:
sem esse acesso, libcamera pode entregar RAW com retorno zero.

O probe CAMSS publica `mediaN` antes de registrar seu notifier V4L2; o
callback `complete` liga os sensores e registra os nós de subdispositivo.
Os drivers OV08X40 e VD55G0 podem registrar seus subdevices previamente na
lista async global. Por isso o startup carrega sensores e heaps primeiro,
espera bind/permissões e só então carrega CAMSS. Resta uma pequena janela
interna de publicação; a ordenação antes do gerenciador gráfico foi
comprovada no `try` v2 e no boot normal `current`. A correção posterior de unwind
é independente dessa ordenação de publicação.
