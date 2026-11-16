# Retomada — Yoga Slim 7 14Q8Y11 / X2 Plus

Pausa em 16/11/2026; retomar em **17/11**. Fonte de verdade:
[docs/ESTADO-ATUAL.md](docs/ESTADO-ATUAL.md), seção de pausa USB3.

- USB3 a 10 Gbit/s passou nas duas portas da esquerda, nas duas orientações,
  com hashes iguais e leituras de 548–615 MB/s. Automação passou no `try`.
- Direita falhou com resets/erros de leitura tanto em 10 quanto em 5 Gbit/s.
  **Decisão do usuário: deixá-la em USB2 por enquanto.** O hardware tem três
  portas USB4 de 40 Gbit/s; isso ainda não é suporte Linux USB4.
- `current`/`good` intactos; `try` restaurado como cópia do `current` USB2.
  `saved_entry=current`, sem `next_entry`. Próximo boot normal: USB2 nas três.
- Unidade USB3 candidata instalada, mas condicionada a `yoga.usb3=1`, ausente
  nos slots restaurados. Fontes experimentais e evidências ficam locais.
- Próximo trabalho: preparar USB3 automático só nas duas esquerdas, manter
  a direita USB2, revisar e provar no `try` antes de promover. Não reaplicar
  o ensaio falho de 5 Gbit/s. Patch de ajustes PHY upstream foi baixado,
  mas não aplicado/compilado/testado; investigar a direita depois.

Seguir [WORKFLOW.md](WORKFLOW.md#atual--pausa-após-os-testes-usb3).
Não reiniciar pelos testes ACPI/ISO históricos nem esperar associação Wi-Fi.
