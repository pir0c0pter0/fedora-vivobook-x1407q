# CLAUDE.md — ASUS Vivobook X1407QA (Snapdragon X) Linux Fixes

## O que é este projeto

Fixes de hardware para rodar Fedora 44 aarch64 no ASUS Vivobook 14 X1407QA com Snapdragon X. A maior parte roda em runtime — 7 módulos DKMS, 1 patch `qcom-camss` histórico não instalado pelo setup, 1 fix Vulkan (LD_PRELOAD + ICD Turnip), 1 extensão GNOME, 1 fix UCM2 áudio, 1 fix suspend/lid, 1 fix cpufreq, 1 fix CDSP/FastRPC e 1 fix charge control; o sistema estável atual usa kernel custom 7.2.

## Conquistas (18 itens; NPU parcial)

1. **Boot** — Custom ISO + Zenbook A14 DTB (mesmo die Qualcomm "Purwa")
2. **WiFi** — `pwrseq_qcom_wcn` nativo + `wlanfw20.mbn` como `amss.bin` + board data `NFA765a_AS_SA_X14QA` (corrige MHI `-110` no Linux 7.2)
3. **Teclado** — DKMS `vivobook_kbd_fix` (bus i2c diferente do Zenbook: b94000:0x3a)
4. **Bateria** — Firmware ADSP no initramfs (qcom-battmgr falhava no early boot)
5. **Brilho** — DKMS `vivobook_bl_fix` (PWM via PMIC PMK8550 LPG → DTEST3 → GPIO5)
6. **Hotkeys Fn** — DKMS `vivobook_hotkey_fix` (init ASUS vendor HID + key mapping)
7. **GPU** — 3 firmwares no initramfs (probe 375ms antes do switchroot, msm.ko não declara MODULE_FIRMWARE; ZAP shader `qcdxkmsucpurwa.mbn` referenciado pelo DTB Zenbook A14)
8. **Boot 1:47→8s** — Mask TPM fantasma + limpeza initrd
9. **Terminal flicker** — `vk_pool_fix.so` (LD_PRELOAD pool Vulkan 200x) + `VK_DRIVER_FILES` (força turnip hardware, Niri usa Lavapipe sem isso)
10. **Tempo bateria** — Extensão GNOME `battery-time@wifiteste` (média ponderada)
11. **Touchpad botão direito** — gsettings `click-method: areas` (clickpad só reporta BTN_LEFT)
12. **Áudio** — UCM2 regex fix (Vivobook 14 não estava no match do alsa-ucm-conf)
13. **Lid close** — tampa suspende via s2idle (~0.80W validado); deep/S3 crasha e continua desabilitado; família hibernate mascarada
14. **cpufreq** — Módulo `scmi_cpufreq` in-tree autoload via `/etc/modules-load.d/` — CPU escala 710MHz–2.96GHz, governor schedutil
15. **CDSP/FastRPC** — Firmware `qccdsp8380.mbn` no initramfs; CDSP online e nó não seguro em `root:render 0660`. QNN registra a NPU, mas HTP inference está bloqueada no backend Qualcomm para SoC ID 635/X1P42100
16. **Charge control** — udev rule seta limite 80% via `charge_control_end_threshold` — firmware aceita escrita, start auto 50%
17. **Câmera RGB** — DKMS `vivobook_cam_fix` (DT overlay two-phase), `system_heap` e tuning OV02C10 — autostart gráfico tardio, libcamera/Snapshot, still 1080p e vídeo 720p30
18. **Display color control** — DKMS `vivobook_color_ctrl` (CTM via DRM atomic commit do kernel) — msm_dpu expõe CTM/PCC mas não GAMMA_LUT, wl-gammarelay-rs e zwlr_gamma_control falham, módulo kernel bypassa restrição de DRM master

## Regras — SEMPRE fazer

