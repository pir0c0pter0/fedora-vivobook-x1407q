# USB4 / Thunderbolt 3 — Investigação (Vivobook X1407QA)

## Hardware

- **Dock**: Elgato Thunderbolt 3 Dock — USB ID `0fd9:005f`, bcdDevice 4.51
- **Portas USB-C**: 2x portas (`a600000.usb` port0, `a800000.usb` port1), USB4 com suporte TB3
- **SoC real**: `qcom,x1p42100` (**Purwa**), não X1E80100/Hamoa. O DT de
  Purwa inclui `hamoa.dtsi`, por isso vários blocos IP continuam usando
  compatibles e nomes `x1e80100`.
- **DT em uso**: ASUS Zenbook A14 UX3407QA; ele descreve DWC3 + QMP USB3/DP +
  PS8833 para as duas portas, mas nenhum host-router USB4.

## Blockers identificados

A primeira barreira observada foi atribuída ao PHY, mas a investigação de
2026-08-24 isolou três peças concretas:

- **Blocker 1 — driver host-router Qualcomm ainda privado**: o suporte NHI
  não-PCI genérico já entrou no upstream, mas o driver de plataforma que tira
  o router do reset, carrega o MCU e registra o domínio USB4 não foi publicado.
- **Blocker 2 — PHY USB4 ainda em review**: a série v4 de 2026-08-20 adiciona
  o terceiro PHY (`QMP_USB43DP_USB4_PHY`), modo TBT e o quinto clock
  `p2rr2p_pipe`. O kernel/DT vivo ainda têm somente o caminho USB3+DP.
- **Blocker 3 — DT/graph do router incompletos publicamente**: o RFC publicou
  um exemplo do HR0; os recursos e a topologia final das duas instâncias ainda
  não existem em um DTS upstream utilizável.

A ausência de `ALT_MODE_OVERRIDE` no UCSI é um achado real, mas **não é um
blocker independente comprovado**. O firmware Qualcomm também conduz altmodes
fora do UCSI; DP funciona nesta máquina mesmo com a lista de altmodes do partner
vazia. O primeiro bloqueio observável continua sendo a ausência do host-router.

```
/proc/device-tree/soc@0/phy@fd5000/compatible  → qcom,x1e80100-qmp-usb3-dp-phy
/proc/device-tree/soc@0/phy@fda000/compatible  → qcom,x1e80100-qmp-usb3-dp-phy
```

Observação importante de upstream: o binding público aceito para X1E fica no
arquivo `qcom,sc8280xp-qmp-usb43dp-phy.yaml`, mas o `compatible` usado para o
SoC continua sendo `qcom,x1e80100-qmp-usb3-dp-phy`. Em outras palavras:
inventar `qcom,x1e80100-qmp-usb43dp-phy` num overlay local não alinha com o
que existe hoje upstream.

O driver atual contém a configuração USB3+DP usada pelo `compatible` acima.
As tabelas e o terceiro PHY específicos de USB4/TBT3 só aparecem na série PHY
v4 ainda não mergeada. Portanto, também não adianta procurar um `compatible`
"mágico": é necessário aplicar a série real e, depois, o driver do router.

## Thunderbolt no kernel: ausente no 7.2 (e inútil se ligado)

O bloco abaixo descrevia o Fedora 6.19.8. **No kernel instalado hoje
(`7.2.0-x1407qa`) o USB4 nem é compilado:**

```
CONFIG_USB4                 ✗ "is not set" em /boot/config-7.2.0-x1407qa
/sys/bus/thunderbolt/       ✗ não existe
thunderbolt.ko              ✗ não existe em /lib/modules
```

Isso **não é regressão a corrigir**. A refatoração genérica para NHI não-PCI
foi mergeada em maio de 2026, mas `CONFIG_USB4` ainda depende de PCI e a árvore
não contém nenhum objeto Qualcomm/platform no `Makefile`. O host-router deste
SoC é MMIO; ligar a opção sem o driver Qualcomm não cria domínio nenhum — foi
o que já acontecia no 6.19.8, onde `CONFIG_USB4=y` convivia com
`/sys/bus/thunderbolt/` inexistente.

