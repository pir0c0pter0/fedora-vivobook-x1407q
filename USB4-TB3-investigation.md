# USB4 / Thunderbolt 3 — Investigação (Vivobook X1407QA)

## Hardware

- **Dock**: Elgato Thunderbolt 3 Dock — USB ID `0fd9:005f`, bcdDevice 4.51
- **Portas USB-C**: 2x portas (`a600000.usb` port0, `a800000.usb` port1), USB4 com suporte TB3

## Blockers identificados

A primeira barreira observada foi o PHY incorreto no DTB, mas a investigação
posterior mostrou que esse não é o bloqueio final. O estado atual ficou:

- **Blocker 1 — PHY ainda em USB3+DP**: o DTB atual usa
  `qcom,x1e80100-qmp-usb3-dp-phy` onde USB4/TB3 requer
  `qcom,x1e80100-qmp-usb43dp-phy`
- **Blocker 2 — firmware/PPM não deixa o Linux entrar no altmode**:
  `ALT_MODE_OVERRIDE` ausente e `SET_NEW_CAM` retorna `Operation not supported`
- **Blocker 3 — falta o host/router USB4 para x1e80100 no kernel**:
  sem esse driver, não existe barramento USB4 funcional para o dock tunelar

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
/sys/bus/usb4/              ✗ NÃO EXISTE — sem host/router USB4 funcional para x1e80100
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

## UCSI confirmado: sem ALT_MODE_OVERRIDE

Em **2026-03-24**, o debugfs UCSI da máquina foi consultado diretamente:

```bash
/sys/kernel/debug/usb/ucsi/pmic_glink.ucsi.0
GET_CAPABILITY   -> features = 0x0004
GET_CURRENT_CAM  -> 0xff (connector 1 e 2)
GET_CAM_SUPPORTED -> 0x03 (connector 1 e 2)
```

Decodificação de `features = 0x0004`:
- `ALT_MODE_DETAILS` = **sim**
- `ALT_MODE_OVERRIDE` = **não**

Isso casa exatamente com o comportamento observado:
- O OS enxerga altmodes locais (`8087`, `ff01`)
- O firmware **não aceita** comandos para forçar entrada neles

Teste direto do PPM:

```bash
SET_NEW_CAM (connector 1, enter=1, cam=0/1) -> Operation not supported
```

Conclusão prática: o firmware/PPM expõe detalhes de altmode, mas não expõe o caminho
de controle para o Linux entrar neles.

## Bug: data_role pode inicializar errado

O estado incorreto não está limitado ao `port0`. Diagnóstico atual do kernel
`6.19.8-300.fc44.aarch64` mostrou as duas portas em:
```
/sys/class/typec/port0/data_role → host [device]
/sys/class/typec/port1/data_role → host [device]
```

Fix manual confirmado funcional:
```bash
echo "host" | sudo tee /sys/class/typec/port0/data_role
```

Sem esse fix, o dock nem aparece como Billboard no USB.
Com o fix, o dock aparece como Billboard USB (classe 0x11, Low Speed) — estado de fallback
quando negociação TB3 falha.

**Status no repo:** fase 0 iniciada com `install-usb4-role-fix.sh`,
`modules/vivobook-usb4-fix-1.0/70-vivobook-usb4.rules` e helper
`vivobook-usb4-role-fix` para auto-forçar `host` nas portas Type-C.

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

## Tentativa de destravar `typec_thunderbolt`: bloqueada por `ps883x`

Em **2026-03-24**, foi testada uma emulação experimental no módulo
`vivobook_usb4_fix`:

1. registrar cabo Type-C sintético
2. registrar partner altmode TB3 sintético (`SVID 0x8087`)
3. injetar `ops->enter/exit` no altmode local `port0.0`
4. deixar o `typec_thunderbolt` avançar até `typec_altmode_enter()`

Resultado:
- o driver avançou além do `-EOPNOTSUPP`
- mas o kernel caiu em **Oops** no caminho:

```text
typec_altmode_enter()
  -> typec_altmode_set_state(TYPEC_STATE_SAFE)
  -> typec_retimer_set()
  -> ps883x_retimer_set()
  -> ps883x_set()
```

O módulo experimental agora deixa essa rota **desligada por padrão** via:

```bash
emulate_tb3_port_ops=0
```

Ela só deve ser religada manualmente para debug controlado, porque pode repetir o Oops.

## O que o dock precisa para funcionar

