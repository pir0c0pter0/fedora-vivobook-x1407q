# USB4 / TB3 — Checklist Exata do Patch Stack Upstream

**Data:** 2026-03-24
**Status:** mapa de dependências públicas para o primeiro kernel USB4/TB3 testável no X1407QA

---

## Resumo curto

Hoje o bloqueio real para o Elgato TB3 Dock é este:

1. **a peça central ainda não foi publicada**: driver Qualcomm do host/router USB4
2. **o resto do stack já pode ser separado em pré-requisitos públicos**:
   clocks/resets, UCSI quirks, graph Type-C/retimer e follow-ups de DP/PHY
3. **o X1407QA ainda não tem DTS público próprio** para a topologia USB4/TB3

Ou seja: já dá para preparar a fila de cherry-picks, mas ainda não dá para
montar um kernel funcional só com patches públicos porque falta justamente o
driver do host/router.

## Checklist por subsistema

| Subsystem | Série / patch público | Estado (Mar/2026) | Impacto prático | Ação |
|-----------|------------------------|-------------------|-----------------|------|
| `drivers/thunderbolt/` + `Documentation/devicetree/bindings/thunderbolt/` + `arch/arm64/boot/dts/qcom/` | RFC `dt-bindings: thunderbolt: Add Qualcomm USB4 Host Router` | **Bloqueador principal**. Só o binding RFC apareceu; o driver ainda não foi publicado. Na revisão, pediram bindings + driver juntos e um exemplo completo do sistema. | Sem isso, `/sys/bus/usb4/` não aparece e o dock fica preso em Billboard/fallback. | Monitorar a série do Konrad ou qualquer branch pública com o driver. Sem isso, não vale buildar um kernel `.usb4` esperando tunneling real. |
| `drivers/usb/typec/ucsi/ucsi.c` | `usb: typec: ucsi: Add UCSI_USB4_IMPLIES_USB quirk for X1E80100` | **Público, ainda em review**. Qualcomm postou em 2026-03-12; Heikki respondeu positivamente em 2026-03-13. | Corrige o caso em que o firmware marca `USB4_GEN3` mas não marca `PARTNER_FLAG_USB`, evitando `ROLE_NONE` em dock USB4. | Carregar esse patch se a base escolhida ainda não o tiver. É o primeiro cherry-pick claro fora do host router. |
| `drivers/usb/typec/ucsi/ucsi_glink.c` | match data para `qcom,x1e80100-pmic-glink` / quirk `UCSI_DELAY_DEVICE_PDOS` | **Público** e já faz parte da linha de base moderna do X1E. | Garante o comportamento específico de UCSI/PMIC GLINK para a plataforma. | Verificar se o kernel base já contém esse suporte; se não, portar junto do patch acima. |
| `drivers/clk/qcom/` + `include/dt-bindings/clock/` + `arch/arm64/boot/dts/qcom/` | `X1E GCC USB4 clock fix-ups` | **Público** e já apareceu em changelogs estáveis recentes. | Entrega clocks/resets básicos do bloco USB4. Sem isso, o host/router não sobe mesmo com driver. | Tratar como pré-requisito obrigatório da base. Se faltar, cherry-pickar antes do driver USB4. |
| `drivers/clk/qcom/dispcc-x1e80100.c` | `dt-bindings: clock: qcom: x1e80100-dispcc: Add USB4 router link resets` + `clk: qcom: dispcc-x1e80100: Add USB4 router link resets` | **Público**. Série focada em DP tunneling sobre USB4. | Leva resets adicionais usados pela rota de link DP via USB4 router. | Carregar se a série do host/router ou do DP tunneling depender disso e a base ainda não tiver. |
| `drivers/gpu/drm/msm/dp/` + DTS `x1e80100` | `x1e80100: Describe the full "link" region of DP hosts` | **Público**. Série ligada a DP sobre USB4. | Expõe o bloco completo de link dos hosts DP, que passa a importar quando o túnel USB4/DP entra na jogada. | Manter na lista de dependências prováveis do primeiro enablement real. |
| `drivers/phy/qualcomm/` + `Documentation/devicetree/bindings/phy/` | `dt-bindings: phy: qcom,sc8280xp-qmp-usb43dp-phy: Document X1E80100 compatible` | **Aceito** desde 2023-12-07. | Confirma que o suporte público do PHY já existe e que o X1E entra no binding USB43DP. | Não inventar um `compatible` local fora do upstream. O caveat é que o arquivo do binding é `usb43dp`, mas o `compatible` público do X1E continua `qcom,x1e80100-qmp-usb3-dp-phy`. |
| `Documentation/devicetree/bindings/phy/` + `drivers/phy/qualcomm/phy-qcom-qmp-combo.c` | follow-ups de `usb-switch` / `mode-switch` e mapeamento de lanes no QMP combo | **Públicos**, mas em parte ainda em review. | Servem para descrever corretamente complexos USB-C/DP mais completos. | Tratar como bucket de verificação, não como P0. O Fedora 6.19 já faz DP alt-mode; então aqui a regra é portar só o que a série do host/router realmente exigir. |
| `drivers/usb/typec/mux/` + `drivers/usb/typec/retimer/` + DTS de placas X1E/X1P | séries públicas de PS8830/PS8833, CRD/T14s external DP e ASUS Vivobook S15 USB-C/retimer | **Públicas**. Já existem exemplos de graph/retimer próximos do hardware que nos interessa. | Mostram como ligar conector, retimer, DP controller e USB controller no DT. | Usar como referência para o port local do X1407QA quando o host/router existir. Hoje não substituem o driver Qualcomm ausente. |
| `arch/arm64/boot/dts/qcom/` | DTS específico do X1407QA para USB4/TB3 | **Inexistente publicamente**. | Sem isso, mesmo com o driver, ainda faltará a cola exata da placa. | Preparar port local a partir das séries CRD/T14s/Vivobook S15 assim que houver o driver do host/router. |

