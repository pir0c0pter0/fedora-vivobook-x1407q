# Estado da construção personalizada

Última atualização: **2026-08-24**

## Estado atual

- Linux `7.2.0-x1407qa` foi reconstruído do zero para AArch64 e verificado.
- Quatro correções locais foram compiladas para o kernel final e integradas ao
  live/initramfs: reguladores do WCN6855, teclado I2C-HID, backlight PMK8550 e
  hotkeys ASUS.
- O firmware necessário de ADSP, CDSP, GPU e Wi-Fi é selecionado por um
  manifesto SHA-256 determinístico de 16 arquivos.
- O instalador live aceita o caminho EROFS exposto por
  `/run/initramfs/livedev`.
- A entrada principal copia o live integralmente para RAM quando há pelo menos
  4 GiB disponíveis; existe fallback explícito que continua usando o USB.
- O ADSP, necessário para battery manager, só é iniciado depois que o live da
  entrada principal já está seguro em RAM. Isso evita desconectar a mídia cedo.
- O backup completo dos drivers Windows está ultracomprimido no repositório,
  mas não foi incluído na ISO. A ISO contém apenas os arquivos usados.
- O primeiro teste físico da imagem anterior confirmou boot, teclado e
  Bluetooth, mas encontrou quatro regressões: Wi-Fi ausente, tethering USB/PAN
  indisponível, `sudo` sem proprietário/modo corretos e instalador interrompido.
- O Wi-Fi falhava porque `wcn_regulator_fix` era carregado antes de
  `pwrseq_qcom_wcn`; o novo kernel/initramfs força a sequência correta.
- O kernel agora inclui `rndis_host`, `cdc_ether`, `cdc_ncm` e `bnep` como
  módulos para compartilhamento de internet por USB ou Bluetooth.
- A reconstrução do rootfs preserva permissões, executa `rpm --restore -a` e
  bloqueia a ISO se `/usr/bin/sudo` não for `root` e setuid. A auditoria do
  EROFS final confirmou UID/GID `0/0` e modo `4111`.
- Os firmwares GPU `qcom/gen71500_sqe.fw` e `qcom/gen71500_gmu.bin` passaram a
  ser exigidos no rootfs e no initramfs.
- A ISO final foi auditada, gravada no Kingston, relida integralmente com
  SHA-256 idêntico e ejetada/desligada com segurança.
- O primeiro teste físico da ISO anterior instalou, mas o sistema instalado não
  bootava: o GRUB acusava `invalid environment block` e as únicas entradas BLS
  do rootfs eram herdadas da imagem kiwi da Fedora, apontando para caminhos
  `/root/var/lib/mock/...` inexistentes, sem entrada para o kernel 7.2 e sem
  linha `devicetree`.
- Fix: `tools/make-rootfs-installable.sh` (chamado pelos dois builders) remove
  as entradas kiwi, grava `grubenv` válido de 1024 bytes, copia o DTB para
  `/boot/dtb-x1407qa/` e instala
  `/usr/share/anaconda/post-scripts/90-x1407qa-bootloader.ks`, que no fim da
  instalação cria a entrada BLS do 7.2 com `devicetree`, `root=` real do
  `/etc/fstab` e os parâmetros Snapdragon, e recria o grubenv com
  `grub2-editenv`. Regressões cobertas em `tests/test-build-regressions.sh`.
- **2026-08-20, novo teste físico: instalou e o sistema instalado ainda não
  boota, sem erro visível na tela.** Causa raiz CONFIRMADA pelo relatório do
  kit de resgate rodado no notebook: **no Anaconda do Fedora 44 a função
  `appendPostScripts()` (pyanaconda/kickstart.py:332) existe mas não tem
  nenhum chamador — é código morto**. O post-script
  `90-x1407qa-bootloader.ks` nunca rodou (zero `ks-script-*.log`); o Anaconda
  regenerou entradas BLS próprias (`Regenerating BLS info`, para 6.19.10 e
  7.2.0) **sem linha `devicetree`**, então o kernel instalado boota sem DTB:
  tela preta, sem erro visível. Layout real do disco: raiz btrfs
  `nvme0n1p3` (subvol=root), `/boot` ext4 `nvme0n1p2`
  (UUID 2f7fdc97-dc6b-4657-a4a0-da3152249881), ESP `nvme0n1p1`; NVRAM tem
  entrada Fedora; Secure Boot inativo.
- Primeiro `--repair` no notebook gravou no lugar errado: o GNOME Files tinha
  automontado `nvme0n1p2` em `/run/media/liveuser/…`, o mount do script
  falhou e os reparos caíram no `/boot` vazio do subvol raiz. O script agora
  faz `umount -A` das partições internas antes de montar (correção no repo;
  o live gravado ainda tem a versão antiga — contornar com `umount` manual).
