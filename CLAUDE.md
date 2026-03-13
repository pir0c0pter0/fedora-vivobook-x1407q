# CLAUDE.md — ASUS Vivobook X1407QA (Snapdragon X) Linux Fixes

## O que é este projeto

Fixes de hardware para rodar Fedora 44 aarch64 no ASUS Vivobook 14 X1407QA com Snapdragon X. Tudo feito em runtime — 5 módulos DKMS, 1 fix Vulkan (LD_PRELOAD), 1 extensão GNOME, 1 fix UCM2 áudio, 0 patches de kernel.

## Conquistas (12/12)

1. **Boot** — Custom ISO + Zenbook A14 DTB (mesmo die Qualcomm "Purwa")
2. **WiFi** — DKMS `wcn_regulator_fix` + board.bin (PCIe race condition + regulador)
3. **Teclado** — DKMS `vivobook_kbd_fix` (bus i2c diferente do Zenbook: b94000:0x3a)
4. **Bateria** — Firmware ADSP no initramfs (qcom-battmgr falhava no early boot)
5. **Brilho** — DKMS `vivobook_bl_fix` (PWM via PMIC PMK8550 LPG → DTEST3 → GPIO5)
6. **Hotkeys Fn** — DKMS `vivobook_hotkey_fix` (init ASUS vendor HID + key mapping)
7. **GPU** — 4 firmwares no initramfs (ZAP shader MDT loader não faz retry)
8. **Boot 1:47→8s** — Mask TPM fantasma + limpeza initrd
9. **Terminal flicker** — `vk_pool_fix.so` (LD_PRELOAD que aumenta pool Vulkan 50x)
10. **Tempo bateria** — Extensão GNOME `battery-time@wifiteste` (média ponderada)
11. **Touchpad botão direito** — gsettings `click-method: areas` (clickpad só reporta BTN_LEFT)
12. **Áudio** — UCM2 regex fix (Vivobook 14 não estava no match do alsa-ucm-conf)

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
| Vulkan fix | LD_PRELOAD em `/usr/local/lib64/`, desktop entry override em `~/.local/share/applications/` |
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

## TODO

- **Câmera** — Sem driver
- **3 devices I2C desconhecidos** — bus 4: 0x43, 0x5b, 0x76
- **UCM2 upstream** — PR para alsa-ucm-conf adicionando Vivobook 14 ao regex
