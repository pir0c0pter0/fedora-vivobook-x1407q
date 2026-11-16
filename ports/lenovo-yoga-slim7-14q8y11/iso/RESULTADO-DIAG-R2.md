# ISO DIAG-R2 — 2026-11-13

> **Histórico (13/11/2026).** Este documento descreve o planejamento e os testes anteriores ao bring-up físico de 16/11. O estado atual está no [README do porte](/ports/lenovo-yoga-slim7-14q8y11/README.md) e em [docs/ESTADO-ATUAL.md](/ports/lenovo-yoga-slim7-14q8y11/docs/ESTADO-ATUAL.md).

> Relatório histórico desta revisão. Estado atual: USB R3-CONS, ainda não testado no Lenovo; ver [retomada](../RETOMADA.md) e [relatório R3](RESULTADO-R3-CONS.md).

Arquivo: `<workspace>/isos/Fedora-45-Yoga-14Q8Y11-Diag-R2-20261113.iso`.

Tamanho: 8.253.669.376 bytes.
SHA256: `04397fcf04d18c9985c12e8ba401115aa54d4663f62f5261617ecec45d9581d2`.

Reempacota a ISO experimental anterior, mantendo kernel e sistema live. Acrescenta o DTB mínimo Kalambo à ISO e ESP, sincroniza o menu nas duas e atualiza `/LEIA-ME-YOGA.txt`. O texto dentro do EROFS permanece histórico da construção original.

O menu não inicia sozinho. As duas primeiras entradas mostram resultados e pausam com Esc; falhas bloqueiam a entrega ao kernel. O comando `read` não está incluído no GRUB Fedora desta mídia, então a espera usa `sleep --interruptible` em laço. A tentativa anterior que dependia de `read` foi rejeitada antes de gravar o USB.

Validação realizada:

- Sintaxe GRUB e shell; testes simulados dos caminhos ACPI/DTB e de falha em cada etapa.
- Hash da ISO base e do DTB de seis CPUs.
- Checksum MD5 interno da ISO: PASS.
- GPT/ESP e conteúdo do menu/DTB embutidos conferidos por extração; cópia ISO9660 do menu e do DTB conferida.
- GRUB real em QEMU arm64: ACPI parou em SEARCH=0, LINUX=0 e INITRD=0; Esc avançou cada etapa até o marcador BOOT.
- GRUB real em QEMU arm64: DTB parou em SEARCH=0, LINUX=0 e DEVICETREE=0. VM encerrada antes de executar esse DTB específico de hardware Lenovo.
- A captura completa ACPI R2 mostra execução de Linux e início do Fedora/systemd. O autoteste completo do live não foi repetido. Logs em `local/iso-build/qemu-diag-r2*.typescript`.

Secure Boot: o usuário confirmou nesta rodada que está desativado desde o primeiro teste físico. Essa hipótese não explica os três resultados anteriores segundo a configuração relatada.

Gravação USB concluída: serial `<serial-do-pendrive>`, 8,253,669,376 bytes escritos e relidos com O_DIRECT. SHA256 idêntico à ISO; pendrive desligado/ejetado por UDisks. Registro: `local/usb-iso-write-diag-r2-2026-11-13.json`. Menu SHA256: `bdc2410a54f25c82d5e66a0e1ee45cace8f407652cfd46ba5b02fc3aaa44469c`.

Procedimento desta revisão histórica: primeira entrada ACPI, fotografar os retornos e pressionar Esc em cada pausa. Informar a última etapa visível caso a tela apague. Nenhuma instalação no NVMe é autorizada por esta mídia de diagnóstico.

## Primeiro teste físico DIAG-R2 — atualização do usuário

As quatro fotos comprovam SEARCH=0, LINUX=0, INITRD=0 e o marcador BOOT no Lenovo. Depois de parecer parado, apareceram muitas linhas e o notebook reiniciou, conforme relato do usuário. Posteriormente foi recebida transcrição parcial: Linux, console EFI e seis CPUs em EL2 observados; causa do reset desconhecida. Não concluir que ficou travado no GRUB. Secure Boot já estava desativado.

Esta mídia não tem captura automática de logs no pendrive: live em RAM, sem persistência. CONFIG_EFI_VARS_PSTORE=y está compilado, mas a entrada diagnóstica usa efi=noruntime, que impede contar com o backend EFI. CONFIG_PSTORE_CONSOLE não está habilitado; ramoops não está configurado para a placa. panic=0 já estava ativo, portanto o reinício não deve ser atribuído a um timeout de panic configurado sem examinar as últimas mensagens. A transcrição e suas limitações foram analisadas no relatório R3; o próximo teste é a entrada R3 já preparada.

Correção do registro QEMU: o arquivo completo qemu-diag-r2.typescript contém Linux version e chega a Welcome to Fedora Linux 45 e systemd. A observação anterior de ausência de saída Linux decorreu da leitura incompleta da captura, não de travamento comprovado da VM. Não foi concluído novo autoteste do live nessa execução.
