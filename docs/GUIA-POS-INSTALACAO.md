# Proteção pós-instalação — fluxo legado desativado

`post-install-protect.sh` foi desativado em 2026-08-24. Ele copiava um DTB
wifi-fix obsoleto, criava entradas BLS duplicadas e restaurava
`pd_ignore_unused`, contrariando o contrato validado do sistema instalado.

Use:

- `setup-vivobook.sh` para configurar o sistema instalado;
- `rescue-installed-boot --repair` a partir do live USB para recuperar BLS,
  `custom.cfg`, DTB e GRUB;
- `tools/audit-stable-hardware.sh --post-reboot` depois de cada mudança de
  kernel ou boot.

## Verificação dos aceleradores

```bash
# Vulkan deve mostrar Turnip/Adreno, nunca Lavapipe
env -u DISPLAY -u WAYLAND_DISPLAY \
  VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
  vulkaninfo --summary

# A câmera inicia automaticamente após o display manager
systemctl status vivobook-camera.service
cam -l
cam -c 1 --capture=1 --stream role=still,width=1920,height=1080,pixelformat=XRGB8888

# CDSP online não prova inferência NPU — o verificador prova
cat /sys/class/remoteproc/remoteproc1/{name,state}
stat -c '%A %U:%G %n' /dev/fastrpc-cdsp
tools/npu-run ~/.local/share/vivobook-qnn/bin/python tools/verify-qnn-npu.py
```

Em 2026-08-24, GPU Vulkan, câmera RGB e inferência QNN/HTP passaram após
reboot. O último comando deve imprimir `PASS: inferencia HTP/NPU com fallback
de CPU desabilitado` e sair `0`; o verificador desabilita fallback CPU, então
um PASS por CPU é impossível. Sem o wrapper `tools/npu-run` ele imprime
`SKIP` e sai `2` — o `libQnnHtp.so` não conhece o SoC ID `635`/X1P42100 e o
override de `soc_id` é escopado por processo, nunca global.

Atualizações automáticas de kernel continuam desabilitadas. Um kernel novo só
deve ser mantido depois de validar fisicamente boot, Wi-Fi, áudio, teclado,
brilho e s2idle. O hook definitivo de `kernel-install` ainda é uma pendência
registrada em `BUILD-STATE.md`.
