# Inicialização das câmeras do Yoga X2 Plus

`yoga-camera.service` prepara RGB, IR, DMA heaps e o iluminador desligado.
Só executa com `yoga.camera=1`, depois de `yoga-video.service` e
`yoga-usb3.service`, e depois de `yoga-gpu.service` quando a GPU estiver
programada para iniciar. A habilitação cria uma dependência em
`yoga-usb3.service.wants`: o gatilho udev USB3 existente continua responsável
por iniciar a sequência depois da placa Wi-Fi, sem esperar associação à rede.
Sensores e heaps são preparados antes de carregar CAMSS; a espera udev é
limitada aos dois heaps para concluir suas permissões. O GDM pode iniciar enquanto a câmera termina a preparação.

Boot normal aprovado no **slot `current` em 17/11/2026**, após o teste no
`try`: câmera terminou em 23,810963 s, antes do início do GDM em
23,813315 s; boot total de 23,838 s. WirePlumber descobriu os dois dispositivos e as duas fontes
automaticamente, sem reinício. Sensores e heaps ficaram prontos e o
iluminador terminou OFF. RGB permaneceu como câmera padrão. `good` foi
preservado; o boot salvo é `current`, sem tentativa pendente. Evidência privada:
`local/physical-2026-11-17/camera-workflow/current-final-validation.txt`.

Capturas RAW RGB/IR e capturas processadas como usuário estão registradas
em [TESTE-RGB-IR.md](TESTE-RGB-IR.md). No boot normal, PipeWire passou com
90 buffers RGB1080 e 60 IR640×480 GRAY8 até EOS após o
[ajuste CPU por usuário do WirePlumber](wireplumber.service.d/README.md).
O processo permaneceu com PID 1712, `NRestarts=0` e `MemoryDenyWriteExecute=yes`.
Na rodada posterior, o [perfil RGB do Windows](WINDOWS-CALIBRATION.md) foi
instalado e as [correções de reabertura](camss/README.md) foram promovidas.
O boot normal passou em 23,897 s: 90 quadros RGB com CCM conferida e,
via PipeWire, 1.800 buffers RGB1080 em 60,181 s e 1.800 IR em 29,016 s.
WirePlumber PID1718/NRestarts0 permaneceu estável; um timeout inicial RGB
foi recuperado, sem falha de stream ou WARN do kernel.
O [ensaio de sincronização](ir/SYNCHRONIZATION.md) ficou limitado a quadro
único; módulos, opções, DT e unidades temporários foram retirados.

## Pré-requisitos

- DTB compilado de [ir/yoga-camera-all-test.dts](ir/yoga-camera-all-test.dts),
  sobre a base USB3 validada, com PM8010, CCI corrigido e ambos os sensores.
- Kernel `7.4.0-rc1-yoga-kalambo+` e módulos com o mesmo vermagic; debugfs
  montado, Python 3 e kmod disponíveis.
- Vídeo e USB3 ativos, eDP conectado, PCIe Wi-Fi/NVMe ativos;
  `vreg_l1f1` e `vreg_l4f1` em uso, BOB1_E0 em uso a 3416 mV.
- Os sete módulos desta tabela devem ser os artefatos revisados em `updates/`;
  o caminho, sozinho, não identifica a correção. Comparar hashes/build-id
  com o pacote testado antes da instalação.

| Arquivo em `updates/` | Fonte/correção |
|---|---|
| `qcom-pm8008.ko` | [MFD PM8010](extmod-pm8010/qcom-pm8008.c) |
| `qcom-pm8008-regulator.ko` | [Reguladores PM8010](extmod-pm8010/qcom-pm8008-regulator.c) |
| `i2c-qcom-cci.ko` | Completions corrigidas, reset na retomada e drenagem da IRQ; [build e patches](camss/README.md) |
| `ov08x40.ko` | [Reset inicial com uma repetição após timeout](camss/ov08x40-initial-reset-retry-test.patch) |
| `qcom-camss.ko` | [Desligamento dos subdispositivos iniciados quando um start falha](camss/camss-start-unwind-test.patch) |
| `vd55g0.ko` | [Driver ST v5 e build](ir/README.md) |
| `leds-qcom-flash.ko` | [Timer e teardown corrigidos](ir/qcom-flash-cleanup.patch) |

`camcc_glymur`, `phy_qcom_mipi_csi2`, `system_heap` e `cma_heap`
usam os módulos stock deste kernel. A unidade verifica todos os arquivos e
releases antes da primeira carga. Recusa CCI ou flash já carregados, pois
`modinfo` consulta o disco e não comprova qual binário está na memória.
Uma tentativa parcial exige revisar o erro e reiniciar, sem descarregar
drivers que compartilham recursos com vídeo e USB.

## Instalar no Lenovo, depois de preparar e revisar o pacote

Preservar DTB/argumentos/initramfs de `current`, `good` e `try`, estado do
boot e quaisquer módulos/unidades que serão substituídos. Em um diretório
de pacote, reunir os sete `.ko` revisados da tabela. No notebook:

```sh
set -eu
release=$(uname -r)
test "$release" = '7.4.0-rc1-yoga-kalambo+'
# Fazer o backup dos arquivos existentes antes desta instalação.
sudo install -d "/usr/lib/modules/$release/updates"
sudo install -m 0644 qcom-pm8008.ko qcom-pm8008-regulator.ko \
  i2c-qcom-cci.ko ov08x40.ko qcom-camss.ko vd55g0.ko leds-qcom-flash.ko \
  "/usr/lib/modules/$release/updates/"
sudo depmod -a "$release"
for module in qcom_pm8008 qcom_pm8008_regulator i2c_qcom_cci ov08x40 qcom_camss vd55g0 leds_qcom_flash; do
  modinfo -n "$module"
  modinfo -F vermagic "$module"
done
```

Conferir que os sete caminhos apontam a `updates/`, e instalar os três
arquivos a partir desta pasta do porte:

```sh
sudo install -m 0755 install/camera/yoga-camera-up /usr/local/sbin/
sudo install -m 0644 install/camera/yoga-camera.service /etc/systemd/system/
sudo install -m 0644 install/camera/70-yoga-camera.rules /etc/udev/rules.d/
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
sudo systemctl enable yoga-camera.service
```

Não usar `enable --now`: a carga manual anterior já pode estar na memória.
No slot `try`, usar o DTB conjunto e acrescentar `yoga.camera=1` e `cma=128M`, preservando
`yoga.video=1`, `yoga.usb=1`, `yoga.usb3=1` e os bloqueios existentes.
Acrescentar estes nomes a **ambas** as listas `modprobe.blacklist` e
`rd.driver.blacklist`, sem substituir as listas:

```text
qcom_pm8008,qcom_pm8008_regulator,camcc_glymur,i2c_qcom_cci,phy_qcom_mipi_csi2,qcom_camss,ov08x40,vd55g0,leds_qcom_flash
```

Esses bloqueios evitam carga por alias/initramfs; a unidade carrega nomes
explicitamente. Não usar `module_blacklist` nem uma regra `install ... false`,
que impediriam essa carga. Usar a tentativa única existente `yoga-boot-once
try`, conferir a ordem no journal, `systemctl status yoga-camera.service`,
ambos os sensores no `media-ctl -p`/`cam -l`, DMA heaps e leitura física OFF.
Só promover o slot depois de repetir captura e conferir vídeo, USB e rede.

A regra udev concede acesso por grupo `video` e pela sessão local ativa
(`uaccess`) somente a `/dev/dma_heap/system` e `default_cma_region`. Ela
deve ser instalada antes da carga dos módulos; para nós já existentes,
reaplicar somente nesses dois dispositivos e conferir suas ACLs. O heap
`reserved` não recebe permissão adicional. Testar `cam` como o usuário da
sessão: com os heaps restritos a root, libcamera pode desativar o software
ISP e capturar RAW mesmo retornando zero. O teste como root produziu RGB
processado a 720p; 1080p excedeu a reserva CMA de 32 MiB. Com `cma=128M`
e acesso aos heaps, o usuário capturou 90 quadros 1080p ABGR8888 a cerca
de 30 fps; GStreamer direto também passou com RGB1080 e IR640×480.
Descoberta automática e streams RGB/IR via PipeWire passaram no `try` e
no boot normal `current`, com o ajuste CPU por usuário. O serviço não
altera a reserva nem os argumentos de boot.

Os índices de `cam -l` mudam com a ordem de registro: no `try` v2, IR é 1 e
RGB é 2. Usar os IDs estáveis e as [receitas de captura](TESTE-RGB-IR.md#selecionar-o-sensor-pelo-id),
sem presumir que a primeira câmera seja RGB.

O script não captura quadros nem dispara luz. Escreve OFF nos dois controles
do flash e confere 0xee46/0xee4e por leitura dirigida. Não altera GPIO99 nem
o evento `SW_CAMERA_LENS_COVER` da chave de privacidade. A chave continua
disponível ao sistema; esta unidade não acrescenta política de captura ou
autenticação. A capacidade atual de flash permanece limitada pelo DT a
100 mA totais/10 ms; não usar torch para contornar esse limite.

## Testar as guardas sem hardware

A partir da raiz deste porte:

```sh
python3 install/camera/test-startup.py
```

Os 20 cenários simulam sysfs e comandos de carga, incluindo o layout real
de mídia, pré-requisitos ausentes, ordem de publicação e falhas do OFF.
Não acessam o notebook nem substituem as capturas e o boot físico.

## Reverter

Desabilitar `yoga-camera.service`, retirar `yoga.camera=1` do slot e
restaurar seu DTB/argumentos anteriores; reiniciar para a base preservada.
`systemctl stop` não descarrega drivers nem desenergiza o PMIC. Não usar
`rmmod` como rollback: GPIO106/BOB podem continuar ativos e os trilhos CSI
são compartilhados. Restaurar/remover somente os sete arquivos de
`updates/`, a unidade/script e `70-yoga-camera.rules` desta instalação,
conforme o backup; executar `depmod -a`, `systemctl daemon-reload` e
`udevadm control --reload-rules`. Reiniciar remove as permissões herdadas
nos nós existentes. Preservar os demais módulos
de vídeo/USB e manter `good` intocado durante o teste.
