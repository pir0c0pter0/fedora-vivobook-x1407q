# USB4 / Thunderbolt 3 — Investigação (Vivobook X1407QA)

## Hardware

- **Dock**: Elgato Thunderbolt 3 Dock — USB ID `0fd9:005f`, bcdDevice 4.51
- **Portas USB-C**: 2x portas (`a600000.usb` port0, `a800000.usb` port1), USB4 com suporte TB3

## Blockers identificados

A primeira barreira observada foi o PHY incorreto no DTB, mas a investigação
posterior mostrou que esse não é o bloqueio final. O estado atual ficou:

- **Blocker 1 — topologia DT/PHY ainda incompleta para USB4**: o DT atual
  expõe só o caminho hoje aproveitado por USB3+DP; para USB4 ainda faltam
  host/router, graph completo e os follow-ups públicos de PHY/DP
- **Blocker 2 — firmware/PPM não deixa o Linux entrar no altmode**:
  `ALT_MODE_OVERRIDE` ausente e `SET_NEW_CAM` retorna `Operation not supported`
- **Blocker 3 — falta o host/router USB4 para x1e80100 no kernel**:
  sem esse driver, não existe barramento USB4 funcional para o dock tunelar

```
/proc/device-tree/soc@0/phy@fd5000/compatible  → qcom,x1e80100-qmp-usb3-dp-phy
/proc/device-tree/soc@0/phy@fda000/compatible  → qcom,x1e80100-qmp-usb3-dp-phy
```

Observação importante de upstream: o binding público aceito para X1E fica no
arquivo `qcom,sc8280xp-qmp-usb43dp-phy.yaml`, mas o `compatible` usado para o
SoC continua sendo `qcom,x1e80100-qmp-usb3-dp-phy`. Em outras palavras:
inventar `qcom,x1e80100-qmp-usb43dp-phy` num overlay local não alinha com o
que existe hoje upstream.

O driver `phy-qcom-qmp-combo.ko` JÁ contém `x1e80100_usb43dp_serdes_tbl`
(tabelas USB4 Gen3+DP), então o gargalo deixou de ser "achar um compatible
mágico" e passou a ser subir a pilha USB4 completa com DT/graph corretos.

## Thunderbolt no kernel: ausente no 7.2 (e inútil se ligado)

O bloco abaixo descrevia o Fedora 6.19.8. **No kernel instalado hoje
(`7.2.0-x1407qa`) o USB4 nem é compilado:**

```
CONFIG_USB4                 ✗ "is not set" em /boot/config-7.2.0-x1407qa
/sys/bus/thunderbolt/       ✗ não existe
thunderbolt.ko              ✗ não existe em /lib/modules
```

Isso **não é regressão a corrigir**: `CONFIG_USB4` ainda é `depends on PCI` e
só constrói o NHI da Intel (`nhi.c`, dispositivo PCI). O host router da
Qualcomm é MMIO e não aparece no barramento PCI, então ligar `CONFIG_USB4=y`
no 7.2 não cria domínio nenhum — foi o que já acontecia no 6.19.8, onde
`CONFIG_USB4=y` convivia com `/sys/bus/usb4/` inexistente.

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
2. DT/PHY/graph alinhados ao stack público de USB4 para `x1e80100`
3. `typec_thunderbolt.ko` conseguir negociar altmode
4. boltctl autorizar o dispositivo

## Abordagem DKMS: útil para debug, insuficiente sozinha

Seguindo o padrão do projeto (INSYDE bloqueia DTB override):
- Criar módulo DKMS com `of_overlay_fdt_apply()`
- Overlay precisa:
  - Alinhar nós de PHY/connector/retimer ao stack público de USB4 do X1E
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

## Reverificação 2026-08-24 — dump Windows + upstream

Feita depois de extrair `windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst`,
para testar a hipótese de que os arquivos do Windows destravariam o caso.
**Não destravam.** O bloqueio é um só: o driver não existe em lugar nenhum.

### Upstream: três árvores, nenhuma tem o driver

`drivers/thunderbolt/Makefile` é byte a byte o mesmo nas três, sem qcom:

| Árvore | Resultado |
|--------|-----------|
| `torvalds/linux` master (pós-7.2) | sem qcom; `USB4 depends on PCI` |
| `linux-next` | idêntico ao master |
| `westeri/thunderbolt.git` branch `next` (árvore do mantenedor) | idêntico ao master |

Ou seja: quase um ano depois da RFC de bindings (Set/2025), o `qcom_usb4.c`
continua fora até da árvore onde ele entraria primeiro. Segue sem ETA.

### O hardware, confirmado pelos INFs do dump

O dump não traz driver aproveitável (é `.sys` ARM64/PE), mas fecha a
identidade e a arquitetura do bloco:

| Item | Valor | Origem |
|------|-------|--------|
| Bus enumerador | `ACPI\QCOM0C6D` — "Qualcomm(R) USB4(TM) Host Router Bus" | `QcUsb4Bus8380.inf` |
| Host router | `USB4\QCOM0CD10001` | `QcUsb4Filter8380.inf` |
| Driver do router | genérico da Microsoft, ligado a `ACPI\ACPI0015` | `usb4hostrouter.inf` |
| Papel da Qualcomm | só um **lower filter** + o bus | ambos INFs |
| Firmware do router | residente, versionado, build `Nov 24 2024`; só atualizável via CFU | strings de `QcUsb4Filter8380.sys` |

Dois pontos que importam para o port Linux:

1. **Não é PCI.** O router é MMIO e o Windows usa `ACPI0015` (host interface
   padrão do spec USB4). Confere com a RFC: "Because it's not a PCIe device,
   all the places where the code assumes it can freehand dereference
   `nhi->pdev` are altered to instead consume a `struct device *`". É por isso
   que o `nhi.c` da Intel não serve.
2. **O router roda firmware num MCU.** A string
   `Starting USB4 FW ver: %x.%x.%x (%s boot)` confirma; a RFC descreve o driver
   Linux carregando esse firmware com `memcpy_toio()` e acordando o MCU.

### O firmware NÃO está no dump

Verificado, não presumido:

- Os pacotes `qcusb4bus8380` e `qcusb4filter8380` têm exatamente **3 arquivos
  cada** (`.cat`, `.inf`, `.sys`) — declarado nos `.ini` do DriverStore
- Nenhum `.mbn` de USB4 no dump inteiro (5421 arquivos): só ADSP, CDSP, GPU,
  WLAN, vídeo, câmera, HDCP, WPSS, AV1E, VSS
- `QcUsb4Filter8380.sys` não tem blob embutido: as 8 seções PE são de driver
  normal, e as strings de link training (`Lanes bonded successfully`,
  `Phase 5. Preset %x`, `PHY ack lane %x`) ficam em `.data` — é o **catálogo de
  trace** que o driver usa para decodificar eventos do MCU, não a imagem

Coerente com o INF, que só declara `ComponentFirmwareUpdate` (atualização),
nunca carga inicial: quem carrega o firmware do router é a cadeia UEFI/XBL.

### Conclusão

Faltam **duas** peças, e o dump não entrega nenhuma: o driver (Qualcomm-interno)
e o firmware do MCU em formato carregável pelo Linux. O que o dump entrega é
identidade e arquitetura — útil para revisar a série quando ela sair, inútil
para fazer o dock funcionar hoje.

Não há o que ligar, aplicar ou configurar. Reabrir só quando o `qcom_usb4.c`
aparecer publicamente.

## Dock USB-C sem túnel: validado 2026-08-24

Contraprova prática de que o bloqueio é só o túnel, não a porta Type-C.
**Dell Pro Smart Dock SD25** plugado na porta 0 (`a600000.usb`) enumerou
inteiro por USB3 puro, sem host router nenhum envolvido.

| Peça | Resultado |
|------|-----------|
| Hubs USB3 | Realtek `0bda:0480` / `0485` / `0481` — **USB 3.2 Gen 2, 10 Gbps** |
| Hubs USB2 | Realtek `0bda:5480` / `5485` / `5481` |
| Ethernet | RTL8156 2.5GbE (`0bda:8156`) → `r8152` → `enu1u4u1` a 5000M |
| HIDs Dell | `413c:b0a2` (SD25), `b0a5` (VMM8431), `b06e` (K2 DOCK HID), `b0a1`/`b0a3`/`b0a4` |
| Carga | contrato PD ativo (`power_operation_mode = usb_power_delivery`) |

Dois estados que **parecem** falha e não são:

- `enu1u4u1` em `NO-CARRIER` / `Link detected: no` — não havia cabo de rede no dock
- bateria em `Not charging` — é o limite de 80% (`charge_control_end_threshold`)
  segurando; comportamento normal da conquista #16

**Vídeo: não testado.** Não havia monitor ligado ao dock durante o teste.
`card0-DP-1` e `card0-DP-2` ficaram `disconnected`, e o plug do dock (t=1357s)
não gerou nenhum evento de DP, altmode ou HPD — só enumeração USB. Sem display
atado ao dock isso é o esperado, porque o VMM8431 (o MST hub de vídeo do dock)
só pede entrada em DP alt mode quando tem HPD. **Não conta como bug**; refazer o
teste com monitor plugado antes de concluir qualquer coisa sobre esse caminho.

Conclusão: um dock USB-C que não dependa de túnel entrega hub 10 Gbps + 2.5GbE +
carga hoje, sem kernel custom e sem driver faltando. O Elgato TB3 continua sem
solução porque roteia *tudo* por dentro do túnel Thunderbolt.

**Próximo passo aprovado (Mar/2026) — SUPERSEDIDO pela reverificação acima.**

O plano de "kernel custom com patch stack USB4/TB3" pressupunha que existisse um
patch stack para aplicar. Em 2026-08-24 foi confirmado que não existe: nem no
master, nem no linux-next, nem na árvore do mantenedor. Buildar kernel custom
hoje não muda nada — não há patch para colocar nele.

`docs/research/2026-03-24-usb4-custom-kernel-plan.md` e
`docs/research/2026-03-24-usb4-upstream-patch-checklist.md` continuam válidos
como *procedimento*, para o dia em que a série sair. Não são acionáveis agora.

**O que dá para fazer enquanto isso:**
- Hub USB-A, ou dock USB-C que não dependa de túnel (USB3 + DP alt mode funcionam)
- Acompanhar `westeri/thunderbolt.git` — é onde o `qcom_usb4.c` aparece primeiro
- Gatilho para reabrir: `drivers/thunderbolt/Makefile` ganhar objeto qcom

## Artefatos iniciados no repositório

- `diagnose-usb4.sh` — coleta o estado atual de Type-C, altmodes, USB, logs e UCSI debugfs
- `install-usb4-role-fix.sh` — instala a regra `udev` para corrigir `data_role`
- `modules/vivobook-usb4-fix-1.0/` — base DKMS experimental para instrumentação do caminho Type-C/retimer
