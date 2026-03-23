# Design: vivobook-usb4-fix DKMS Module

**Data:** 2026-03-23
**Hardware:** ASUS Vivobook X1407QA, Snapdragon X X1-26-100, Kernel 6.19.8-300.fc44.aarch64
**Objetivo:** Habilitar TB3 (Thunderbolt 3) no Elgato Thunderbolt 3 Dock via bypass do firmware ADSP

---

## Problema

O dock Elgato TB3 aparece apenas como USB Billboard (classe 0x11, Low Speed) — estado de fallback quando a negociação TB3 falha. O host não estabelece o túnel Thunderbolt.

### Causa raiz (dois blockers em série)

**Blocker 1 — PHY não configurado para USB4 (DT overlay):**

O DTB atual usa `qcom,x1e80100-qmp-usb3-dp-phy` (USB3+DP apenas) nos PHYs `fd5000` e `fda000`. TB3 requer `qcom,x1e80100-qmp-usb43dp-phy` (USB4 Gen2+DP). O driver `phy_qcom_qmp_combo` JÁ contém as tabelas SerDes USB43dp mas o DT não as ativa. Sem isso, o PHY não consegue operar em modo USB4 mesmo que o software acima esteja correto.

**Blocker 2 — Firmware ADSP não envia USBC_NOTIFY (kernel module):**

O driver `ucsi_glink`/`typec_ucsi` gerencia o stack TypeC. O `pmic_glink_altmode` envia `ALTMODE_PAN_ENABLE` ao firmware ADSP, mas o firmware **nunca responde com `USBC_NOTIFY`**. Sem esse callback:
1. O PS8833 retimer não é programado para modo USB4/TB3
2. O TypeC stack não registra o altmode 0x8087 (TB3) do partner
3. `typec_thunderbolt.ko` não ativa
4. boltctl não consegue autorizar o dock

### O que NÃO é o problema

- Topologia DT connector↔retimer: os nós já conectam PS8833 aos connectors corretamente no Zenbook A14 DTB
- Device link failures (`DL_FLAG_SYNC_STATE_ONLY`): benignos, probe ordering
- PS8833 driver: `ps883x` carregado e bound em I2C 2-0008 e 5-0008
- TypeC port management: `ucsi_glink` + `typec_ucsi` gerenciam as portas

---

## Arquitetura

### Dois componentes

```
/usr/src/vivobook-usb4-fix-1.0/
├── vivobook_usb4_fix.c          ← módulo kernel: bypass ADSP + retimer programming
├── vivobook_usb4_phy.dts        ← DT overlay: mudar PHY compatible para usb43dp
├── Makefile                     ← build overlay + módulo (padrão vivobook_cam_fix-2.0)
├── dkms.conf                    ← PRE_BUILD para compilar overlay
└── 70-vivobook-usb4.rules       ← udev rule: data_role fix
```

---

## Componente 1: DT Overlay (PHY fix)

### O que muda

Substituir o compatible dos PHYs `fd5000` e `fda000`:

```dts
/dts-v1/;
/plugin/;

/* Habilitar tabelas USB4 Gen2 no QMP combo PHY */
&{/soc@0/phy@fd5000} {
    compatible = "qcom,x1e80100-qmp-usb43dp-phy";
};

&{/soc@0/phy@fda000} {
    compatible = "qcom,x1e80100-qmp-usb43dp-phy";
};
```

### Risco e fallback

Se `phy_qcom_qmp_combo` não tiver o alias `qcom,x1e80100-qmp-usb43dp-phy` registrado no OF table, o overlay será aplicado mas o driver não rebindará — o PHY continuará em USB3 mode. O módulo detecta isso verificando se o PHY rebindou. Neste caso, o módulo ainda tenta programar o retimer (TB3 pode funcionar fisicamente sobre USB3 Gen2 = 10Gbps).

---

## Componente 2: Kernel Module

### Trigger: USB Billboard class driver

Em vez de usar um "TypeC partner notifier" (que não existe na kernel API), o módulo registra como **USB device driver** para a classe Billboard (class=0x11, subclass=0, protocol=0).

Racional: dispositivos TB3 que falham na negociação de altmode aparecem **exatamente** como USB Billboard. Quando o dock conecta sem TB3, ele se registra como Billboard. Isso nos dá um trigger limpo sem polling.