O Elgato TB3 Dock tem **tudo** (USB hub, ethernet, HDMI 2.0) atrás do túnel Thunderbolt.
Sem TB3 ativo, só acessa: carga PD + interface Billboard (inútil).

Para funcionar completamente precisa:
1. Driver host/router USB4 no kernel + nó NHI/router correspondente no DT
2. PHY mudado para `qcom,x1e80100-qmp-usb43dp-phy`
3. `typec_thunderbolt.ko` conseguir negociar altmode
4. boltctl autorizar o dispositivo

## Abordagem DKMS: útil para debug, insuficiente sozinha

Seguindo o padrão do projeto (INSYDE bloqueia DTB override):
- Criar módulo DKMS com `of_overlay_fdt_apply()`
- Overlay precisa:
  - Mudar `compatible` do PHY `fd5000` e `fda000` para `qcom,x1e80100-qmp-usb43dp-phy`
  - Adicionar nó USB4 NHI/router para `a600000.usb` e `a800000.usb`
- Referência de padrão: `vivobook_cam_fix.c` (two-phase overlay)

Limite atual dessa abordagem:
- O overlay ainda é útil para validar DT/PHY e deixar a topologia pronta
- O módulo `vivobook_usb4_fix` continua útil para instrumentação e logs
- Mas **isso não basta** para o Elgato TB3 Dock: sem driver host/router no kernel,
  o túnel Thunderbolt nunca fecha
- Portanto o DKMS virou **fase de groundwork**, não mais a solução principal

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

## Conclusão: próximo passo = kernel custom

**Revisado em 2026-03-24.** O diagnóstico fecha em:

- o fix de `data_role` continua necessário como fase 0
- o DKMS experimental continua útil para debug
- mas o caso do dock TB3 **não será resolvido** sem um kernel com suporte
  host/router USB4 para `x1e80100`

Em outras palavras: a investigação saiu de "tentar destravar altmode no runtime"
para "carregar a pilha USB4 correta dentro do kernel".

| Recurso | Status | Kernel mínimo |
|---------|--------|---------------|
| USB3 SuperSpeed via USB-C | ✅ Funciona | 6.8+ |
| DP Alt Mode (tela via USB-C) | ✅ Funciona | 6.16+ |
| **USB4 / TB3 tunneling** | ❌ **Driver inexistente** | N/A |

**Por que o dock não funciona:** O Elgato TB3 Dock roteia USB hub, ethernet e HDMI inteiramente através do túnel Thunderbolt 3. Sem o túnel TB3 ativo, nada é acessível.

**Status upstream (Mar 2026):**
- A árvore upstream de Thunderbolt/USB4 continua sem driver Qualcomm específico
  para host/router em `drivers/thunderbolt/`
- Konrad Dybcio (Qualcomm) está escrevendo `qcom_usb4.c` — RFC bindings postados Set/2025, driver "not yet 100% ready to share"
- Mantenedor Mika Westerberg exige submissão de bindings + driver juntos
- GCC USB4 clocks/resets mergeados (6.12.63+, 6.17.13+) — só infraestrutura
- UCSI glink quirk para x1e80100 em review (Jan/2026)
- Nenhum kernel disponível (incluindo 6.19.9, COPR kevin/x1e80100kernel 6.17-rc1) tem o driver

**ETA:** Desconhecido. Mesmo a árvore de desenvolvimento atual não expõe ainda
um driver host/router Qualcomm pronto para teste imediato.

**Próximo passo aprovado:**
- Partir para kernel custom com patch stack USB4/TB3
- Tratar `modules/vivobook-usb4-fix-1.0/` como apoio de diagnóstico, não como fix final
- Usar o fluxo RPM Fedora já aplicado na investigação de `s2idle`
- Plano de execução: `docs/research/2026-03-24-usb4-custom-kernel-plan.md`

**Alternativas enquanto o patch stack não chega:**
- Hub USB-A ou dock USB4 passivo (sem requisito TB3)
- Testar RFC patches do Konrad Dybcio via kernel custom
- Acompanhar: https://lkml.org (buscar "Qualcomm USB4 Host Router")

## Artefatos iniciados no repositório

- `diagnose-usb4.sh` — coleta o estado atual de Type-C, altmodes, USB, logs e UCSI debugfs
- `install-usb4-role-fix.sh` — instala a regra `udev` para corrigir `data_role`
- `modules/vivobook-usb4-fix-1.0/` — base DKMS experimental para instrumentação do caminho Type-C/retimer
