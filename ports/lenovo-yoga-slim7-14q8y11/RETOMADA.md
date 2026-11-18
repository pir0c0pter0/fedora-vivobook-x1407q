# Retomada — Yoga Slim 7 14Q8Y11 / X2 Plus

Atualizado em **17/11/2026, após os ensaios de NPU**. Fonte de verdade:
[docs/ESTADO-ATUAL.md](docs/ESTADO-ATUAL.md), seção "COMECE AQUI".

O Yoga voltou ao boot normal `current` em **34,441 s**, com vídeo, USB,
câmeras, áudio, GPU e GDM ativos. SoCCP attached, ADSP running e bateria
legível. `current` e `try` usam o DTB `92f6b329…`; hashes de `current` e
`good` conferidos. `saved_entry=current`, sem tentativa de boot pendente.

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