- **DKMS para diferenças do modelo**: o BLS carrega o DTB base do Zenbook A14, mas não existe DTB upstream do Vivobook; corrigir diferenças específicas em runtime até upstream
- **initramfs para firmware**: firmware crítico (ADSP, GPU, WiFi) deve estar no initramfs via dracut — rootfs não está montado no early boot
- **Testar antes de commitar**: rodar o fix, verificar logs (`journalctl -b`), confirmar que funciona
- **Documentar causa raiz**: cada fix no README tem: Problema → Causa raiz → Solução → Tabela de propriedades
- **LD_PRELOAD para bugs de userspace**: quando o bug está em lib/driver de userspace (Mesa, GTK4), interceptar via LD_PRELOAD em vez de recompilar
- **Extensão GNOME para UI**: GNOME 50 no Wayland — extensões ESM modules, `shell-version: ["50", "50.rc"]`
- **Português direto**: respostas curtas, sem enrolação

## Regras — NUNCA fazer

- **NÃO substituir o caminho BLS/DTB comprovado** — `devicetree` em BLS funciona no instalado 7.2; não repetir os loaders EFI alternativos que falharam nem usar DTB não auditado
- **NÃO mudar GPIO5 DIG_OUT_SOURCE_CTL para 0x00** — mata a tela, requer reboot forçado
- **NÃO forçar GPIO5 output LOW** — mesmo efeito, mata a tela
- **NÃO usar `gpio_to_irq()`** — não funciona no Qualcomm TLMM, usar `irq_create_fwspec_mapping()`
- **NÃO usar `GSK_RENDERER=ngl` como fix definitivo** — é workaround. O fix real é `vk_pool_fix.so` que mantém Vulkan
- **NÃO usar `post-install-protect.sh`** — legado desativado; criava BLS duplicado e restaurava `pd_ignore_unused`
- **NÃO atualizar kernel/mesa sem testar** — auto-updates desabilitados por motivo, cada update pode quebrar os módulos DKMS

## Padrões técnicos

| Área | Padrão |
|------|--------|
| Módulos kernel | DKMS em `/usr/src/<nome>-1.0/`, auto-load via `/etc/modules-load.d/` |
| Firmware | initramfs via `/etc/dracut.conf.d/`, depois `sudo dracut --force` |
| Vulkan fix | LD_PRELOAD em `/usr/local/lib64/` + `VK_DRIVER_FILES` via `~/.config/environment.d/` — MR 37622 corrige device select mas LVP ainda carrega sem o override, degradando rendering |
| FastRPC | Expor somente `/dev/fastrpc-cdsp` não seguro ao grupo `render`; nunca relaxar permissões dos nós secure/ADSP |
| Câmera | `vivobook-camera.service` habilitado em `graphical.target`, após módulos core e display manager; carrega `system_heap`; instala `/usr/share/libcamera/ipa/simple/ov02c10.yaml`; nunca adicionar em `modules-load.d` nem usar `rmmod` |
| Extensão GNOME | `~/.local/share/gnome-shell/extensions/<uuid>/`, ESM modules, GNOME 50 |
| GRUB instalado | BLS + `custom.cfg` com `clk_ignore_unused mem_sleep_default=s2idle`; sem `pd_ignore_unused` |
| Bateria sysfs | `/sys/class/power_supply/qcom-battmgr-bat/` (energy_now, power_now em µW) |
| UCM2 áudio | `/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf` — regex DMI matching |

## Hardware chave

