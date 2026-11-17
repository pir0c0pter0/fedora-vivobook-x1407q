# Teste RGB + IR

Atualização de 17/11 após o [perfil Windows](WINDOWS-CALIBRATION.md) e as
correções CCI/OV08X40/CAMSS: dez reaberturas rápidas de cada câmera passaram,
com nove timeouts iniciais RGB recuperados. No boot normal `current`,
90 quadros RGB8881080p publicaram a CCM extraída; PipeWire concluiu 1.800
buffers RGB em 60,181 s e 1.800 IR em 29,016 s. WirePlumber permaneceu com
PID1718/NRestarts0. Um timeout foi recuperado nessa validação normal, sem
WARN/Oops/falha de stream. Logs em `camera-calibration/normal-*.txt`.
As rotas DEBUG mostram que ambas as câmeras usam CSID0/VFE0 na libcamera
atual; estes testes são sequenciais, sem comprovação de captura simultânea.

Capturas físicas aprovadas em **17/11/2026**, kernel
`7.4.0-rc1-yoga-kalambo+`, após substituir o CCI original:

| Caminho | Resultado observado |
|---|---|
| RGB V4L2 | OV08X40 em `6-0010`, quatro quadros `pgAA` 3856×2416; intervalos de 33,33 ms, cerca de 30 fps; 46.696.448 bytes |
| IR V4L2 | VD55G0 em `5-0010`, oito quadros `Y10P` 640×480; cerca de 60 fps; 3.072.000 bytes |
| RGB libcamera 0.7.2, root | Vinte quadros 1280×720 `ABGR8888/sRGB`, aproximadamente 30 fps; software ISP ativo, renderer llvmpipe |
| RGB libcamera, usuário, CMA128 | Noventa quadros 1920×1080 `ABGR8888/sRGB`, aproximadamente 30 fps |
| GStreamer direto, usuário | Sessenta buffers RGB1080 `RGBx` e sessenta IR640×480 `GRAY8` |
| PipeWire no boot normal `current`, usuário, software ISP CPU | Noventa buffers RGB1080 e sessenta IR640×480 GRAY8 até EOS; WirePlumber PID1712/NRestarts0 antes e depois, MDWE habilitado |

As enumerações I²C acima são desta coleta, não endereços de barramento
permanentes. Evidências privadas em
`local/physical-2026-11-17/camera-workflow/{rgb-capture1,ir-capture1,rgb-libcamera-720}.txt`.
O primeiro boot automático registrou sensores e heaps, mas a guarda de mídia
usava um caminho sysfs incorreto. A correção usa o barramento media real.
Foi detectada também descoberta prematura pelo WirePlumber: reiniciá-lo
após a carga revelou os dois sensores. A nova ordem sensores/heaps antes
CAMSS e câmera antes do gerenciador gráfico passou no **`try` v2**:
unidade concluída em 23,884430 s, GDM iniciado em 23,885607 s e boot total
de 23,892 s. WirePlumber publicou dois dispositivos libcamera e duas fontes
automaticamente, sem restart. Evidência em `integration-try-v2.txt`.
O **boot normal `current` também passou**: câmera concluída em 23,810963 s,
GDM iniciado em 23,813315 s e boot total de 23,838 s. As duas fontes foram
descobertas automaticamente, RGB permaneceu padrão e os dois streams
PipeWire chegaram a EOS sem reinício do WirePlumber. O preflight do flash
confirmou módulo/canais OFF, sem emissão nesta validação final. Vídeo,
USB2/USB3, SoCCP, RTC e EC estavam ativos; `good` permaneceu intacto e o
boot salvo é `current`, sem tentativa pendente. A única unidade em falha
era `firewalld.service`, fora da pilha de câmera.
O laudo `current-final-validation.txt` registra comandos, serviços e resultados.
Evidências adicionais em `integration-user-capture.txt`, `integration-apps.txt`
e `integration-wireplumber-restart.txt` na mesma pasta privada. A falha
separada ao abrir RGB por PipeWire foi corrigida selecionando o debayer CPU
no [drop-in do WirePlumber por usuário](wireplumber.service.d/README.md),
mantendo `MemoryDenyWriteExecute=yes`. `pipewire-cpu-test.txt` comprova o
primeiro ensaio; `current-final-validation.txt` confirma a persistência no
boot normal, com PID1712/NRestarts0 antes e depois das capturas.
RGB processado a 1080p falhou com CMA de 32 MiB e passou com 128 MiB.
A captura como usuário sem
acesso aos DMA heaps retornou zero, mas caiu para RAW: conferir formato e
mensagens do software ISP, além do retorno. A integração e a regra de acesso
estão em [README.md](README.md). Os avisos de crop/propriedades e calibração
`uncalibrated.yaml` permanecem; esses testes não comprovam calibração de cores
específica nem todas as aplicações gráficas. `rgb-1080.png`, na pasta privada,
é uma imagem real capturada em 1080p.

## Selecionar o sensor pelo ID

No `try` v2 a ordem mudou para IR=1 e RGB=2. Usar IDs estáveis, tanto no
`cam` quanto na propriedade `camera-name` do GStreamer. Executar os testes
sequencialmente, como o usuário da sessão com acesso aos heaps:

```sh
RGB='/base/soc@0/cci@ac16000/i2c-bus@1/camera@10'
IR='/base/soc@0/cci@ac15000/i2c-bus@0/camera@10'
cam -l
timeout 15s cam -c "$RGB" -s width=1920,height=1080,pixelformat=ABGR8888 --capture=90
timeout 15s cam -c "$IR" -s width=640,height=480,pixelformat=R8 --capture=60
timeout 15s gst-launch-1.0 -e libcamerasrc camera-name="$RGB" \
  ! video/x-raw,format=RGBx,width=1920,height=1080 ! fakesink num-buffers=60 sync=false
timeout 15s gst-launch-1.0 -e libcamerasrc camera-name="$IR" \
  ! video/x-raw,format=GRAY8,width=640,height=480 ! fakesink num-buffers=60 sync=false
```

Conferir o ID selecionado, formato negociado e quantidade de quadros. Os
números de `/dev/video*`, IDs numéricos PipeWire e adaptadores I²C também
podem mudar entre boots. Essas receitas diretas não atravessam PipeWire.
A contagem `num-buffers` pertence ao [fakesink](https://gstreamer.freedesktop.org/documentation/coreelements/fakesink.html#fakesink:num-buffers),
não ao elemento `libcamerasrc`.

## Preparar uma carga manual controlada

`yoga-camera-rgb-ir-test.dts` reúne a base USB3 atual, CAMSS/CCI, PM8010 e
os dois sensores. Não contém iluminador nem `st,leds`. Compilar com os
mesmos includes e `dtc` usados nos outros DTBs do porte; submeter a revisão
independente antes do boot `try`.

Preservar `current`/`good` e o backup de `try`. Copiar kernel, initramfs e
argumentos de `current` para `try`, mudando apenas o DTB. Para esta carga
manual, retirar `yoga.camera=1` dos argumentos copiados; esse argumento delega a sequência
ao serviço automático. Acrescentar os seguintes nomes às listas existentes
de `modprobe.blacklist` **e** `rd.driver.blacklist`:

```text
camcc_glymur,qcom_pm8008,qcom_pm8008_regulator,i2c_qcom_cci,phy_qcom_mipi_csi2,qcom_camss,ov08x40,vd55g0,leds_qcom_flash
```

Manter também todas as blacklists anteriores. Armar uma tentativa com
`yoga-boot-once try`; no retorno conferir vídeo, rede, USB, NVMe, bateria,
GPIO99 e BOB1 em 3416 mV. Não carregar módulos se o PMIC ainda não tiver
sido identificado, se BOB1 estiver desligado ou se GPIO106 tiver outro dono.

Módulos preparados no PC, relativos à pasta do porte:

- PMIC: `install/camera/extmod-pm8010/qcom-pm8008.ko` e
  `qcom-pm8008-regulator.ko`.
- CCI **corrigido**: `local/iso-build/extmod-yoga-cci/i2c-qcom-cci.ko`,
  com [patch e build obrigatórios](camss/README.md).
- RGB: `local/iso-build/extmod-ov08x40/ov08x40.ko`.
- IR: `local/iso-build/extmod-vd55g0/vd55g0.ko`.

Conferir `modinfo -F vermagic` contra `uname -r` antes de copiar para uma
pasta temporária do Yoga. Os comandos abaixo pressupõem essa pasta como
diretório atual; registrar `dmesg` e `devices_deferred` entre etapas e parar
na primeira falha. `insmod` não resolve dependências automaticamente.

```sh
set -eu
test ! -d /sys/module/i2c_qcom_cci
modprobe regmap_i2c
insmod ./qcom-pm8008.ko
insmod ./qcom-pm8008-regulator.ko
# Conferir PMIC, sete reguladores, GPIO106 e tensões antes da câmera.
modprobe camcc_glymur
insmod ./i2c-qcom-cci.ko
modprobe phy_qcom_mipi_csi2
modprobe v4l2_fwnode
modprobe v4l2_cci
insmod ./ov08x40.ko
# Conferir probe RGB/ID e ausência de falha antes de acrescentar IR.
insmod ./vd55g0.ko
modprobe system_heap
modprobe cma_heap
udevadm wait --timeout=10 --initialized=yes \
  /dev/dma_heap/system /dev/dma_heap/default_cma_region
# Conferir ambos os sensores bound antes de publicar mediaN.
modprobe qcom_camss
media-ctl -p
cam -l
```

A primeira carga do CCI original retornou `Segmentation fault` em
`modprobe i2c_qcom_cci` e exigiu reinicialização. O reset usa a completion
do master0 mesmo com bus0 desabilitado; o probe original a deixava sem
inicialização neste caso. O [reprodutor offline](camss/test-cci-completion.py)
aborta com a fonte original e passa com o patch. O CCI corrigido registrou
os dois controladores no Yoga e permitiu as capturas acima. Não habilitar
CCI1/bus0 como contorno: seus pinos incluem GPIO106, do PMIC.

A blacklist bloqueia descoberta por alias, mas não o `modprobe` explícito.
Se os módulos já estiverem instalados em `updates/`, a alternativa é a
sequência do serviço, que confere caminhos/versões antes de carregar.
Não executar o exemplo manual sobre o serviço já ativo.
Não usar `rmmod` em lote nem desligar os reguladores compartilhados para
recuperar uma falha; capturar os logs e voltar pelo reboot normal a `current`.

Para captura, seguir os formatos em `camss/README.md` e `ir/README.md`, usando
os nomes reais de `media-ctl -p`. Testar primeiro cada sensor separadamente,
com contagem limitada e timeout, depois repetir abertura/parada. A presença
de `/dev/video*` sozinha não comprova frames nem funcionamento das câmeras.