- **Próximo passo estrutural para ISOs futuras**: abandonar o mecanismo
  post-scripts do Anaconda. Candidato preferido: drop-in
  `/etc/kernel/install.d/95-x1407qa-devicetree.install` no rootfs — o
  Anaconda executa `kernel-install` no chroot (`Regenerating BLS info`), e o
  plugin injetaria a linha `devicetree` na entrada BLS gerada; também cobre
  atualizações de kernel futuras. O fallback `custom.cfg` do post-script
  sofre do mesmo problema (nunca roda) e deve migrar junto.
  Ferramentas criadas:
  - `tools/rescue-installed-boot.sh` — rodar como root no live USB. Sem
    argumentos: monta o sistema instalado read-only, audita ESP/NVRAM/BLS/
    grubenv/Secure Boot e extrai os logs do Anaconda para
    `/run/x1407qa-rescue/report`. Com `--repair`: recria a entrada BLS, grava
    entrada direta com `devicetree` em `/boot/grub2/custom.cfg` (mesmo método
    comprovado do GRUB do live — o blscfg do grubaa64.efi suporta `devicetree`
    em BLS, confirmado por strings em `bls_get_devicetree`, mas nunca foi
    provado neste firmware a partir do disco), corrige o grubenv e cria o
    fallback `\EFI\BOOT\BOOTAA64.EFI` + entrada NVRAM se faltarem.
  - O post-script do Anaconda agora também gera o `custom.cfg` de fallback em
    instalações futuras (UUID via `findmnt`).

## 2026-08-24 — Sistema instalado boota; s2idle e áudio validados

- **O sistema instalado boota do NVMe** via entrada BLS
  `x1407qa-7.2.0-x1407qa` **com linha `devicetree`** — o mecanismo blscfg do
  `grubaa64.efi`, até então nunca provado neste firmware a partir do disco,
  está comprovado fisicamente.
- **s2idle validado** (deep continua proibido — crasha, não mudar): 2 ciclos
  suspend/resume limpos (`PM: suspend entry (s2idle)` → exit),
  WiFi/BT/teclado/áudio ok após resume. Consumo suspenso: 0.368Wh em
  27.7min = **~0.80W** (baseline idle ligado: 2.85W).
- **Áudio consertado no instalado** — estava morto por 3 causas empilhadas:
  1. Kernel custom sem `CONFIG_FW_LOADER_COMPRESS`/`_XZ` → não carrega
     `qcom/x1e80100/X1E80100-ASUS-Zenbook-A14-tplg.bin.xz` (só existe `.xz`
     no linux-firmware). Fix local: `xz -dk` do arquivo.
  2. `snd_soc_wcd938x` não autocarregou no boot (race; modalias correto) →
     `/etc/modules-load.d/vivobook-audio.conf` com `snd_soc_wcd938x`.
  3. Regex UCM2 sem "Vivobook 14" (fix da conquista 12 não tinha sido
     aplicado no instalado) → mesmo `sed` do step 12 do `setup-vivobook.sh`.
- **Persistências aplicadas na máquina**: `mem_sleep_default=s2idle` no
  cmdline (BLS + `custom.cfg`);
  `/etc/systemd/logind.conf.d/no-suspend.conf` com `HandleLidSwitch=suspend`
  (3 variantes) + `IdleAction=ignore`; `sleep.target` e `suspend.target`
  desmascarados (`hibernate.target`, `hybrid-sleep.target` e
  `suspend-then-hibernate.target` continuam masked — sem swap);
  `modules-load.d` do áudio; tplg descomprimido.
- O RTC pm8xxx não tem alarme (sem `wakealarm`) — acordar é sempre por
  botão/tampa.
- **Reboot físico validado**: áudio autocarregou sem erros SoundWire, o cmdline
  contém `mem_sleep_default=s2idle`, `[s2idle]` ficou selecionado e a auditoria
  final passou 16/16 no notebook.
- **Plano CPU/bateria, Fases 0–4**: Runtime PM PCIe não trouxe ganho e não foi
  persistido; `pd_ignore_unused` foi removido do sistema instalado com 16/16
  PASS (~0.1–0.2W de ganho), enquanto `clk_ignore_unused` continua obrigatório
  para o PCIe/Wi-Fi; o cap automático de CPU foi validado em 2.3808GHz na
  bateria e 2.9568GHz no AC/USB. O repo agora reproduz esse contrato no setup,
  BLS e `custom.cfg`; o live USB mantém pd+clk por segurança.

## 2026-08-24 — GPU Vulkan, câmera RGB e CDSP/NPU

- **GPU pronta:** após o segundo reboot limpo, `vulkaninfo --summary` confirmou
  Vulkan 1.4.341, Mesa 26.0.3, `turnip Mesa driver` e Adreno X1-45. O setup fixa o
  ICD Freedreno em `~/.config/environment.d/vulkan-hardware.conf` para impedir
  que Lavapipe seja carregado junto.
