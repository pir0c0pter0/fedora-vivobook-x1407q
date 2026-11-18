# Retomada — Yoga Slim 7 14Q8Y11 / X2 Plus

Atualizado em **18/11/2026**. O estado do hardware e as medições ficam na
seção “COMECE AQUI” do [estado atual](docs/ESTADO-ATUAL.md).

O Yoga iniciou pelo slot `current` e chegou ao GDM em **5,1 s** desde o
início do Linux, com GRUB em **1 s**. Use `Fedora Yoga - boot anterior`
no GRUB para recuperar a instalação anterior à otimização. A ISO live
de **1,87 GiB** chegou ao login em QEMU ARM64 via USB emulado. O boot em
pendrive físico no Yoga segue pendente. [Guia da ISO](iso/LIVE.md)

## Pendências dos ensaios de NPU de 17/11

- **NPU:** três ensaios de 100 inferências Abs passaram no HTP V81, com
  resultados conferidos e nenhum Node CPU nos perfis. QAIRT 2.48.40/QNN 2.4
  precisou de override de SoC 662 apenas no processo; o aparelho continua
  identificado como Kalambo 729. Isso não comprova suporte nativo.
- **Bloqueio:** nova sessão falha com `0x8000054f/AEE_EQURTBADASID`, também
  no reprodutor FastRPC sem QNN. A NPU permanece desabilitada no boot normal,
  sem serviço automático. A causa interna ainda não foi identificada.
- **Retomar:** investigar criação/destruição do user PD usando
  [fastrpc-open-close.c](install/npu/fastrpc-open-close.c) e a
  [matriz de ensaios](install/npu/README.md). Não repetir as variantes
  rejeitadas nem retirar `dma-coherent`: houve erros de memória no kernel.
  Validar reaberturas, usuário comum e novo boot antes de promover.
- **Base preservada:** USB3 à direita em 5 Gbit/s e à esquerda em 10 Gbit/s;
  câmeras RGB/IR; alto-falantes e microfones; Adreno X2-45 limitada a
  310 MHz. Gen2 na direita, USB4/DP alt-mode e suspensão seguem pendentes.
- **Evidências:** `local/physical-2026-11-17/npu-inference/`, incluindo
  `current-restored.txt`. Backup remoto: `/root/npu-20261117/`.
  Os 26 testes locais do startup passaram novamente.
- **Atualização pendente:** instalar `libatomic` invalidou a transação
  offline do DNF; será necessário reagendá-la no aplicativo de atualizações.

As etapas anteriores estão em [WORKFLOW.md](WORKFLOW.md). Não retomar
pelos testes ACPI/ISO históricos; firmware, binários e logs privados
permanecem fora do Git.