No teste de 2026-03-24, nenhum altmode TB3 de partner foi registrado/entrado;
portanto o caminho `typec_thunderbolt` não avançou até um túnel. Isso descreve
o resultado, não atribui a causa ao UCSI.

## Altmodes registrados no port0 (lado local)

```
/sys/class/typec/port0/port0.0/svid → 8087  (Thunderbolt — suportado localmente)
/sys/class/typec/port0/port0.1/svid → ff01  (DisplayPort — suportado localmente)
/sys/class/typec/port0/port0.1/vdo  → 0x001f1cc5
```

Naquele teste, o partner do dock ficou sem altmodes registrados:
```
/sys/class/typec/port0-partner/number_of_alternate_modes → 0
```
Como DP depois funcionou com esse mesmo contador em zero, o valor isolado não
identifica por qual camada a negociação TB3 parou.

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

Conclusão limitada: o PPM não oferece **override manual via UCSI**. Isso não
prova que o firmware impeça USB4, porque o caminho Qualcomm usa notificações
PMIC GLINK/ADSP fora dessa interface. O kernel 7.2 já contém
`UCSI_USB4_IMPLIES_USB`; esse quirk não cria o host-router ausente.

## Observação histórica: data_role no kernel 6.19.8

O diagnóstico de 2026-03-24 no kernel `6.19.8-300.fc44.aarch64` mostrou as
duas portas em:
```
/sys/class/typec/port0/data_role → host [device]
/sys/class/typec/port1/data_role → host [device]
```

Fix manual confirmado funcional:
```bash
echo "host" | sudo tee /sys/class/typec/port0/data_role
```

Naquele kernel, sem o fix o dock nem aparecia como Billboard; forçar `host`
permitia o fallback USB.

No snapshot vivo do 7.2, port0 já estava em `[host]` com o Dell SD25 e port1
ocioso em `[device]`. Portanto o workaround **não foi revalidado como requisito
do 7.2** e não deve ser aplicado cegamente. Só investigar a role novamente se
um dispositivo USB conectado não enumerar.

**Artefatos históricos no repo:** `install-usb4-role-fix.sh`,
`modules/vivobook-usb4-fix-1.0/70-vivobook-usb4.rules` e helper
`vivobook-usb4-role-fix` para auto-forçar `host` nas portas Type-C.

## Observação histórica: sem USBC_NOTIFY no teste TB3 de 2026-03-24

- PDR notifica `charger_pd` → `pmic_glink_altmode_pdr_notify()` é chamado → agenda `enable_work`
- `enable_work` envia `ALTMODE_PAN_ENABLE` ao firmware ADSP
- Naquele teste, o firmware não respondeu com `USBC_NOTIFY` quando o dock TB3
  estava conectado
- Sem `USBC_NOTIFY`, o driver não programa o PS8833 retimer para nenhum modo

Isso descreve o sintoma daquele caminho sem host-router; não prova uma limitação
do firmware nem substitui o bloqueio de driver identificado depois.

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

Não religar essa rota antes de existir um host-router real; ela já causou Oops e
não tem como criar o domínio ausente.

## O que o dock precisa para funcionar

O Elgato TB3 Dock tem **tudo** (USB hub, ethernet, HDMI 2.0) atrás do túnel Thunderbolt.
Sem TB3 ativo, só acessa: carga PD + interface Billboard (inútil).

Para funcionar completamente precisa:
1. Driver host/router USB4 no kernel + nó NHI/router correspondente no DT
2. DT/PHY/graph alinhados ao stack público de USB4 para `x1e80100`
3. `typec_thunderbolt.ko` conseguir negociar altmode
4. boltctl autorizar o dispositivo

## DKMS experimental: somente instrumentação passiva