### Fluxo de execução

#### module_init

```
1. DMI check → aborta se não for ASUS Vivobook
2. Aplicar DT overlay (PHY compatible change) via of_overlay_fdt_apply()
3. Encontrar PS8833 retimers via of_find_compatible_node("parade,ps8833")
   → obter fwnode de cada PS8833
4. Pré-carregar handles de switch/mux (sem adquirir ownership ainda):
   → fwnode_typec_switch_get(ps8833_fwnode) → typec_switch*
   → fwnode_typec_mux_get(ps8833_fwnode)    → typec_mux*
5. Registrar USB driver para Billboard class
6. Registrar typec_altmode_driver para SVID 0x8087 (defensivo — para caso
   o firmware eventualmente envie USBC_NOTIFY e altmode seja descoberto)
```

#### USB Billboard probe (dock conectou, TB3 falhou)

```
1. Receber struct usb_device do Billboard
2. Mapear USB device → USB host controller (usb_device->bus->controller)
3. USB host controller → DWC3 platform device
4. DWC3 → TypeC port via DT graph (port@0 endpoint → pmic-glink connector)
5. TypeC port → partner device (typec_altmode2port / sysfs lookup)
6. Ler orientation GPIO (TLMM GPIO121 para port0, GPIO123 para port1)
   → TYPEC_ORIENTATION_NORMAL (GPIO HIGH) ou REVERSE (GPIO LOW)
7. typec_switch_set(sw, orientation)
   → PS8833 configura sentido do cabo (CC pin assignment)
8. typec_mux_set(mux, &state)
   → state.mode = TYPEC_STATE_MODAL
   → state.alt  = NULL (sem altmode object ainda)
   → state.data = &eudo  (struct enter_usb_data)
      eudo.eudo = FIELD_PREP(EUDO_USB_MODE_MASK, EUDO_USB_MODE_USB4) |
                  FIELD_PREP(EUDO_CABLE_SPEED_MASK, EUDO_CABLE_SPEED_USB4_GEN2) |
                  FIELD_PREP(EUDO_CABLE_TYPE_MASK, EUDO_CABLE_TYPE_RE_TIMER)
9. Tentar registrar altmode 0x8087 no partner:
   → typec_partner_register_altmode(partner, &tb3_desc)
   → tb3_desc = { .svid = 0x8087, .mode = 1, .vdo = 0x00000001 }
10. Log resultado — se typec_thunderbolt bindou: "TB3 ativo"
    Se não: "retimer programado; aguardando boltctl ou TB3 VDM"
```

#### USB Billboard disconnect

```
1. typec_mux_set(mux, TYPEC_STATE_SAFE)
2. typec_switch_set(sw, TYPEC_ORIENTATION_NONE)
3. Remover altmode 0x8087 (se foi registrado)
```

#### typec_altmode_driver probe (SVID 0x8087 — fallback)

```
Se o firmware eventualmente enviar USBC_NOTIFY e o altmode for descoberto:
→ Executar steps 6-10 acima
→ typec_thunderbolt já teria bindado, log apenas confirmação
```

### Softdep

```c
MODULE_SOFTDEP("pre: pmic_glink_altmode ps883x phy_qcom_qmp_combo ucsi_glink typec_ucsi");
```

---

## Componente 3: udev rule

```
# 70-vivobook-usb4.rules
# Garante host mode no port0 quando está em device mode
ACTION=="change", SUBSYSTEM=="typec", \
  ATTR{data_role}=="host [device]", \
  ATTR{data_role}="host"
```

Nota: `ATTR{data_role}=="host [device]"` match exato — `[host]` indica o modo selecionado entre colchetes. Evita disparar quando já está em host mode.

---

## Detalhes técnicos

### typec_mux_state correto para USB4

```c
struct enter_usb_data eudo = {
    .eudo = FIELD_PREP(EUDO_USB_MODE_MASK, EUDO_USB_MODE_USB4) |
            FIELD_PREP(EUDO_CABLE_SPEED_MASK, EUDO_CABLE_SPEED_USB4_GEN2) |
            FIELD_PREP(EUDO_CABLE_TYPE_MASK, EUDO_CABLE_TYPE_RE_TIMER),
};
struct typec_mux_state state = {
    .alt  = NULL,
    .mode = TYPEC_MODE_USB4,
    .data = &eudo,
};
typec_mux_set(mux, &state);
```

