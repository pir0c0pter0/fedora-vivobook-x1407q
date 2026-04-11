# CLAUDE.md — ASUS Vivobook X1407QA (Snapdragon X) Linux Fixes

## O que é este projeto

Fixes de hardware para rodar Fedora 44 aarch64 no ASUS Vivobook 14 X1407QA com Snapdragon X. Tudo feito em runtime — 6 módulos DKMS, 1 fix Vulkan (LD_PRELOAD), 1 PTY sync proxy, 1 extensão GNOME, 1 fix UCM2 áudio, 1 fix suspend/lid, 1 fix cpufreq, 1 fix CDSP/NPU, 1 fix charge control, 0 patches de kernel.

## Conquistas (19/19)

1. **Boot** — Custom ISO + Zenbook A14 DTB (mesmo die Qualcomm "Purwa")
2. **WiFi** — DKMS `wcn_regulator_fix` + board.bin (PCIe race condition + regulador)
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
13. **Lid close** — Suspend S3 crasha no Snapdragon X → desabilitado, tampa só desliga tela (logind lock + mask targets)
14. **cpufreq** — Módulo `scmi_cpufreq` in-tree autoload via `/etc/modules-load.d/` — CPU escala 710MHz–2.96GHz, governor schedutil
15. **CDSP/NPU** — Firmware `qccdsp8380.mbn` no initramfs via dracut — Hexagon Compute DSP online, fastrpc contexts disponíveis
16. **Charge control** — udev rule seta limite 80% via `charge_control_end_threshold` — firmware aceita escrita, start auto 50%
17. **Câmera RGB** — DKMS `vivobook_cam_fix` (DT overlay two-phase) — OV02C10 no CCI1, libcamera + Snapshot, on-demand via `vivobook-camera start`
18. **Claude Code flicker-free** — `sync_render` (PTY proxy com Mode 2026 synchronized output) — coalesce 5ms + render atômico, zero flicker no ARM/Wayland
19. **Display color control** — DKMS `vivobook_color_ctrl` (CTM via DRM atomic commit do kernel) — msm_dpu expõe CTM/PCC mas não GAMMA_LUT, wl-gammarelay-rs e zwlr_gamma_control falham, módulo kernel bypassa restrição de DRM master

## Regras — SEMPRE fazer

- **DKMS para hardware**: firmware INSYDE impede override de DTB. Todo fix de hardware = módulo kernel DKMS que corrige em runtime
- **initramfs para firmware**: firmware crítico (ADSP, GPU, WiFi) deve estar no initramfs via dracut — rootfs não está montado no early boot
- **Testar antes de commitar**: rodar o fix, verificar logs (`journalctl -b`), confirmar que funciona
- **Documentar causa raiz**: cada fix no README tem: Problema → Causa raiz → Solução → Tabela de propriedades
- **LD_PRELOAD para bugs de userspace**: quando o bug está em lib/driver de userspace (Mesa, GTK4), interceptar via LD_PRELOAD em vez de recompilar
- **Extensão GNOME para UI**: GNOME 50 no Wayland — extensões ESM modules, `shell-version: ["50", "50.rc"]`
- **Português direto**: respostas curtas, sem enrolação

## Regras — NUNCA fazer

- **NÃO tentar override de DTB** — 7 métodos testados (GRUB devicetree, BLS, dtbloader.efi, EFI stub), TODOS falharam no INSYDE
- **NÃO mudar GPIO5 DIG_OUT_SOURCE_CTL para 0x00** — mata a tela, requer reboot forçado
- **NÃO forçar GPIO5 output LOW** — mesmo efeito, mata a tela
- **NÃO usar `gpio_to_irq()`** — não funciona no Qualcomm TLMM, usar `irq_create_fwspec_mapping()`
- **NÃO usar `GSK_RENDERER=ngl` como fix definitivo** — é workaround. O fix real é `vk_pool_fix.so` que mantém Vulkan
- **NÃO atualizar kernel/mesa sem testar** — auto-updates desabilitados por motivo, cada update pode quebrar os módulos DKMS

## Padrões técnicos

| Área | Padrão |
|------|--------|
| Módulos kernel | DKMS em `/usr/src/<nome>-1.0/`, auto-load via `/etc/modules-load.d/` |
| Firmware | initramfs via `/etc/dracut.conf.d/`, depois `sudo dracut --force` |
| Vulkan fix | LD_PRELOAD em `/usr/local/lib64/` + `VK_DRIVER_FILES` via `~/.config/environment.d/` — MR 37622 corrige device select mas LVP ainda carrega sem o override, degradando rendering |
| Terminal sync | `sync_render` PTY proxy em `/usr/local/bin/`, Mode 2026 synchronized output |
| Extensão GNOME | `~/.local/share/gnome-shell/extensions/<uuid>/`, ESM modules, GNOME 50 |
| GRUB | Entry custom em `/etc/grub.d/08_vivobook` com `clk_ignore_unused pd_ignore_unused` |
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
| Câmera RGB | OV02C10 × 2 (OmniVision, 2MP), CCI1, I2C 0x36, CSIPHY4, MCLK4 19.2MHz |
| Câmera IR | Hynix HM1092 (Windows Hello), ACPI QCOM0C99 (Spectra 695 ISP Aux Sensor), MCLK0 GPIO 96, reset GPIO 109, bus TBD |

## TODO

- **Câmera IR (HM1092)** — Phase 1 discovery concluída em 2026-04-11 via Qualcomm SOC driver package (não BIOS). Sensor confirmado: Hynix HM1092, binding Asus Purwa = `SUBSYS_13041043&REV_0001` → `CameraAuxSensor_Device_QRD_Pw`, AVDD=pm8010 LDO7_M (2.91V), DOVDD=pm8010 LDO4_M (1.82V), MCLK0 GPIO 96, reset GPIO 109, AosShareResource=0 (sem AOS sharing). Bloqueio: pm8010 ausente no SPMI scan mas Windows usa LDO4_M/LDO7_M → duas hipóteses (pm8010 dormente no DT Zenbook A14 vs fisicamente ausente). Próximo passo = habilitar pm8010 no DT overlay como teste empírico (Checkpoint A = YELLOW). Findings em `docs/research/2026-04-11-ir-camera-discovery.md`.
- **RGB cpas_ahb patch regrediu no 6.19.10** — kernel bumpou 6.19.8 → 6.19.10 e perdemos o patch `qcom_camss` que suprimia `cam_cc_pll8/Lucid PLL/cam_cc_slow_ahb_clk_src` warnings. Frame capture ainda funciona, só warnings cosmético. Fix = rebuild do patch pra 6.19.10 em `/lib/modules/6.19.10-300.fc44.aarch64/updates/`.
- **1 device I2C desconhecido** — bus 4: 0x5b respondendo (0x43 e 0x76 não responderam no scan). Pode ser PS8833 (USB retimer) já mapeado no DTB.
- **UCM2 upstream** — PR para alsa-ucm-conf adicionando Vivobook 14 ao regex
- **Mesa issue #15106** — Aberto e fechado: device select via MR 37622 funciona no Mesa 25.3.6, mas LVP ainda é carregado sem `VK_DRIVER_FILES`, degradando rendering. `VK_DRIVER_FILES` mantido no setup. https://gitlab.freedesktop.org/mesa/mesa/-/issues/15106
