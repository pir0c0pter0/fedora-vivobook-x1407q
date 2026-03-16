# Brightness Research — ASUS Vivobook 14 X1407QA

## Painel

| Propriedade | Valor |
|-------------|-------|
| **Modelo** | Innolux N140JCA-ELK (14" IPS LCD, 1920x1200) |
| **Conexão** | eDP via displayport-controller@aea0000 |
| **Driver kernel** | `panel_samsung_atna33xc20` (fallback genérico do DTB Zenbook A14) |
| **DRM connector** | card1-eDP-1 (connector_id=39) |
| **DP AUX device** | `/dev/drm_dp_aux2` |

## DPCD Capabilities (eDP)

Registros lidos de `/dev/drm_dp_aux2`:

| Offset | Nome | Valor | Significado |
|--------|------|-------|-------------|
| 0x700 | EDP_DPCD_REV | 0x01 | eDP 1.2 |
| 0x701 | EDP_GENERAL_CAP_1 | 0x02 | bit 1 = `BACKLIGHT_PIN_ENABLE_CAP` (backlight on/off via GPIO) |
| 0x702 | EDP_BACKLIGHT_ADJUSTMENT_CAP | 0x01 | bit 0 = `BACKLIGHT_BRIGHTNESS_PWM_PIN_CAP` (brilho via PWM externo) |
| 0x720 | DISPLAY_CONTROL_REGISTER | 0x00 | (default) |
| 0x721 | BACKLIGHT_MODE_SET_REGISTER | 0x00 | (default = PWM pin mode) |
| 0x722 | BACKLIGHT_BRIGHTNESS_MSB | 0x00 | |
| 0x723 | BACKLIGHT_BRIGHTNESS_LSB | 0x00 | |
| 0x724 | PWMGEN_BIT_COUNT | 0x00 | |
| 0x727 | BACKLIGHT_CONTROL_STATUS | 0x01 | |

### Bits importantes de 0x701

```
Bit 0: DP_EDP_TCON_BACKLIGHT_ADJUSTMENT_CAP = 0  → TCON NÃO ajusta backlight
Bit 1: DP_EDP_BACKLIGHT_PIN_ENABLE_CAP      = 1  → Backlight enable via pino GPIO
Bit 2: DP_EDP_BACKLIGHT_AUX_ENABLE_CAP      = 0  → NÃO suporta enable via AUX
```

### Bits importantes de 0x702

```
Bit 0: DP_EDP_BACKLIGHT_BRIGHTNESS_PWM_PIN_CAP = 1  → Brilho via PWM pin externo
Bit 1: DP_EDP_BACKLIGHT_BRIGHTNESS_AUX_SET_CAP = 0  → NÃO suporta brilho via AUX/DPCD
```

### Conclusão DPCD

O painel **não suporta controle de brilho via DPCD/AUX**. Brilho é controlado via **PWM pin externo** do SoC/PMIC.

## Backlight Enable GPIO

| Propriedade | Valor |
|-------------|-------|
| **PMIC** | PMC8380_3 (pmic@3) |
| **GPIO** | gpio4 |
| **Estado** | `out high normal vin-1 push-pull medium` |
| **DT alias** | `edp_bl_en` |
| **DT node** | `/soc@0/arbiter@c400000/spmi@c42d000/pmic@3/gpio@8800/edp-bl-en-state` |

O GPIO4 do PMC8380_3 está HIGH = backlight ligado. É só enable on/off, não controla brilho.

## PWM (PMIC LPG) — Status

Ambos os PWMs do PMIC estão **disabled** no DTB:

```
pmk8550_pwm (pmic@0): compatible = "qcom,pmk8550-pwm", status = "disabled"
pm8550_pwm  (pmic@1): compatible = "qcom,pm8550-pwm", "qcom,pm8350c-pwm", status = "disabled"
```

- Nenhum `pwmchip*` registrado em `/sys/devices/`
- Módulo `leds-qcom-lpg` disponível mas não carregado (DT node disabled)
- LPG channels esperados em SPMI registers 0xE100-0xE400

## Kernel Config Relevante

```
CONFIG_BACKLIGHT_PWM=m           (pwm_bl.ko)
CONFIG_BACKLIGHT_QCOM_WLED=m     (qcom-wled.ko)
CONFIG_BACKLIGHT_GPIO=m          (gpio_backlight.ko)
CONFIG_OF_DYNAMIC=y
CONFIG_OF_OVERLAY=y
```

## Testes Realizados

### TESTE 1 — DPCD BLACK VIDEO (ACIDENTAL)

**O que fiz:** Escrevi 0x02 em 0x720 + 0xFF em 0x721

**O que aconteceu:** Tela preta, backlight no máximo, precisou force power off

**Por quê:** 0x720 bit 1 = `DP_EDP_BLACK_VIDEO_ENABLE` — ativei o modo "vídeo preto" por engano. Eu achava que 0x720 era o registro de modo e 0x721 era o brilho, mas na verdade:
- 0x720 = Display Control (backlight enable, BLACK VIDEO, etc.)
- 0x721 = Backlight Mode (PWM/PRESET/DPCD)
- 0x722 = Brightness MSB
- 0x723 = Brightness LSB

### TESTE 2 — Só brightness MSB (seguro)

**O que fiz:** Escrevi 0x08 em 0x722, sem tocar em 0x720/0x721

**Resultado:** Nenhum efeito visual. Rollback automático 15s OK.

**Conclusão:** Sem ativar modo DPCD em 0x721, o registro de brilho é ignorado.

### TESTE 3 — Enable + DPCD mode + brightness

**O que fiz:** 0x720=0x01 (BACKLIGHT_ENABLE sem BLACK_VIDEO), 0x721=0x02 (DPCD mode), 0x722=0x10

**Resultado:** Nenhum efeito visual. Tela ficou normal. Rollback automático 15s OK.

**Conclusão:** Painel genuinamente NÃO suporta brilho via DPCD. Consistente com DPCD 0x702 bit 1 = 0.

## Outras Investigações

### I2C Bus 4

- 0x3a = teclado (já em uso pelo vivobook_kbd_fix)
- 0x5b = dispositivo desconhecido (registros dump: 0x00-0x0F = 0xFF, 0x10=0xC4, 0x15-0x16=0x0E, 0x18=0x0E) — **NÃO parece backlight controller**

### DRM Connector Properties

Connector eDP-1 tem apenas: EDID, DPMS, link-status, non-desktop, TILE. **Nenhuma propriedade de brightness.**

### `/sys/class/backlight/`

Diretório **vazio**. Nenhum backlight device registrado.

### Mensagem do kernel sobre backlight

```
samsung_atana33xc20 aux-aea0000.displayport-controller: [drm:drm_panel_dp_aux_backlight [drm_display_helper]] DP AUX backlight is not supported
```

O driver `panel_samsung_atna33xc20` chamou `drm_panel_dp_aux_backlight()` que checou 0x701 bit 0 (`DP_EDP_TCON_BACKLIGHT_ADJUSTMENT_CAP` = 0) e desistiu. Nenhum backlight device foi criado.

## Próximos Passos

1. **Habilitar PMIC PWM via DT overlay** — `CONFIG_OF_OVERLAY=y` está habilitado. Criar overlay que muda `status = "disabled"` para `"okay"` no node `pmk8550_pwm` ou `pm8550_pwm`, então o `leds-qcom-lpg` driver probes e cria um `pwmchip`. Depois usar `pwm_bl` para criar backlight device.

2. **Módulo DKMS direto** — Acessar SPMI registers do LPG (0xE100+) diretamente via `spmi_ext_register_readl()`/`writel()` para programar PWM. Registrar backlight device. Não depende de DT overlay.

3. **Identificar qual canal LPG** — Ler registers LPG de PMK8550 (SID 0) e PM8550 (SID 1) para ver se algum canal já está pré-configurado pelo firmware. Channels esperados em 0xE100, 0xE200, 0xE300, 0xE400.

4. **Fn keys** — O teclado I2C-HID provavelmente envia scancodes para Fn+F7/F8 (brightness down/up). Com um backlight device em `/sys/class/backlight/`, o GNOME/systemd deve capturar automaticamente.

## Script de Teste

`test-brightness.sh` no repo — faz testes DPCD com rollback automático de 15s:

```bash
sudo ./test-brightness.sh 1   # Só brightness MSB (mais seguro)
sudo ./test-brightness.sh 2   # Enable + DPCD mode + brightness
sudo ./test-brightness.sh 3   # Enable + PWM mode + brightness
sudo ./test-brightness.sh 4 N # Custom brightness MSB=N
```
