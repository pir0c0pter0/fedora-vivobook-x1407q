# USB4 / Thunderbolt 3 — Investigação (Vivobook X1407QA)

## Hardware

- **Dock**: Elgato Thunderbolt 3 Dock — USB ID `0fd9:005f`, bcdDevice 4.51
- **Portas USB-C**: 2x portas (`a600000.usb` port0, `a800000.usb` port1), USB4 com suporte TB3

## Problema raiz: PHY não configurado para USB4

O DTB atual usa PHY `qcom,x1e80100-qmp-usb3-dp-phy` (USB 3.0 + DP apenas).
USB4/TB3 requer a variante `qcom,x1e80100-qmp-usb43dp-phy` (USB4 Gen3 + DP).

```
/proc/device-tree/soc@0/phy@fd5000/compatible  → qcom,x1e80100-qmp-usb3-dp-phy  ← ERRADO para USB4
/proc/device-tree/soc@0/phy@fda000/compatible  → qcom,x1e80100-qmp-usb3-dp-phy  ← ERRADO para USB4
```

O driver `phy-qcom-qmp-combo.ko` JÁ contém `x1e80100_usb43dp_serdes_tbl` (tabelas USB4 Gen3+DP),
o hardware suporta, mas o DT não configura.

## Thunderbolt no kernel: presente mas inativo

```
CONFIG_USB4=y               ✓ (built-in)
thunderbolt.ko              ✓ (built-in)
typec_thunderbolt.ko        ✓ (alias typec:id8087)
/sys/bus/usb4/              ✗ NÃO EXISTE — sem USB4 host controller no DT
boltctl → Security Level: unknown
```

`typec_thunderbolt.ko` nunca carrega porque o altmode TB3 nunca é negociado.

## Altmodes registrados no port0 (lado local)

```
/sys/class/typec/port0/port0.0/svid → 8087  (Thunderbolt — suportado localmente)
/sys/class/typec/port0/port0.1/svid → ff01  (DisplayPort — suportado localmente)
/sys/class/typec/port0/port0.1/vdo  → 0x001f1cc5
```

Porém o partner (dock) não anuncia altmodes:
```
/sys/class/typec/port0-partner/number_of_alternate_modes → 0
```
Isso porque sem USB4 host controller ativo, a negociação TB3 não acontece.

## Bug: data_role padrão errado

Port0 inicializa em **device mode** ao invés de host:
```
/sys/class/typec/port0/data_role → host [device]   ← BUG: deveria ser [host]
/sys/class/typec/port1/data_role → [host] device   ← OK
```

Fix manual confirmado funcional:
```bash
echo "host" | sudo tee /sys/class/typec/port0/data_role
```

Sem esse fix, o dock nem aparece como Billboard no USB.
Com o fix, o dock aparece como Billboard USB (classe 0x11, Low Speed) — estado de fallback
quando negociação TB3 falha.

**TODO**: criar udev rule para auto-setar host mode quando partner conecta.

## pmic_glink_altmode: firmware não envia USBC_NOTIFY

- PDR notifica `charger_pd` → `pmic_glink_altmode_pdr_notify()` é chamado → agenda `enable_work`
- `enable_work` envia `ALTMODE_PAN_ENABLE` ao firmware ADSP
- Firmware **nunca responde** com `USBC_NOTIFY` quando dock está conectado
- Sem `USBC_NOTIFY`, o driver não programa o PS8833 retimer para nenhum modo

PS8833 retimers (I2C):
```
I2C 2-0008 → port0 retimer
I2C 5-0008 → port1 retimer
Driver: ps883x_retimer
```

## O que o dock precisa para funcionar

O Elgato TB3 Dock tem **tudo** (USB hub, ethernet, HDMI 2.0) atrás do túnel Thunderbolt.
Sem TB3 ativo, só acessa: carga PD + interface Billboard (inútil).

Para funcionar completamente precisa:
1. USB4 host controller no DT (NHI/router node)
2. PHY mudado para `qcom,x1e80100-qmp-usb43dp-phy`
3. `typec_thunderbolt.ko` conseguir negociar altmode
4. boltctl autorizar o dispositivo

## Abordagem DKMS (DT overlay em runtime)

Seguindo o padrão do projeto (INSYDE bloqueia DTB override):
- Criar módulo DKMS com `of_overlay_fdt_apply()`
- Overlay precisa:
  - Mudar `compatible` do PHY `fd5000` e `fda000` para `qcom,x1e80100-qmp-usb43dp-phy`
  - Adicionar nó USB4 NHI/router para `a600000.usb` e `a800000.usb`
- Referência de padrão: `vivobook_cam_fix.c` (two-phase overlay)

## Alternativa mais simples: DP Alt Mode direto

Se um adaptador USB-C → HDMI/DP simples (não Thunderbolt) for testado:
- O firmware pode enviar `USBC_NOTIFY` com modo DP (sem precisar de TB3)
- `pmic_glink_altmode_enable_dp()` programa o PS8833 para roteamento DP
- Evita toda a complexidade USB4/TB3
- Vale testar antes de atacar o overlay USB4

## Erros conhecidos (não bloqueantes)

```
qcom_pmic_glink pmic-glink: Failed to create device link (0x180) with supplier a600000.usb
qcom_pmic_glink pmic-glink: Failed to create device link (0x180) with supplier a800000.usb
```
Presentes em todos os boots — `DL_FLAG_SYNC_STATE_ONLY | DL_FLAG_INFERRED` por probe ordering.
Não causam falha funcional.

## AVISO: boot com dock conectado falha

Com dock plugado durante o boot, o sistema trava por 2-3 minutos e não inicia.
Sempre desconectar o dock antes de reiniciar. Conectar só após o boot completo.

## Conclusão: bloqueio fundamental — driver não existe

**Investigado em 2026-03-23.** O driver USB4 Host Router para x1e80100 **não existe em nenhum kernel Linux atual.**

| Recurso | Status | Kernel mínimo |
|---------|--------|---------------|
| USB3 SuperSpeed via USB-C | ✅ Funciona | 6.8+ |
| DP Alt Mode (tela via USB-C) | ✅ Funciona | 6.16+ |
| **USB4 / TB3 tunneling** | ❌ **Driver inexistente** | N/A |

**Por que o dock não funciona:** O Elgato TB3 Dock roteia USB hub, ethernet e HDMI inteiramente através do túnel Thunderbolt 3. Sem o túnel TB3 ativo, nada é acessível.

**Status upstream (Mar 2026):**
- Konrad Dybcio (Qualcomm) está escrevendo `qcom_usb4.c` — RFC bindings postados Set/2025, driver "not yet 100% ready to share"
- Mantenedor Mika Westerberg exige submissão de bindings + driver juntos
- GCC USB4 clocks/resets mergeados (6.12.63+, 6.17.13+) — só infraestrutura
- UCSI glink quirk para x1e80100 em review (Jan/2026)
- Nenhum kernel disponível (incluindo 6.19.9, COPR kevin/x1e80100kernel 6.17-rc1) tem o driver

**ETA:** Desconhecido. Estimativa: 6.21–6.22 se Konrad submeter em breve.

**Alternativas enquanto aguarda upstream:**
- Hub USB-A ou dock USB4 passivo (sem requisito TB3)
- Testar RFC patches do Konrad Dybcio via kernel custom
- Acompanhar: https://lkml.org (buscar "Qualcomm USB4 Host Router")