Um overlay não pode antecipar uma ABI de driver que ainda não existe. O módulo
`vivobook_usb4_fix` continua servindo para logs, sempre com a rota de escrita
desligada:

```text
dry_run=1 attempt_usb4=0 emulate_tb3_port_ops=0
```

Não habilitar `attempt_usb4` ou a emulação sintética. Além do Oops já observado,
uma falha parcial ao programar switch/mux/retimer pode deixar o caminho em estado
inconsistente até a desconexão. Corrigir esse experimento não criaria o
host-router e, portanto, não avançaria o tunneling.

## Alternativa funcional: DP Alt Mode direto

Um dock/adaptador USB-C que não dependa de túnel já foi validado. USB3 a
10 Gbps, 2.5GbE, carga e DP funcionam pelo caminho DWC3/QMP/PS8833 atual, sem
host-router USB4.

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

## Estado fechado em 2026-08-24

O tunneling ainda não pode funcionar, mas a investigação avançou muito além do
diagnóstico de março: a preparação NHI não-PCI já foi mergeada, apareceu uma
série PHY USB4 pública e o firmware do MCU foi recuperado do driver Windows.
O bloqueio que continua absoluto é o **driver Qualcomm do host-router**, junto
da ABI/DT final que ele consumirá.

| Recurso | Status atual |
|---------|--------------|
| USB3 SuperSpeed via USB-C | ✅ Funciona a 10 Gbps |
| DP Alt Mode | ✅ Funciona |
| Firmware do MCU USB4 | ✅ Localizado e extraído do driver Windows |
| PHY USB4/TBT no upstream | 🟡 Série v4 pública, ainda não mergeada |
| Host-router Qualcomm no upstream | ❌ Driver ainda não publicado |
| **USB4 / TB3 tunneling** | ❌ Sem domínio/driver para criar o túnel |

### Prova ao vivo no notebook

Toda a validação abaixo foi somente leitura via SSH, sem carregar módulo, mudar
sysfs/debugfs ou reiniciar:

```text
kernel                         7.2.0-x1407qa
compatible                     qcom,x1p42100 (Purwa)
CONFIG_USB4                    is not set
/sys/bus/thunderbolt           ausente
QMP fd5000/fda000 clock-names  aux,ref,com_aux,usb3_pipe
host-router no DT              ausente
```

O `clk_summary` é uma contraprova útil: todos os clocks HR0/HR1 e
`gcc_usb4_{0,1}_phy_p2rr2p_pipe_clk` existem no provider, mas estão desligados,
com contagem zero e consumer `deviceless`. USB3/DP usam os mesmos QMPs e estão
ativos. Portanto o silício e a infraestrutura GCC existem; faltam consumidores
DT/driver.

### Upstream avançou, mas ainda não chegou ao driver