| Item | Detalhe |
|------|---------|
| SoC | Snapdragon X X1-26-100, die "Purwa" (x1p42100) |
| GPU | Adreno X1-45, driver freedreno/turnip (Mesa) |
| WiFi | WCN6855 hw2.1, ath11k_pci, PCI 17cb:1103 |
| Teclado | I2C HID, bus 4 (b94000), addr 0x3a, VID 0x0b05 PID 0x4543, IRQ GPIO 67 |
| Brilho | PMK8550 LPG ch0 → DTEST3 → GPIO5, 12-bit PWM (4096 níveis) |
| Bateria | X321-42 50Wh, driver qcom_battmgr via pmic_glink |
| Painel | Samsung ATANA33XC20, eDP, 1920x1200@60Hz |
| Áudio codec | WCD938x (WCD9385) via SoundWire |
| Áudio speakers | WSA884x × 2 via SoundWire |
| Áudio DSP | ADSP via Q6APM, LPASS macros (rx, tx, wsa, va) |
| Câmera RGB | 1× OV02C10 (OmniVision, 2MP), CCI1, I2C 0x36, CSIPHY4, MCLK4 19.2MHz |
| Câmera IR | Hynix HM1092 (Windows Hello), ACPI QCOM0C99 (Spectra 695 ISP Aux Sensor), MCLK0 GPIO 96, reset GPIO 109, bus TBD |

## TODO

- **Câmera IR (HM1092)** — sensor e binding Asus Purwa confirmados via pacote Qualcomm; AVDD/DOVDD dependem do pm8010, ausente no SPMI e sem resposta física aos testes RPMH. Continua bloqueada; não habilitar ou testar durante o trabalho da RGB. Findings em `docs/research/2026-04-11-ir-camera-discovery.md` e `docs/research/CAMERA_STATUS.md`.
- **NPU QNN/HTP** — `onnxruntime-qnn 2.4.0` registra a NPU, mas o backend falha em inicializar no SoC real ID 635/X1P42100 mesmo como root e sem fallback CPU. Revalidar `tools/verify-qnn-npu.py` quando a Qualcomm publicar runtime compatível; não persistir spoof de SoC.
- **Warnings da câmera no kernel 7.2** — RESOLVIDO em 2026-08-24. `kernel/linux-7.2-camera-warning-fix.patch` (aplicado sempre por `kernel/build-linux-7.2-x1407qa.sh`) adiciona `.get_selection` ao `ov02c10` e pula o voto de `cpas_ahb` no camss x1e80100; `libcamera/libcamera-0.7.1-ov02c10.patch` registra o sensor no libcamera (RPM `0.7.1-1.fc44.x1407qa`). Boot limpo, sem `cam_cc_*` nem aviso de static properties.
- **Orientação da câmera RGB** — o sensor é montado 180°. `rotation = <180>` no overlay é obrigatório: o libcamera só dirige `HFLIP`/`VFLIP` do OV02C10 quando o DT declara isso. Trocar para `<0>` cala um aviso e devolve a imagem de ponta cabeça.
- **Validação do autostart da câmera (2026-08-24)** — reboot físico com serviço `enabled/active`; teclado e touchpad registraram antes do overlay, auditoria 16/16, still 1080p, vídeo 60/60 em 720p30 e fonte PipeWire `Built-in Front Camera`; sem Oops/soft lockup.
- **Estado global atual** — `systemd-analyze` = 7.301s total (3.325s userspace; `graphical.target` em 3.278s; comandos do módulo da câmera = 112ms). O instalado usa `systemd.zram=0 plymouth.enable=0`; `rd.live.ram` continua exclusivo do live principal. O firewall foi corrigido no kernel 7.2 com nftables + helper conntrack NetBIOS e validado `active/running` em 2026-08-24; não restaurar o config sem esses módulos.
- **1 device I2C desconhecido** — bus 4: 0x5b respondendo (0x43 e 0x76 não responderam no scan). Pode ser PS8833 (USB retimer) já mapeado no DTB.
- **UCM2 upstream** — PR para alsa-ucm-conf adicionando Vivobook 14 ao regex
- **Mesa issue #15106** — Aberto e fechado: device select via MR 37622 funciona no Mesa 25.3.6, mas LVP ainda é carregado sem `VK_DRIVER_FILES`, degradando rendering. `VK_DRIVER_FILES` mantido no setup. https://gitlab.freedesktop.org/mesa/mesa/-/issues/15106
