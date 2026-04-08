# Upstream Status — 2026-04-07

Pesquisa de novidades relevantes para o projeto Vivobook X1407QA (Snapdragon X / Purwa).

---

## Câmera CAMSS — x1e80100 (Bryan O'Donoghue / Linaro)

### O que foi enviado

| Série | Data | Patches | Cobertura |
|-------|------|---------|-----------|
| v8 | 2026-02-25 | 18 patches | dt-bindings + dtsi CAMSS x1e80100 |
| v9 | 2026-02-26 | 7 patches | dt-bindings reduzidos + PHY API |
| x1e/Hamoa DTSI | 2026-02-26 | 11 patches | CAMSS+CAMCC+CSIPHY+CCI por device |

**Referências LKML:**
- [v8 00/18](https://lkml.org/lkml/2026/2/25/1157)
- [v9 0/7](https://lkml.org/lkml/2026/2/26/1172)
- [Hamoa DTSI 00/11](https://lkml.org/lkml/2026/2/26/1238)

### Status

- v8/v9: **em review**, não merged. Feedback de Dmitry Baryshkov e Krzysztof Kozlowski.
- Patchwork v5 (março 2025): marcado como **Superseded** pelas versões mais novas.
- Sem indicação de merge em 6.14, 6.15 ou 6.16.

### Dispositivos suportados pelos patches Hamoa

- Dell Inspiron 14p
- Lenovo ThinkPad T14s
- Lenovo Yoga Slim7x
- x1 CRD

Inclui **OV02C10 no CSIPHY4** — mesmo sensor do Vivobook, mas só para plataforma
x1e80100 (Hamoa).

### Impacto para o Vivobook X1407QA (Purwa / x1p42100)

**Nenhum.** Os patches são 100% focados em x1e80100. x1p42100 (Purwa) não está
incluído em nenhuma série enviada. Mesmo após o merge, precisaríamos de patches
específicos para x1p42100 (ou portar o DTSI do Hamoa para Purwa manualmente via
overlay — o que já fazemos com `vivobook-cam-fix-2.0`).

---

## Linux 6.16 — Snapdragon X

- **x1p42100 (Snapdragon X Plus 8-core) habilitado** como plataforma suportada.
- **ASUS Zenbook A14** adicionado como novo device (mesmo die Purwa).
- Dell XPS 13 9345 e Lenovo ThinkPad T14s: DisplayPort externo habilitado.
- **Câmera: não incluída.**

Fonte: [Phoronix — Linux 6.16 SoCs](https://www.phoronix.com/news/Linux-6.16-SoCs)

---

## CDSP/NPU — Headers DSP

**Qualcomm fechou a issue sobre open-source dos headers DSP Snapdragon X.**

Não vão liberar os headers que permitiriam uso genérico do CDSP com aplicações
existentes (FastRPC userspace, frameworks de ML etc.).

**Alternativa proposta:** novo driver kernel **QDA (DSP Accelerator)** para o
subsistema `accel/`. Oferece FastRPC via RPMsg, suporta todos os domínios DSP
(ADSP, CDSP, SDSP, GDSP). Mas não é compatível com o stack tradicional de
fastrpc — é uma interface nova, específica para o driver.

Impacto: o `qccdsp8380.mbn` que já colocamos no initramfs continua sendo o
necessário para manter o CDSP online. Não há caminho claro para usar o CDSP
como acelerador de propósito geral no Linux por ora.

Fontes:
- [Qualcomm DSP headers — VideoCardz](https://videocardz.com/newz/qualcomm-shuts-door-on-snapdragon-x-dsp-headers-open-sourcing-linux-support-hopes-fade)
- [Qualcomm QDA driver — Phoronix](https://www.phoronix.com/news/Qualcomm-DSP-Accel-Driver)

---

## Mesa MR 37622

- Título: **"device-select: Fix error check."** (Bas Nieuwenhuizen)
- Criado: 2025-09-29, branch `device-select-crash-fix` → `main`
- Status: provavelmente merged — CLAUDE.md já documenta funcionamento no Mesa 25.3.6.
- `VK_DRIVER_FILES` ainda necessário (LVP carrega sem o override, degradando rendering).

---

## Resumo executivo

| Item | Status | Impacto |
|------|--------|---------|
| CAMSS x1e80100 v9 | Em review, não merged | Nenhum (é Hamoa, não Purwa) |
| CAMSS Purwa patches | Não existem | Câmera continua via nosso DKMS |
| Linux 6.16 | x1p42100 habilitado, sem câmera | Positivo (plataforma reconhecida) |
| CDSP headers | Qualcomm não vai abrir | CDSP continua via firmware only |
| QDA driver | Proposta nova, interface diferente | Não resolve stack atual |
| Mesa MR 37622 | Provavelmente merged | Já funcionando no setup atual |
