# Brightness Fix - ASUS Vivobook X1407QA (Snapdragon X / X1E80100)

## STATUS: FUNCIONANDO

Controle de brilho funcionando via módulo DKMS `vivobook-bl-fix`.
Cria `/sys/class/backlight/vivobook-backlight` com 4096 níveis (12-bit).
GNOME detecta automaticamente. Slider aparece no Quick Settings (canto superior direito).

### Como usar
- **GNOME**: Slider no Quick Settings (canto superior direito)
- **CLI**: `brightnessctl set 50%` ou `echo 2048 > /sys/class/backlight/vivobook-backlight/brightness`
- **Teclas Fn+F5/F6**: NÃO funcionam ainda (teclado registra keycodes mas não envia eventos)

### Arquivos instalados
- `/usr/src/vivobook-bl-fix-1.0/` — fonte DKMS (vivobook_bl_fix.c, Makefile, dkms.conf)
- `/etc/modules-load.d/vivobook-bl-fix.conf` — auto-load no boot

---

## Como foi resolvido (passo a passo)

### 1. O problema

O painel LCD (Innolux N140JCA-ELK) precisa de um sinal PWM externo para controlar o brilho.
O firmware INSYDE configura o hardware PWM no PMIC (PMK8550 LPG ch0), mas marca o nó DTB
como `status = "disabled"`, então nenhum driver do kernel assume o controle.
Como não é possível modificar o DTB neste firmware (7 métodos testados, todos falharam),
a solução foi criar um módulo kernel que acessa o hardware diretamente via regmap.

### 2. Identificação do hardware

**PWM Generator**: PMK8550 LPG (Light Pulse Generator) channel 0
- Endereço base SPMI: 0xE800
- Tipo: HI_RES_PWM (subtype 0x0C)
- Resolução: 12-bit (4096 níveis), clock 19.2MHz
- Firmware já configura tudo, só falta routing do sinal

**GPIO de saída**: PMK8550 GPIO5 (0xBC00)
- Modo: digital output
- DIG_OUT_SOURCE_CTL = 0x04 = **DTEST3** (no mapeamento LV/MV)
- Já habilitado pelo firmware

**GPIO de enable**: PMC8380_3 GPIO4
- On/off do backlight (já HIGH = ligado)

### 3. O problema do routing

O LPG gera o PWM internamente, mas o sinal não chega ao GPIO5 porque:
- GPIO5 espera receber o sinal pela linha **DTEST3** do barramento de teste do PMIC
- O LPG não estava configurado para enviar seu PWM pela DTEST3
- Resultado: GPIO5 flutuava HIGH = brilho sempre 100%

### 4. A solução: DTEST3 routing + PWM_SYNC

Duas peças críticas foram necessárias:

**DTEST3 routing** (registro E2 do LPG, protegido por SEC_ACCESS):
```c
// Desbloqueia escrita protegida
regmap_write(rm, 0xE8D0, 0xA5);  // SEC_ACCESS = unlock key
// Roteia saída PWM do LPG para linha DTEST3
regmap_write(rm, 0xE8E2, 0x01);  // TEST3 = enable PWM output on DTEST3
```

**PWM_SYNC** (registro 0x47, auto-clearing):
```c
// Após escrever novo valor de PWM nos registros 0x44-0x45:
regmap_write(rm, 0xE847, 1);  // Latcha o novo valor no hardware PWM
```

Sem o PWM_SYNC, os valores escritos ficam no cache do regmap mas o gerador PWM
do hardware não atualiza. Este foi o bug que travou o progresso por horas.

### 5. Cadeia completa do sinal

```
LPG ch0 (0xE800)     SEC_ACCESS + E2=0x01     GPIO5 (0xBC00)
┌─────────────┐      ┌──────────────┐      ┌──────────────┐
│ PWM 12-bit  │─────►│   DTEST3     │─────►│ DIG_OUT_SRC  │──► Painel LCD
│ 0x44=LSB    │      │   (linha     │      │ = 0x04       │    (backlight)
│ 0x45=MSB    │      │   interna    │      │ (= DTEST3)   │
│ 0x47=SYNC   │      │   do PMIC)   │      │              │
└─────────────┘      └──────────────┘      └──────────────┘
```

### 6. O que NÃO funciona / PERIGOSO

| Tentativa | Resultado |
|-----------|-----------|
| GPIO5 DIG_OUT_SOURCE_CTL = 0x00 (func3) | **MATA A TELA** — reboot forçado |
| GPIO5 forçar saída LOW | **MATA A TELA** — reboot forçado |
| DPCD/AUX backlight | Painel não suporta (LCD, não OLED) |
| Modificar DTB | Firmware INSYDE bloqueia todos os métodos |
| WLED | Não existe neste PMIC |
| ACPI backlight | Sem métodos _BCM/_BCL no DSDT |
| Apenas DTEST sem PWM_SYNC | Routing funciona mas valor PWM não atualiza |

---

## Hardware Summary

| Item | Value |
|------|-------|
| Panel | Innolux N140JCA-ELK (IPS LCD, NOT OLED) |
| PMIC | PMK8550 (SID 0, DT: pmic@0) |
| LPG channel | ch0 at 0xE800 (HI_RES_PWM subtype 0x0C) |
| PWM config | 12-bit (4096 levels), 19.2MHz clock, enabled |
| GPIO for PWM | PMK8550 GPIO5 at 0xBC00, DIG_OUT_SOURCE_CTL=0x04 (DTEST3) |
| Backlight enable | PMC8380_3 GPIO4 (on/off, already HIGH) |
| Key register | LPG TEST3 (0xE8E2): write 0x01 via SEC_ACCESS to enable DTEST3 |
| Key register | PWM_SYNC (0xE847): write 1 after each value change |

## Pendente

- [ ] Teclas Fn+F5/F6: keycodes registrados no vivobook-kbd mas não geram eventos
- [ ] Testar persistência após reboot (módulo auto-load configurado)
- [ ] Verificar slider no GNOME Quick Settings (pode precisar logout/login)
