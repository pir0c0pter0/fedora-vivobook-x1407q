# Transcrição parcial R2 e teste R3-CONS — 2026-11-13

> **Histórico (13/11/2026).** Este documento descreve o planejamento e os testes anteriores ao bring-up físico de 16/11. O estado atual está no [README do porte](/ports/lenovo-yoga-slim7-14q8y11/README.md) e em [docs/ESTADO-ATUAL.md](/ports/lenovo-yoga-slim7-14q8y11/docs/ESTADO-ATUAL.md).

Fonte preservada em `local/physical-diag-r2/Transcricao_video_Yoga_log_e_erros.txt`, SHA256 `3d7c57b2e86d0d281cc5fcccb3124df0d5442b36cde0ab1c82061eccfdc53dd9`. É uma transcrição visual por outro Codex, incompleta, com nomes e campos incertos; não é dmesg original. O vídeo não foi revisto nesta rodada.

O usuário relata cerca de cinco minutos antes das linhas aparecerem, seguidos de aproximadamente dois segundos de texto em velocidade normal e reinício. A duração em câmera lenta não mede tempo de boot. Timestamps zero na fase inicial não medem esse intervalo de parede nem provam defeito do relógio.

Evidência transcrita: execução Linux, console EFI habilitado, ACPI/PSCI/GIC, seis CPUs iniciadas em EL2 e initcalls posteriores aos avisos. Última linha parcialmente legível em ~0,576 s do kernel; nenhum panic/Oops legível. Não prova que chegou ao initramfs ou live, não prova suporte aos periféricos e não identifica a rotina responsável pelo reset.

O usuário confirmou que não editou parâmetros. As leituras `efi=novamap`, `systemd.gpt_auto=0` e sufixo `halimbo` conflitam com os artefatos; registrar como transcrição incerta, não alterar o inventário a partir delas. O menu da ESP antes da atualização conferiu SHA256 R2 `bdc2410a54f25c82d5e66a0e1ee45cace8f407652cfd46ba5b02fc3aaa44469c`. A configuração continua efi=noruntime, systemd.zram=0 e kernel yoga-kalambo+.

## Análise dos avisos

- SPCR: o código usado (`drivers/acpi/spcr.c`) faz fallback para acesso de byte. Não há evidência de parada nessa mensagem.
- Timer EL2: `drivers/clocksource/arm_arch_timer.c` seleciona o temporizador físico como fallback; o log prossegue e mostra `(hyp)`. Não alterar IRQs por essa mensagem isolada.
- CDW3: no DSDT coletado, `local/iso-build/acpi/acpi-registry-0000.dsl:108490`, o método `\_SB._OSC` cria incondicionalmente um DWORD no offset 8 antes de distinguir o UUID USB4 do UUID de capacidades da plataforma. O kernel em `drivers/acpi/bus.c:455` usa `capbuf[2]` (8 bytes) na negociação da plataforma. Isso fornece uma explicação concreta e consistente para o buffer de 64 bits excedido por CDW3. A transcrição sem caminho completo não permite atribuir definitivamente essa ocorrência ao método. Não foi aplicado override ACPI.
- AE_NOT_FOUND, pacote _CST curto e retornos -19: tratar como pistas, sem apontar qualquer um como causa fatal, pois a execução prossegue.

## Teste R3-CONS — preparado, pendente de teste físico

Hipótese a testar, não diagnóstico fechado: a depuração muito verbosa no framebuffer EFI pode perturbar/retardar o boot. A implementação do earlycon copia linhas do framebuffer durante a rolagem; não é possível atribuir os cinco minutos a isso sem comparação. Watchdog/reset de firmware permanece hipótese, não razão para desativar proteções.

A nova primeira entrada usa o mesmo kernel, ACPI, initrd, earlycon, keep_bootcon, loglevel=7, panic=0 e efi=noruntime. Retira somente `initcall_debug` e `ignore_loglevel`. As pausas continuam com Esc. Entradas antigas foram mantidas para comparação.

Somente `EFI/BOOT/grub.cfg` do pendrive serial <serial-do-pendrive> foi alterado. Backup do menu anterior em `local/physical-diag-r2/usb-grub-before-r3.cfg`. Hash novo: `5be4480e84a0db817e5e1a7a05bfa0022802478c066eb02becad16db5aedb418`. DTB preservado, ambos conferidos após remontagem somente leitura. Sintaxe GRUB e testes simulados de sequência/falhas/argumentos passaram. Não foi realizado novo teste em QEMU ou no Lenovo desta variante.

A ISO R2 em disco não foi reconstruída. O hash do pendrive inteiro agora difere da ISO, pois sua ESP mudou. Não há log automático no pendrive nesta revisão.

USB ejetado com sucesso, conforme `local/usb-esp-r3-cons.json`. Trabalho pausado a pedido do usuário; retomar em 16/11/2026 quando ele voltar, sem ação agendada.

Na retomada: escolher `1. Yoga: ACPI menos logs (teste R3)`, avançar pausas com Esc, medir o tempo desde BOOT e filmar a saída até o reinício. Registrar se apareceu terminal e se a espera mudou. Não instalar no NVMe.
