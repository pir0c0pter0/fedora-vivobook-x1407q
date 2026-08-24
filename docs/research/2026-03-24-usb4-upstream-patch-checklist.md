# USB4 / TB3 — Checklist Exata do Patch Stack Upstream

**Criado:** 2026-03-24 · **Reverificado:** 2026-08-24

**Alvo real:** X1P42100/Purwa, herdando os blocos USB de `hamoa.dtsi`

**Status:** ainda não existe um stack público funcional; não buildar nem reiniciar

## Resumo

O trabalho público avançou, mas ainda termina antes da peça que cria o domínio
USB4:

1. a preparação genérica para NHI não-PCI foi mergeada;
2. o PHY USB4/TBT3 de Hamoa/Purwa foi publicado em v4, mas ainda está em review;
3. o quirk UCSI e clocks/resets já estão no kernel instalado;
4. o driver Qualcomm do host-router e sua ABI/DT final continuam inéditos.

O dump Windows e o BIOS 314 resolveram identidade, firmware e parte importante
do mapa de hardware. Eles não substituem o driver de plataforma, mailbox, PM e
integração Type-C que ainda faltam.

## Checklist por subsistema

| Subsistema | Estado em 2026-08-24 | Evidência / impacto | Ação |
|------------|----------------------|---------------------|------|
| NHI comum não-PCI | **Mergeado** em 2026-05-21 | Commits `8c3ff7c5ae15`, `e241d98e04ef`, `dd60fb487e55`, `15bcac35ba04`; a série foi testada pela Qualcomm em X1E CRD com driver privado e monitor TB3 | Usar como base futura; sozinho não cria probe Qualcomm |
| Host-router Qualcomm | **Bloqueador, não publicado** | O RFC descreve MMIO/MCU e um exemplo HR0; não há objeto Qualcomm em `drivers/thunderbolt/` | Esperar driver + binding revisado; não reconstruir por tentativa |
| QMP USB4/TBT PHY | **v4 pública, não mergeada** | Adiciona `PHY_MODE_TBT`, `QMP_USB43DP_USB4_PHY`, tabelas USB4/TBT3 e `p2rr2p_pipe`; testada no X1E CRD | Aplicar somente junto de um stack HR testável |
| UCSI `USB4_IMPLIES_USB` | **Mergeado e presente no 7.2 instalado** | `ucsi_glink.c` aplica `UCSI_DELAY_DEVICE_PDOS | UCSI_USB4_IMPLIES_USB` ao X1E/Purwa herdado | Nenhum cherry-pick necessário |
| GCC/DISPCC USB4 | **Mergeado e presente** | Clocks HR0/HR1/P2RR2P existem no `clk_summary`, mas ficam 0/`deviceless` sem DT/driver | Nenhuma ação isolada |
| DT QMP de Hamoa/Purwa | **Patch v4 em review** | O DT vivo tem só quatro clocks e PHY índice 0 para USB3; falta quinto clock/índice 2 | Virá da série PHY, herdida por `purwa.dtsi` |
| DT host-router | **Incompleto publicamente** | O DT vivo não tem HR. O RFC fornece HR0; graph/power-contract e DTS de placa ainda não fecharam | Esperar a série do driver; não inventar ABI |
| Firmware MCU | **Extraído do filter Windows** | Dois payloads em `.data`, carregados em `HR+0x13000` e `HR+0x1b000`; hashes documentados na investigação principal | Manter extração reproduzível; definir nome/formato só quando o driver publicar a interface |
| Recursos Purwa/placa | **Parcialmente recuperados** | Filter e BIOS confirmam routers `0x15600000`, `0x15700000`, `0x15500000`, QMPs e SIDs | Usar para revisar a futura série, não para ativar overlay hoje |

## O que existe no notebook hoje

```text
compatible                     qcom,x1p42100
kernel                         7.2.0-x1407qa
CONFIG_USB4                    is not set
/sys/bus/thunderbolt           ausente
QMP fd5000/fda000              USB3+DP, quatro clocks
host-router no DT              ausente
clocks USB4 HR/P2RR2P          presentes, desligados, deviceless
```

Purwa inclui `hamoa.dtsi`; manter
`compatible = "qcom,x1e80100-qmp-usb3-dp-phy"` é correto. O nome do binding
USB43DP não autoriza inventar `qcom,x1e80100-qmp-usb43dp-phy` nem
`qcom,x1p42100-usb4-hr`.

## Lacuna exata de DT

Para cada uma das duas portas físicas, o DT atual já liga:

```text
DWC3 USB3 ─┐
DP host ───┼─ QMP USB3/DP ─ PS8833 ─ conector Type-C
SBU ───────┘
```

