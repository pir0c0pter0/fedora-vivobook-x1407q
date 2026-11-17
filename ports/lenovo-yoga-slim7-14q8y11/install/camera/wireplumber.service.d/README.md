# Software ISP da câmera RGB no WirePlumber

No Yoga X2 Plus, o libcamera 0.7.2 seleciona EGL por padrão. Sem GPU ativa,
EGL usa llvmpipe. A primeira captura via PipeWire caiu dentro do JIT LLVM
no processo WirePlumber, cujo serviço aplica `MemoryDenyWriteExecute=yes`.

`90-yoga-libcamera-cpu.conf` seleciona o debayer CPU nativo do libcamera
somente nesse serviço. Não altera as proteções do WirePlumber nem a
configuração global do Mesa ou dos outros aplicativos.

Validado no **boot normal `current` em 17/11/2026**: duas fontes descobertas
automaticamente, RGB padrão, 90 buffers RGB1080 e 60 IR640×480 GRAY8 via
PipeWire até EOS. WirePlumber manteve PID1712, `NRestarts=0`, modo CPU e
`MemoryDenyWriteExecute=yes` antes e depois. Evidência privada:
`local/physical-2026-11-17/camera-workflow/current-final-validation.txt`.

O nome suportado é `LIBCAMERA_SOFTISP_MODE=cpu`. A documentação e o código
do tag v0.7.2 confirmam que a variável mapeia para `software_isp.mode` e
que `cpu` cria `DebayerCpu` sem inicializar EGL:

- [Configuração de execução v0.7.2](https://gitlab.freedesktop.org/camera/libcamera/-/blob/v0.7.2/Documentation/runtime_configuration.rst).
- [Seleção do debayer v0.7.2](https://gitlab.freedesktop.org/camera/libcamera/-/blob/v0.7.2/src/libcamera/software_isp/software_isp.cpp).
- [Mapeamento da variável v0.7.2](https://gitlab.freedesktop.org/camera/libcamera/-/blob/v0.7.2/src/libcamera/global_configuration.cpp).

Instalar **como o usuário da sessão gráfica no Yoga**, a partir da raiz
deste porte, após copiar o arquivo para o notebook:

```sh
install -Dm644 install/camera/wireplumber.service.d/90-yoga-libcamera-cpu.conf \
  "$HOME/.config/systemd/user/wireplumber.service.d/90-yoga-libcamera-cpu.conf"
systemctl --user daemon-reload
systemctl --user restart wireplumber.service
systemctl --user show wireplumber.service \
  -p ActiveState -p Environment -p MemoryDenyWriteExecute
```

Confirmar `LIBCAMERA_SOFTISP_MODE=cpu`, `MemoryDenyWriteExecute=yes` e
serviço ativo. O drop-in fica em
`$HOME/.config/systemd/user/wireplumber.service.d/` na conta da sessão gráfica.

Em 17/11/2026, a captura direta com `cam`, como usuário, passou com
**60 quadros 1920×1080 ABGR8888** usando esse modo CPU. O resultado está em
`local/physical-2026-11-17/camera-workflow/cpu-rgb-test.txt`. O ensaio separado
`pipewire-cpu-test.txt` comprovou 60 buffers por câmera via PipeWire, seguido
do reteste no boot normal descrito acima.

Para repetir a validação como usuário, usar os nomes estáveis dos nós,
sem presumir IDs numéricos de `wpctl`:

```sh
RGB_NODE='libcamera_input._base_soc_0_cci_ac16000_i2c-bus_1_camera_10'
IR_NODE='libcamera_input._base_soc_0_cci_ac15000_i2c-bus_0_camera_10'
systemctl --user show wireplumber.service -p MainPID -p NRestarts
timeout 20s gst-launch-1.0 -e pipewiresrc target-object="$RGB_NODE" \
  ! video/x-raw,width=1920,height=1080 ! fakesink num-buffers=90
timeout 15s gst-launch-1.0 -e pipewiresrc target-object="$IR_NODE" \
  ! video/x-raw,width=640,height=480,format=GRAY8 ! fakesink num-buffers=60
systemctl --user show wireplumber.service -p MainPID -p NRestarts
```

Conferir EOS nos dois testes e o mesmo PID/contador de reinícios. O modo CPU
continua usando o software ISP, os controles AE/AWB e o acesso aos DMA heaps
já preparado pelo porte. A captura funciona sem calibração específica do
sensor; desempenho e cores em cada aplicativo têm validação própria.

Para remover somente este ajuste:

```sh
rm "$HOME/.config/systemd/user/wireplumber.service.d/90-yoga-libcamera-cpu.conf"
systemctl --user daemon-reload
systemctl --user restart wireplumber.service
```