Referências: `include/linux/usb/typec_mux.h`, `include/linux/usb/typec_altmode.h`, `include/linux/usb/pd.h:498-514`.

### Orientation GPIOs (do Zenbook A14 DTB, base do Vivobook)

```
pmic-glink/orientation-gpios:
  TLMM GPIO 0x79 = GPIO121  → port0 (connector@0)
  TLMM GPIO 0x7b = GPIO123  → port1 (connector@1)

Convenção: GPIO HIGH = TYPEC_ORIENTATION_NORMAL
           GPIO LOW  = TYPEC_ORIENTATION_REVERSE
(a confirmar no primeiro teste — inverter se USB não funcionar)
```

### Mapeamento USB Billboard → TypeC port

```
usb_device (Billboard)
  → usb_device->bus->controller (struct device*)
  → platform_get_drvdata() → dwc3 struct
  → dwc3->dev.of_node → DT node usb@a600000 / usb@a800000
  → of_graph_get_endpoint_by_regs(node, 0, -1) → port@0 endpoint
  → of_graph_get_remote_port_parent() → pmic-glink connector@N node
  → typec_port lookup via dev_name match em /sys/class/typec/
```

---

## Riscos e mitigações

| Risco | Prob | Mitigação |
|-------|------|-----------|
| usb43dp-phy compatible não registrado no OF table → PHY não rebinda | **Confirmado** (kernel 6.19.8 só tem alias sc8280xp, não x1e80100) | Módulo detecta e continua com USB3 PHY; TB3 físico pode funcionar sobre USB3 Gen2. Nível 1 (PHY rebind) **não será atingido** nesta versão do kernel |
| `fwnode_typec_switch_get()` recusa (ucsi_glink tem ownership) | Alta | Tentar com consumer NULL; fallback: acessar via `typec_altmode_get_plug()` |
| `typec_partner_register_altmode()` falha (sem partner object acessível) | Média | Apenas programar retimer; verificar se boltctl detecta mesmo sem altmode |
| typec_thunderbolt não ativa mesmo com retimer+altmode corretos | Média | Investigar ucsi_glink para forçar VDM Discover Modes manualmente |
| Boot com dock conectado causa hang 2-3 min | Confirmado | Softdep garante carregamento pós-boot; módulo não força probe durante early boot |
| Orientation GPIO invertida no Vivobook vs Zenbook A14 | Baixa | Detectar falha de USB após programação; tentar REVERSE se NORMAL falhar |

---

## Critérios de sucesso

**Nível 1 — PHY overlay aplicado (não ativa no kernel 6.19.8 — alias ausente):**
- Overlay aplicado sem crash (`journalctl` sem erro de overlay)
- `/sys/class/typec/port0/usb_capability` permanece `"usb2 [usb3]"` (esperado neste kernel)
- Nível 1 completo exige upstream patch que adicione `x1e80100` ao OF table do `phy_qcom_qmp_combo`

**Nível 2 — Retimer programado (objetivo primário deste módulo):**
- Billboard USB desaparece e dock re-enumera em modo diferente
- `/sys/class/typec/port0-partner/number_of_alternate_modes` > 0
- `typec_thunderbolt.ko` bound ao partner altmode

**Nível 3 — TB3 funcional (sucesso completo):**
- `boltctl list` mostra o dock autorizado
- USB hub do dock em `lsusb`
- Ethernet em `ip link`

*Nível 3 depende de Nível 1 (PHY). Se PHY não rebindar, Nível 3 pode ainda ser alcançado se TB3 funcionar fisicamente sobre USB3 Gen2.*

---

## Fora de escopo

- HDMI via dock (DP altmode — fix separado)
- Câmera IR
- USB4 Gen3 (hardware suporta Gen2 / TB3 apenas)
- Kernel patches upstream
- **Diagnóstico DP Alt Mode simples**: antes de fazer o dock TB3 funcionar, vale testar adaptador USB-C→HDMI/DP simples para confirmar que `pmic_glink_altmode_enable_dp()` funciona — isola se o problema é específico ao TB3 ou a todo altmode
