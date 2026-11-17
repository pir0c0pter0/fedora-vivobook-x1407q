# Adreno X2-45 no Yoga 14Q8Y11

Validada em 17/11/2026 no `try` e no boot normal `current`. GNOME e
aplicativos do usuario usam Mesa 26.2.3 em `/opt/mesa-x2-45`: renderer
`Adreno (TM) X2-45`, OpenGL 4.6/GLES 3.2, direct rendering e accelerated=yes.
O Mesa do sistema permanece instalado.

O kernel fornece dois slices e 10,5 MiB de GMEM. A entrada de chip
`0xffff44060020` do patch passou nos testes EGL: triangulo verde sobre
fundo vermelho, pixels internos/externos exatos e GL error=0. Casos:
64x64, sysmem 1920x1200, gmem 1920x1200 e gmem 3840x2160.

**Limite de 310 MHz mantido:** speed-bin 193 ainda nao tem mapeamento
comprovado. `yoga-gpu-up` aplica o menor OPP antes da primeira abertura do
render node; nao foram alteradas tensoes nem liberados os demais OPPs.
Vulkan, Niri, desempenho e estabilidade prolongada ainda nao validados.
A confirmacao visual/interativa do GNOME pelo usuario ficou pendente;
os testes de renderer, contexto e pixels foram feitos por software.

## Instalacao usada

- `build-mesa-x2-45.sh`: build AArch64 em Fedora 45/QEMU no PC.
  Arquivo local `mesa-x2-45-26.2.3-aarch64.tar.xz`, SHA256
  `c5160dfc3f287ae1d2f53e665c8c5c770d595cbe23aeb097c0e6aa9ecf889d2f`.
- `mesa-x2-45-env` em `/usr/local/bin/`; `egl-offscreen-test.py` em
  `/usr/local/libexec/yoga-egl-test.py`; `yoga-gpu-up` em `/usr/local/sbin/`.
- `yoga-gpu.service` em `/etc/systemd/system/`, habilitado como dependencia
  fraca do audio. Requer `yoga.gpu=1` no slot e audio ativo.
- `90-yoga-mesa.conf` em `/etc/systemd/system/gdm.service.d/`.
  O GDM so inicia com GPU habilitada depois de o teste EGL passar.
  Nao adicionar Requires=GPU ao GDM: anteciparia audio/cameras antes da
  guarda PCIe/USB3.
- Symlink `/etc/environment.d/90-yoga-mesa.conf` para `/run/yoga-gpu.env`.
  O arquivo so existe depois do teste e tambem fornece ambiente ao GDM.

Nao houve mudanca de kernel, initramfs ou DT para a GPU. O DT continua
incluindo audio/DMIC e cameras. Apenas `3d00000.gpu` recebe bind em adreno;
o KMS existente nao e descarregado. GX/SMMU podem precisar de reprobe
depois de gpucc, por adiamento ja observado no boot.

## Evidencia e recuperacao

Boot normal 34,444 s; GNOME usa libgallium/EGL/GBM de `/opt`, abre o
renderD128 e o KMS card1. GLX executado pelo systemd do usuario passou
sem wrapper. Audio, SoCCP attached, ADSP running e WirePlumber com
NRestarts=0 preservados. O aviso de card0 sem modesetting e esperado:
esse dispositivo so renderiza; a tela usa card1.

23 testes de inicializacao e nove cenarios simulados do EGL passaram
em revisao independente. Logs privados em
`local/physical-2026-11-17/audio-gpu-npu/gpu-{render-tests,try-desktop,current-validation}.txt`.
Backup no Yoga: `/root/gpu-20261117/current-before/`. Para retornar ao
desktop por software, restaurar o args.cfg desse backup e reiniciar;
o arquivo de ambiente em /run desaparece no reboot. `good` esta intacto.