A série PHY v4 acrescenta o quinto clock `p2rr2p_pipe` e um terceiro handle PHY
no mesmo QMP. O driver HR deverá consumir esse handle; o DWC3 continua sendo o
native USB3 protocol adapter.

O RFC publica para HR0 a janela `0x15600000` (NHI em `0x1563f000`), SID
`0x1440`, IRQs SPI 472/579, clocks, resets e PHY fd5000 índice 2. A engenharia
reversa confirma ainda:

| Índice | Container HR | NHI visto pelo Windows | QMP | SID do BIOS |
|--------|--------------|-------------------------|-----|-------------|
| 0 | `0x15600000` | `0x1563f000` | `0xfd5000` | `0x1440` |
| 1 | `0x15700000` | `0x1573f000` | `0xfda000` | `0x1480` |
| 2 | `0x15500000` | `0x1553f000` | `0xfdf000` | `0x14c0` |

Esses dados corrigem a antiga extrapolação de HR1 em `0x15800000`. A DSDT do
BIOS 314 fornece ainda os GSIs exatos: HR0 ring/wake/fw = 504/287/611 (SPI
472/255/579); HR1 = 637/555/639 (SPI 605/523/607). Isso ainda não autoriza um
nó ativo: faltam a ABI Linux/graph final, integração `usb4-host-interface`, RCs
PCIe tunelados e o driver que define o contrato.

## Firmware recuperado

No `QcUsb4Filter8380.sys` 1.0.4458.2600, o stream fica em raw `0x4b9c0`, mede
`0x9f70` e tem SHA-256:

```text
cd4f5929b51f2dbb0b583693ff8d024521c87f0d2e45c7adc142fed976650b99
```

Ele contém dois records little-endian:

- payload 0: raw `0x4b9c8`, `0x7a80` bytes → `HR+0x13000`;
- payload 1: raw `0x53450`, `0x24e0` bytes → `HR+0x1b000`.

Não copiar o container inteiro com uma `memcpy_toio()`: os headers não são
firmware e o loader Windows preserva um intervalo de `0x580` bytes entre os
destinos. Ver comandos e hashes individuais em `USB4-TB3-investigation.md`.

## Ordem futura do patch stack

Quando o driver Qualcomm for publicado, a ordem mínima de revisão/build será:

1. base contendo a preparação NHI não-PCI;
2. série QMP USB4 PHY/P2RR2P;
3. driver Qualcomm HR + binding da mesma revisão;
4. DTS Hamoa/Purwa e board graph exigidos pelo driver;
5. firmware no nome/formato que o driver declarar;
6. somente então habilitar `CONFIG_USB4`, compilar e instalar.

Não preparar patch local de HR antes do passo 3: qualquer propriedade inventada
será descartável e pode programar MMIO/reset incorreto.

## Go / No-Go

### Go

Prosseguir para build e reboot somente se todos forem verdadeiros:

- existe fonte pública do driver Qualcomm no patch stack;
- binding e DTS de exemplo correspondem à mesma revisão;
- a série PHY exigida aplica na mesma base;
- o driver define como solicita/carrega o firmware;
- os recursos de ambas as portas podem ser comparados ao BIOS/Windows acima.

### No-Go atual

- só NHI genérico ou só PHY v4 disponível;
- apenas binding RFC sem driver;
- tentativa baseada em altmode sintético ou escrita manual no PS8833;
- nó HR fabricado a partir de stride/endereço presumido.

## Referências

- [Non-PCI NHI prep v4](https://patchew.org/linux/20260515-topic-usb4._5Fnonpcie._5Fprepwork-v4-0-5c818378243e@oss.qualcomm.com/)
- [QMP USB4 PHY v4 — cover](https://lkml.iu.edu/hypermail/linux/kernel/2608.2/08363.html)
- [QMP USB4 PHY v4 — binding/índice](https://lkml.iu.edu/hypermail/linux/kernel/2608.2/08365.html)
- [QMP USB4 PHY v4 — suporte preliminar](https://lkml.iu.edu/hypermail/linux/kernel/2608.2/08368.html)
- [QMP USB4 PHY v4 — config Hamoa](https://lkml.iu.edu/hypermail/linux/kernel/2608.2/08369.html)
- [QMP USB4 PHY v4 — P2RR2P no DTS](https://lkml.iu.edu/hypermail/linux/kernel/2608.2/08370.html)
- [Qualcomm USB4 Host Router RFC](https://patchew.org/linux/20250916-topic-qcom._5Fusb4._5Fbindings-v1-1-943ecb2c0fa7@oss.qualcomm.com/)
- [Hamoa mainline](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/arm64/boot/dts/qcom/hamoa.dtsi)
- [Purwa mainline](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/arm64/boot/dts/qcom/purwa.dtsi)
- [Investigação principal](../../USB4-TB3-investigation.md)