- **Câmera RGB pronta com autostart gráfico tardio:** o setup instala as
  ferramentas e plugins
  libcamera/PipeWire, o tuning `ov02c10.yaml`, uma regra uaccess apenas para o
  DMA heap `system`, e habilita o serviço em `graphical.target`, após módulos
  core e display manager, para carregar `system_heap` antes da pilha CAMSS.
  Após reboot: still XRGB8888 1920×1080 (8.294.400 bytes) e vídeo XRGB8888
  1280×720 com 60/60 frames a ~30 fps; o serviço ficou `enabled/active`, a
  fonte PipeWire foi publicada e teclado/touchpad registraram antes do overlay.
  `stop` não descarrega módulos e o unload seguro é reboot. Com o kernel 7.2
  construído com `kernel/linux-7.2-camera-warning-fix.patch` e o libcamera
  patchado (`0.7.1-1.fc44.x1407qa`), os avisos de propriedades/helper e de
  clocks CAMCC deixaram de aparecer; a imagem sai na orientação correta porque
  `rotation = <180>` faz o libcamera dirigir `HFLIP`/`VFLIP` do sensor. Não
  houve Oops/soft lockup e as capturas concluíram.
- **Estado global atual:** auditoria estável 16/16; boot total de 7.301s
  (3.325s userspace, `graphical.target` em 3.278s e comandos do módulo da
  câmera em 112ms). O
  instalado desativa zram/Plymouth pelo cmdline; o live principal conserva
  `rd.live.ram`. O kernel 7.2 inclui nftables e o helper conntrack NetBIOS;
  `firewalld` foi validado `active/running` em 2026-08-24.
- **Build ARM:** o builder principal e o fallback do setup usam `nproc`,
  aproveitando todos os vCPUs que o WSL2 expõe sem um limite fixo em `-j8`.
- **CDSP pronto, NPU parcial:** ADSP e CDSP estão `running`; somente
  `/dev/fastrpc-cdsp` não seguro é exposto em `root:render 0660`. Os nós secure
  e ADSP permanecem `root:root 0600`. `onnxruntime-qnn 2.4.0` registra o
  `QNNExecutionProvider` como NPU, mas uma inferência HTP com fallback CPU
  desabilitado falha em `QNN_BACKEND_ERROR_CANNOT_INITIALIZE` no SoC real ID
  `635`/X1P42100, inclusive como root. Portanto não é bloqueio de permissão e
  CDSP online não deve ser documentado como inferência NPU funcional.
- Contratos reproduzíveis: `tests/test-accelerator-runtime.sh` valida os
  arquivos instalados e `tools/verify-qnn-npu.py` impede falso positivo por CPU.

## ISO final

Reempacotada em 20/08 (tarde) via `tools/resume-personal-iso-repack.sh` dentro
de `podman unshare` (o rootfs extraído usa o mapeamento subuid
`mariostjr:524288`; fora do namespace os UIDs aparecem deslocados e o
empacotamento gravaria donos errados). Novidades desta imagem: post-script do
Anaconda com fallback `custom.cfg` e kit de resgate embutido no live em
`/usr/local/bin/rescue-installed-boot` (instalado via symlink `sbin -> bin`).
`fsck.erofs` limpo.

```text
Nome: Fedora-44-X1407QA-Linux-7.2-hardware-ram.iso
Tamanho: 4.667.998.208 bytes
SHA-256: af7a230eebfa803f1d5400158ba16cae58031964d7204cbd18404e0ca7866398
```

Checksum: `Fedora-44-X1407QA-Linux-7.2-hardware-ram.iso.sha256`. A imagem
anterior (072c715d…) foi substituída; hash preservado aqui como histórico.

## Backup dos drivers Windows

```text
Nome: windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst
Tamanho comprimido: 835.731.061 bytes
Tamanho descomprimido validado: 5.324.103.680 bytes
SHA-256: 43fe0b6fd8a0336bd1d9ef02147bd2e2af09ca6d2d41895c20c7d34609716cd4
```

Por usar janela longa do Zstandard, teste com:

```bash
zstd --long=31 -t windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst
```

## Pendente

- **Ciclo de vida da câmera:** `vivobook-camera.service` está habilitado para
  `graphical.target` e mantém `ExecStop=/bin/true`. `systemctl stop` só muda o
  estado da unit para `inactive`; `vivobook_cam_fix`, `qcom_camss`, `ov02c10`,
  CAMCC e os device nodes continuam carregados. **Não testar `rmmod`**:
  tentativas anteriores corromperam o estado GDSC do CAMCC, causaram
  crash/soft-lockup e travaram shutdown. O único unload conhecido como seguro
  é reboot; não substituir o no-op de `ExecStop` por `modprobe -r`.
- Remover `x1407qa-fallback-fase2.conf` do notebook somente depois de soak
  suficiente da entry principal sem `pd_ignore_unused`.
- Substituir o post-script morto do Anaconda pelo hook de `kernel-install`
  antes de considerar uma instalação futura automaticamente bootável.
- O percentual da bateria no live continua uma pendência separada e não deve
  ser considerado corrigido até o teste físico.
- Revalidar QNN/HTP quando houver runtime Qualcomm que reconheça oficialmente
  X1P42100/SoC ID 635; não persistir `soc_model`/`htp_arch` falsos.

Consulte [`docs/BUILD-REPORT-2026-08-24.md`](docs/BUILD-REPORT-2026-08-24.md)
para a memória completa desta execução. Os relatórios anteriores foram
preservados como histórico e não descrevem o estado atual.