## O que já pode entrar na fila de cherry-pick

### Prioridade P0

- Série do **host/router USB4 Qualcomm** quando ela finalmente aparecer
- DTS/DT binding que vierem junto com essa série

### Prioridade P1

- `usb: typec: ucsi: Add UCSI_USB4_IMPLIES_USB quirk for X1E80100`
- `X1E GCC USB4 clock fix-ups` se a base escolhida ainda não tiver

### Prioridade P2

- `dispcc-x1e80100: Add USB4 router link resets`
- `x1e80100: Describe the full "link" region of DP hosts`
- follow-ups de `mode-switch`/lane mapping no QMP combo, mas só se a série real depender deles

## O que NÃO é mais hipótese principal

- **Trocar manualmente o `compatible` do PHY para `qcom,x1e80100-qmp-usb43dp-phy`**.
  Isso não aparece no binding público aceito para X1E. O nome do arquivo YAML é
  `usb43dp`, mas o `compatible` público segue `qcom,x1e80100-qmp-usb3-dp-phy`.
- **Insistir em altmode sintético como caminho final**.
  Esse caminho já provou só servir para debug e ainda bate no `ps883x`.
- **Buildar kernel renomeado sem patch real**.
  Continua sem valor; o helper `build-usb4-kernel.sh` já recusa isso.

## Port local que ainda vamos ter que fazer

Quando a série do host/router aparecer, o X1407QA ainda vai precisar de:

- nós USB4/host-router ligados às duas portas (`a600000.usb` e `a800000.usb`)
- graph completo entre controller USB, controller DP, conector USB-C e retimer
- validação das duas instâncias PS8833 da placa
- revisão do caminho UCSI/role switch com o dock real

## Monitoramento prático

Buscar por estes termos:

- `Qualcomm USB4 Host Router`
- `x1e80100 usb4 hr`
- `UCSI_USB4_IMPLIES_USB`
- `x1e80100-dispcc USB4 router link resets`
- `Describe the full "link" region of DP hosts`

Quando aparecer uma série testável:

1. salvar em `~/rpmbuild/SOURCES/usb4-*.patch`
2. rodar `bash prepare-usb4-kernel.sh`
3. rodar `bash build-usb4-kernel.sh`

## Referências

- Qualcomm USB4 Host Router RFC bindings:
  - https://lists.openwall.net/linux-kernel/2025/09/16/1588
  - https://lists.openwall.net/linux-kernel/2025/09/16/1789
  - https://lists.openwall.net/linux-kernel/2025/09/17/262
- Árvore Thunderbolt atual, ainda sem driver Qualcomm específico:
  - https://kernel.googlesource.com/pub/scm/linux/kernel/git/westeri/thunderbolt/+/refs/heads/master/drivers/thunderbolt/
- UCSI quirks:
  - https://www.spinics.net/lists/linux-usb/msg270684.html
  - https://www.spinics.net/lists/kernel/msg6093384.html
  - https://www.spinics.net/lists/kernel/msg6096047.html
- Clocks / resets / DP link:
  - https://www.spinics.net/lists/devicetree/msg851575.html
  - https://www.spinics.net/lists/devicetree/msg869631.html
  - https://www.spinics.net/lists/devicetree/msg854670.html
- PHY / QMP combo:
  - https://patches.linaro.org/project/linux-devicetree/patch/20231201-x1e80100-phy-combo-v1-1-6938ec41f3ac@linaro.org/
  - https://lkml.org/lkml/2025/8/7/846
  - https://lkml.org/lkml/2025/9/8/982
- Exemplos públicos de graph / retimer / USB-C em placas próximas:
  - https://www.spinics.net/lists/devicetree/msg706149.html
  - https://lkml.org/lkml/2024/9/3/293
  - https://lkml.org/lkml/2025/11/3/268
