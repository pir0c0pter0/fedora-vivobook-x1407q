# Mídias de diagnóstico Yoga — estado em 13/11/2026

> **Histórico (13/11/2026).** Este documento descreve o planejamento e os testes anteriores ao bring-up físico de 16/11. O estado atual está no [README do porte](/ports/lenovo-yoga-slim7-14q8y11/README.md) e em [docs/ESTADO-ATUAL.md](/ports/lenovo-yoga-slim7-14q8y11/docs/ESTADO-ATUAL.md).

Pausado até a retomada pelo usuário, prevista para 16/11/2026. Ver [retomada](../RETOMADA.md).

- **Pendrive atual: R3-CONS.** Só o menu da ESP foi alterado sobre a base R2; relido após remontagem e ejetado. Primeira entrada ACPI com menos logs. Ainda não testado fisicamente. [Resultado R3](RESULTADO-R3-CONS.md).
- **ISO em disco: R2**, não reconstruída como R3. Contém DTB mínimo Kalambo na ISO e ESP, sem DTS completo de placa. [Resultado R2](RESULTADO-DIAG-R2.md).
- **ISO experimental original:** base histórica, QEMU live com YOGA-SELFTEST-PASS. [Resultado original](RESULTADO.md).

O menu atual aguarda seleção; Esc avança nas pausas. O GRUB Fedora não inclui read: usamos sleep --interruptible. As entradas verbosas antigas continuam para comparação. Não há gravação automática de logs no pendrive. ISO9660/EROFS preservam documentação embutida histórica; [LEIA-ME.txt](LEIA-ME.txt) no workspace descreve o USB atual.

R2 física demonstrou kernel e seis CPUs por transcrição parcial, mas reiniciou. R3 remove somente initcall_debug/ignore_loglevel para testar possível custo da depuração no console; não é correção comprovada. Kernel/live/firmware/ICC não mudaram.

## Histórico da construção original

Os procedimentos abaixo descrevem a base experimental e não devem ser executados automaticamente na retomada. `finish-live.sh` e `repack-diag-r2.sh` são scripts de construções específicas; recusam sobrescrever as respectivas saídas. A R3 foi aplicada com o registro privado `local/iso-build/update-usb-r3-cons.py`, que exige o hash anterior e não deve ser repetido sobre a ESP já atualizada.

## Entradas e construção

Tudo foi preparado em `../local/iso-build/`, no container rootless Podman
`yoga-iso-build` (Fedora 45 x86_64, com binfmt aarch64 habilitado). O container
privilegiado dentro do namespace do usuário permite os bind mounts de
`dev`, `proc`, `sys` e `run` usados pelo chroot; não usa loop devices nem monta
partições do notebook/pendrive. A imagem de ferramentas foi preservada como
`localhost/yoga-iso-tools:20261113`; pacotes acrescentados depois estão no
inventário local do ambiente.

Entradas fixadas:

- Fedora Workstation Live 45-1.4 aarch64, SHA256
  `ad73a977709d417f5b7dda4147fc071396b9d8d2bdcca2df615aa3aab7673710`.
  CHECKSUM validado com assinatura Fedora 45,
  `4F50A6114CD5C6976A7F1179655A4B02F577861E`.
- Kernel Qualcomm `for-next`, commit
  `6a876df4686788cd39128b62d7fcbff62f39278f`, `ARCH=arm64 LLVM=1`,
  defconfig mais EROFS, DM snapshot, simpledrm, SELinux/AUDIT e EC Gen 11.
  O driver EC compilado não é habilitado por um nó de placa nesta imagem.
- Noctalia release `v5.5.0`, tarball oficial com dependências vendorizadas,
  SHA256 `a4ba61392de6024905513d6b070cf40839809f61953468bda7eb8272f7a7aa16`.
  Cross-build Meson/Clang 23 usando bibliotecas aarch64 do Fedora 45.
  Pacote local [noctalia.spec](noctalia.spec), sem assinatura de distribuição.
- Niri `26.04-2.fc45` do Fedora. Configuração oficial de `v26.04`, trocando
  autostart Waybar por `noctalia --daemon` e terminal Alacritty por Foot.
- Sete ICM LEN88AE da coleta validada. Seis arquivos candidatos de firmware
  (ADSP e duas versões CDSP), preservados em diretórios separados, sem ativação
  nem seleção arbitrária entre versões conflitantes. Manifesto local identifica
  origem, caminho na imagem, tamanho e SHA256 de cada arquivo.

O kernel foi construído com:

```sh
make LLVM=1 ARCH=arm64 O=/work/kernel-out defconfig
# As opções efetivas estão em /usr/share/yoga-port/kernel.config na ISO.
make LLVM=1 ARCH=arm64 O=/work/kernel-out olddefconfig
make LLVM=1 ARCH=arm64 O=/work/kernel-out -j28 Image modules
make LLVM=1 ARCH=arm64 O=/work/kernel-out \
  INSTALL_MOD_PATH=/work/kernel-stage INSTALL_MOD_STRIP=1 -j16 modules_install
```

O EROFS original foi extraído com `fsck.erofs --extract`. A instalação de
pacotes usou DNF `--forcearch=aarch64 --installroot=/work/rootfs --releasever=45
--use-host-config`; o Noctalia foi construído em sysroot separado e instalado
como RPM, com resolução normal de dependências. Não foram copiados drivers
`.sys` do Windows para `/usr/lib/firmware`.

[finish-live.sh](finish-live.sh) finaliza o workspace já preparado: verifica
entradas/versões/hashes, instala o kernel, gera initramfs no chroot ARM64,
desmonta binds antes de empacotar, gera EROFS com contextos SELinux, cria o
segundo initrd com a raiz live, remonta a ISO preservando boot EFI/híbrido e
implanta/verifica MD5 interno. O SHA256 final fica ao lado da ISO. Ele recusa
sobrescrever uma ISO anterior. Não é um provisionador completo de ambiente
nem uma promessa de reprodução bit a bit; o inventário registra as versões
realmente resolvidas pelo Fedora nessa rodada.

## Verificações e limites

- `bash -n` nos scripts; `niri validate` no chroot aarch64.
- `noctalia --version` retorna `noctalia v5.5.0` em aarch64.
- Hashes de entrada e dos ICM/firmwares; presença dos módulos live no initramfs.
- EROFS, El Torito/partição EFI e MD5 interno da ISO, além do SHA256 final.
- [ram-selftest.sh](ram-selftest.sh) verifica o payload em VM, quando ativado
  com `yoga.selftest`. O serviço só roda em QEMU e não é acionado no boot normal.
  O `livesys` do Fedora reaplica presets e remove o vínculo ao target; após o
  login na VM, iniciar com `sudo systemctl start yoga-ram-selftest`.
  Resultado efetivo da VM é registrado no relatório desta construção.

Nenhuma dessas verificações demonstra funcionamento físico de USB, GPU,
I²C, áudio, energia/térmica ou instalação neste Lenovo. A raiz na RAM permite
avançar no diagnóstico sem depender do USB Linux, mas não fornece os drivers
ausentes nem corrige ACPI. Niri também depende de um backend gráfico funcional.
O bloqueio atual é o reinício após a execução inicial do kernel no Lenovo.
Ainda faltam boot estável, DTS completo e validação física dos periféricos.
