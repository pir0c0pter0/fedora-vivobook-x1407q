# ISO gerada — 2026-11-13

> **Histórico (13/11/2026).** Este documento descreve o planejamento e os testes anteriores ao bring-up físico de 16/11. O estado atual está no [README do porte](/ports/lenovo-yoga-slim7-14q8y11/README.md) e em [docs/ESTADO-ATUAL.md](/ports/lenovo-yoga-slim7-14q8y11/docs/ESTADO-ATUAL.md).

> Relatório histórico desta revisão. Estado atual: USB R3-CONS, ainda não testado no Lenovo; ver [retomada](../RETOMADA.md) e [relatório R3](RESULTADO-R3-CONS.md).

Arquivo: `<workspace>/isos/Fedora-45-Yoga-14Q8Y11-Experimental-20261113.iso`

Tamanho: **8.253.472.768 bytes (7,69 GiB)**.

SHA256: `9efffc4de3e904e5a1cdca91148786a067bcd0da44f3430c9c734512bddc201c`

- Checksum da base Fedora e assinatura Fedora 45: válidos.
- Digest oficial do tarball Noctalia 5.5.0: confere.
- EROFS, estrutura EFI/El Torito e checksum interno da ISO: passaram.
- SHA256 da cópia entregue em `isos/`: confere.
- Boot UEFI/ACPI em QEMU aarch64, seis CPUs e 12 GiB RAM: passou.
- Raiz EROFS carregada pela UEFI na RAM, overlay e terminal live: funcionaram.
- Autoteste final: `YOGA-SELFTEST-PASS`; Noctalia 5.5.0, configuração Niri e
  hashes dos sete ICM conferidos dentro do sistema inicializado.
- Desativação de ZRAM confirmada, sem o timeout observado na primeira rodada.
- QEMU encerrou com código 0. O autoteste solicita desligamento após o marcador;
  por isso o job `systemctl start` pode aparecer cancelado durante o shutdown.
- Em dois testes físicos, o GRUB apareceu e aceitou a entrada ACPI, mas o kernel
  deixou a tela preta com cursor e a máquina voltou ao Windows antes do live. O
  segundo teste já tinha console EFI antecipado, logs máximos e `panic=0`, sem
  mudar o resultado. A mídia não contém log persistente dessa fase.
- A ESP agora inclui um DTB diagnóstico Kalambo mínimo de seis CPUs, sem nós de
  placa ativados, SHA256
  `1312ce6f353e842e1b770c265c4db1fff245f478b3c0319b67c69168478e1dd2`.
  O novo `grub.cfg` oferece essa entrada primeiro e ambos os arquivos passaram
  na leitura após remontagem somente leitura. O terceiro boot, usando esse DTB,
  repetiu a tela preta/cursor e fallback para o Windows, também sem saída.

Logs, inventários de pacotes, entradas, kernel e RPM local estão preservados em
`../local/iso-build/`; verificações resumidas em `verification.json` e log final
em `qemu-final-clean.log`. A primeira rodada permanece em `previous-build/`.

**Ainda não demonstrado nos três testes desta revisão histórica:** execução efetiva do kernel, DTS/DTB completo da placa, GPU/sessão
gráfica, USB/I²C, energia/térmica, instalação no NVMe e aplicação efetiva dos ICC.
A ISO não contém DTB Elite/CRD; o DTB mínimo foi acrescentado somente à ESP do
pendrive. Exige Secure Boot desativado. Seguir [LEIA-ME.txt](LEIA-ME.txt).

Atualização posterior: a R2 demonstrou execução do kernel e seis CPUs; isso não retroage como sucesso dos testes acima. O próximo teste é R3-CONS, ainda pendente.
