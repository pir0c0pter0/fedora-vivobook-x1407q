# Retomada — Yoga Slim 7 14Q8Y11 / X2 Plus

Atualizado em **17/11/2026**. Fonte de verdade:
[docs/ESTADO-ATUAL.md](docs/ESTADO-ATUAL.md), seção USB3 permanente no topo.

- USB3 permanente: direita **5 Gbit/s**, esquerdas **10 Gbit/s**, nas duas
  orientações. Direita: 16 GiB por orientação a 296/288 MB/s, sem resets
  ou erros; hashes de amostras conferem. USB2 na direita também passou.
- Solução: patch Qualcomm de calibração do QMP combo mais limite Gen1 na
  direita. O módulo em `updates` e o serviço automático passaram no `try`
  e depois no boot normal `current`, com nova leitura no `try` intermediário.
- `current` e `try`: `gwnx2d1-usb3`, hash DTB `0a5f45a9…`; `good` USB2
  intacto. Base USB2 anterior em `/root/usb3-phy-20261117/current-before`.
  `saved_entry=current`, sem tentativa pendente. Boot normal em 23,491 s.
- Vídeo, Wi-Fi, NVMe, bateria, RTC, EC e GDM preservados. Não esperar
  associação Wi-Fi no boot. Nenhuma mudança de tensões, retimers ou SoCCP.
- Gen2 na direita continua instável; não retirar o limite sem validar.
  USB4/DP alt-mode e suspensão continuam pendentes. Não houve escrita nos
  discos externos; USB2 nas esquerdas não foi repetido nesta rodada.
- Próximas frentes anteriores: som permanente, GPU/Mesa e kernel R4.
  Logs privados em `local/physical-2026-11-17/usb3-right/`; receita de
  build e rollback em [install/usb](install/usb/README.md).

Seguir [WORKFLOW.md](WORKFLOW.md#atual--usb3-permanente).
Não reiniciar pelos testes ACPI/ISO históricos.