- A série [non-PCI NHI prep v4](https://patchew.org/linux/20260515-topic-usb4._5Fnonpcie._5Fprepwork-v4-0-5c818378243e@oss.qualcomm.com/)
  foi mergeada em 2026-05-21. Ela remove pressupostos PCI da parte comum, mas
  não adiciona um probe Qualcomm; `CONFIG_USB4` ainda depende de PCI.
- A série [QMP USB4 PHY v4](https://lkml.iu.edu/hypermail/linux/kernel/2608.2/08363.html)
  foi postada em 2026-08-20. Ela adiciona `PHY_MODE_TBT`, o terceiro PHY USB4,
  tabelas Hamoa/Purwa e `p2rr2p_pipe`; ainda não está no master.
- O cover da própria série diz que o driver do host-router será publicado
  separadamente. Não há objeto Qualcomm em `drivers/thunderbolt/` no master,
  linux-next ou árvore do mantenedor.
- O quirk `UCSI_USB4_IMPLIES_USB` já está no kernel instalado e associado a
  `qcom,x1e80100-pmic-glink`; ele resolve enumeração UCSI, não substitui o HR.

Purwa inclui `hamoa.dtsi`, então os patches PHY aplicados ao Hamoa alcançam os
QMPs `fd5000`/`fda000` desta máquina automaticamente. Não se deve trocar o
compatible existente nem inventar um nó `qcom,x1p42100-usb4-hr`: o RFC só
define `qcom,x1e80100-usb4-hr` e ainda não é ABI aceita.

### Windows: identidade e arquitetura do bloco

O dump `windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst` fecha a cadeia:

| Item | Valor | Origem |
|------|-------|--------|
| Bus enumerador | `ACPI\QCOM0C6D` | `QcUsb4Bus8380.inf` |
| PDO padrão criado pelo bus | `ACPI\ACPI0015` / `USB4\QCOM0CD10001` | `QcUsb4Bus8380.sys` |
| Host router | driver USB4 genérico da Microsoft | `usb4hostrouter.inf` |
| Cola Qualcomm | bus dinâmico + lower filter | `QcUsb4Bus8380` / `QcUsb4Filter8380` |
| Instâncias de PHY/router | `QCOM0C8B\0`, `QCOM0C8C\1`, `QCOM0D07\2` | paths de preset no filter |

O filter reconhece janelas NHI `0x1563f000`, `0x1573f000` e `0x1553f000` e
mapeia os containers de 1 MiB `0x15600000`, `0x15700000` e `0x15500000`.
Também mapeia os QMPs `0xfd5000`, `0xfda000` e `0xfdf000`. Isso corrige a
hipótese anterior de que a segunda instância teria base `0x15800000`.

O [BSP/BIOS 314 oficial da ASUS](https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/DriverPackage/50054/SOCPackage_forWebSite_Qualcomm_Z_V1.314.8800.0_50054.exe),
SHA-256 publicado e verificado
`caf0cbd096a4eca8788f4a910a4d34ca1c2174b9e0875d0feaada7fa45356f17`,
é a mesma versão instalada. O capsule confirma `SCP_PURWA`, reserva USB4 de
3 MiB em `0x15500000`, três SIDs (`0x1440`, `0x1480`, `0x14c0`), três QMPs e
os retimers PS8833 da placa. Isso prova presença/configuração do hardware, não
fornece um driver Linux.

A DSDT do mesmo capsule fecha também os `_CRS` das duas portas físicas. Ambas
têm `_CID = ACPI0015`; os números abaixo são GSIs ACPI e, entre parênteses, o
SPI do GIC (`GSI - 32`):

| Porta | NHI `_CRS` | ring | wake | firmware | `PSET` |
|-------|------------|------|------|----------|--------|
| PRT0 / HR0 | `0x1563f000`, len `0xbffff` | 504 (SPI 472) | 287 (SPI 255) | 611 (SPI 579) | buffer `{0x6f}` |
| PRT1 / HR1 | `0x1573f000`, len `0xbffff` | 637 (SPI 605) | 555 (SPI 523) | 639 (SPI 607) | buffer `{0x6f}` |

HR0 ring/firmware coincide exatamente com os SPI 472/579 do RFC. A terceira
interrupção é wake e não aparece no binding RFC de duas IRQs. Isso permite
revisar um futuro DTS de HR1 sem inferir stride, mas ACPI e o BSP continuam sem
definir a ABI Linux de graph/power-contract.

### Correção decisiva: o firmware está embutido no filter

A conclusão anterior de que as strings eram apenas um catálogo de trace estava
errada. O código ARM64 do `QcUsb4Filter8380.sys` aponta diretamente para um
stream de `0x9f70` bytes em `.data`, interpreta records e escreve cada DWORD em
MMIO. As três versões do filter têm código, dados e firmware idênticos.

No filter `1.0.4458.2600`:

```bash
SYS=QcUsb4Filter8380.sys
dd if="$SYS" of=/tmp/qcusb4-fw-stream.bin bs=1 \
  skip=$((0x4b9c0)) count=$((0x9f70))
```

Formato little-endian do stream:

```text
<u32 destino><u32 quantidade_de_dwords><payload> ...

record 0: dest 0x0000, 0x1ea0 dwords -> HR + 0x13000, 0x7a80 bytes
record 1: dest 0x8000, 0x0938 dwords -> HR + 0x1b000, 0x24e0 bytes
```

Hashes reproduzidos localmente:

| Artefato | SHA-256 |
|----------|---------|
| stream `0x9f70` | `cd4f5929b51f2dbb0b583693ff8d024521c87f0d2e45c7adc142fed976650b99` |
| payload 0 | `6fa1aa966d7159c3997fef3c40438dea98927a10c863854341299ff36f905d08` |
| payload 1 | `d504c63d69c447b43a86ffc7721ef5a4ad6fe502fc09b90f6b08e15544a9caaa` |

O payload contém código e dados do MCU, `Qualcomm, Inc.`, `SC8380`,
USB4/TBT3/DROM/HSE/PMEM/DMEM/VUIC e o build
`Nov 24 2024 17:03:31`. O loader limpa `HR+0x22000`, preserva o intervalo
`HR+0x1aa80..0x1afff`, carrega os dois segmentos e executa a sequência de
wake/readiness.

O stream inteiro **não** pode ser passado a uma única `memcpy_toio()`: isso
copiaria os headers e fecharia indevidamente o buraco de `0x580` bytes. Um port
deve interpretar os dois records ou copiar somente os payloads nos destinos
acima. O Windows usa writes little-endian de 32 bits com barreira; a largura e
a ordenação precisam ser confirmadas no driver Linux, não presumidas.

Não foi dado um nome/licença redistribuível ao blob. Por isso ele não foi
adicionado a `firmware/`; os comandos e hashes permitem reproduzir a extração
do dump local quando a interface do driver público definir o formato esperado.

### Limite técnico atual

O firmware deixa de ser peça perdida, mas **não é executável sozinho**. Ainda
faltam publicamente:

1. driver Qualcomm de plataforma/NHI, resets, MCU, mailbox e PM;
2. binding definitivo e graph Type-C/retimer/native protocols;
3. DTS das duas instâncias para Purwa/esta placa;
4. RCs/adaptadores PCIe de tunneling e integração DP final.

Aplicar apenas a série PHY v4 produziria infraestrutura sem consumer. Criar um
HR por overlay sem o driver é inócuo; adivinhar propriedades/IRQs pode travar o
boot. Não existe ajuste seguro de runtime que feche o túnel hoje. O próximo
teste funcional começa quando o driver Qualcomm for publicado; instalar o
kernel/DTB resultante exigirá reinicialização. **Não há razão para reiniciar
agora.**

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

**Vídeo: funciona.** Retestado com um monitor portátil Type-C na mesma porta 0.
`card0-DP-1` subiu `connected`/`enabled` e passou a dirigir modo real no `crtc-1`
— o DP alt mode engata através do dock. (No primeiro teste, sem monitor, os dois
conectores ficaram `disconnected` e o plug não gerou evento de DP/altmode/HPD
nenhum; isso era ausência de display, não falha.)

Duas armadilhas de diagnóstico que valem registro:

- `port0-partner/number_of_alternate_modes` continua **`0` mesmo com o DP
  rodando**, porque quem dirige o DP é o `pmic_glink_altmode`, fora da banda do
  UCSI. Lista de altmode do partner vazia **não** é prova de que o DP falhou —
  olhar o conector DRM, não o UCSI.
- o conector não tem `mst_path`: o dock entrega o DP numa lane direta, não pelo
  MST hub VMM8431 dele.

### O monitor não dá imagem em 960x640 — é o EDID dele, não o driver

**Sintoma:** no plug o monitor mostra **"No Signal"**, enquanto o lado do OS
reporta sucesso completo:

```
card0-DP-1: connected, dpms=On, EDID lido (256 bytes)
crtc-1      mode: "960x640": 60 49160 ...   active=1
plane-1     fb=119  960x640  allocated by = gnome-shell
```

Zero erro de `msm_dp` no dmesg. Pipeline DRM inteiro montado e varrendo
framebuffer — e tela preta.

**Causa:** o **DTD 1 do bloco base é 960x640**, e o EDID 1.4 define o primeiro
detailed timing como o modo nativo/preferido. Kernel e GNOME honram o que o
monitor declara (ambos marcam `960x640` como `is-preferred`) — só que o painel
não consegue travar esse timing.

**Fix:** escolher qualquer modo são. `1920x1080@60` deu imagem na hora. O GNOME
persiste em `~/.config/monitors.xml` chaveado pelo serial do monitor, então
reaplica sozinho no próximo plug.

O EDID é auto-contraditório, como é comum em painel Type-C barato:

| Campo | Valor |
|-------|-------|
| Fabricante / modelo | `DRS` / `9557`, nome do produto literalmente `TYPE-C` |
| Tamanho no bloco base | 29 cm x 17 cm; DTD 1 diz 293 x 165 mm |
| Tamanho nas DTD da extensão | 160 x 90 mm em **todas** |
| DTD 1 (nativo declarado) | 960x640 @ 60 — **não produz imagem** |
| DTD 2 (bloco CTA) | 2560x1600 @ 60, 268.63 MHz |
| Max dotclock declarado | 280 MHz |

Não há fix de kernel a fazer: o driver está correto, o EDID é que mente.

### Três armadilhas de diagnóstico

Valem para qualquer display USB-C nesta máquina:

1. `port0-partner/number_of_alternate_modes` fica **`0` mesmo com o DP rodando** —
   quem dirige o DP é o `pmic_glink_altmode`, fora da banda do UCSI. Lista de
   altmode do partner vazia **não** é prova de que o DP falhou; olhar o conector
   DRM, não o UCSI.
2. O atributo `edid` do sysfs faz `stat` como **0 bytes** mas lê 256 de verdade.
   Checar tamanho com `[ -s ... ]` reporta "sem EDID" num link que tem EDID bom.
3. Pipeline DRM montado prova que o **kernel** está satisfeito, não que chega luz
   no painel. `connected` + framebuffer vivo + "No Signal" = problema de modo,
   não de link.

Conclusão: um dock USB-C que não dependa de túnel entrega hub 10 Gbps + 2.5GbE +
carga + saída de vídeo hoje, sem kernel custom e sem driver faltando. O Elgato TB3 continua sem
solução porque roteia *tudo* por dentro do túnel Thunderbolt.

**Próximo passo aprovado em março de 2026 — supersedido.**

Já existe preparação pública NHI e PHY, mas ainda não existe um patch stack
completo que possa produzir tunneling. Buildar kernel custom hoje só permitiria
testar infraestrutura sem consumer; não criaria `/sys/bus/thunderbolt`.

`docs/research/2026-03-24-usb4-custom-kernel-plan.md` e
`docs/research/2026-03-24-usb4-upstream-patch-checklist.md` continuam válidos
como *procedimento*, para o dia em que a série sair. Não são acionáveis agora.

**O que dá para fazer enquanto isso:**

- usar dock USB-C sem túnel (USB3 + DP alt mode funcionam);
- acompanhar a série Qualcomm e `westeri/thunderbolt.git`;
- reabrir quando `drivers/thunderbolt/Makefile` ganhar um objeto Qualcomm e a
  série trouxer driver + binding/DT compatíveis;
- então aplicar NHI + PHY + HR/DT, compilar, instalar e reiniciar uma única vez
  para o primeiro teste real.

## Artefatos iniciados no repositório

- `diagnose-usb4.sh` — coleta o estado atual de Type-C, altmodes, USB, logs e UCSI debugfs
- `install-usb4-role-fix.sh` — workaround histórico do `data_role` no 6.19.8;
  não revalidado como necessário no 7.2
- `modules/vivobook-usb4-fix-1.0/` — base DKMS experimental para instrumentação do caminho Type-C/retimer
