# Memória completa — ISO Fedora 44 para ASUS Vivobook X1407QA

Data de consolidação: **20 de agosto de 2026**

Este documento registra o trabalho executado em 19–20/08/2026 para corrigir a
ISO live/instalável do ASUS Vivobook X1407QA. Ele substitui o relatório de
19/08 como descrição do estado atual, sem apagar aquele histórico.

## 1. Pedido e diagnóstico inicial

O primeiro artefato desta rodada inicializou fisicamente com o kernel
`7.2.0-x1407qa`. Teclado e Bluetooth funcionaram, mas o percentual da bateria
não apareceu, o Wi-Fi não criou interface e o instalador começava e parava. O
live também não reconheceu compartilhamento de internet por USB ou Bluetooth.

O journal identificou causas distintas:

- o QCNFA765/WCN6855 (`17cb:1103`, subsystem `105b:e130`) era encontrado por
  `ath11k_pci`, mas o MHI terminava em timeout `-110` enquanto
  `wcn_regulator_fix` repetia `regulator providers not ready: -517`;
- `pwrseq_qcom_wcn` existia, porém não era garantido antes do módulo consumidor;
- o Vivo V2562 (`2d95:6003`) expunha CDC Data, mas o kernel não tinha
  `rndis_host`; o PAN Bluetooth não tinha `bnep`;
- `/usr/bin/sudo` perdeu UID/modo privilegiado durante a extração do EROFS;
- `qcom/gen71500_sqe.fw` e `qcom/gen71500_gmu.bin` não estavam disponíveis.

Esses achados motivaram uma segunda reconstrução. A imagem documentada nas
seções 9 e 10 contém as correções, foi auditada e gravada, mas ainda aguarda o
primeiro boot físico.

Os únicos drivers Windows recuperáveis estavam no próprio pendrive. Antes de
sobrescrevê-lo, todo o conteúdo de drivers foi preservado em um arquivo
ultracomprimido no repositório. A implementação Linux foi então reconstruída a
partir da documentação e dos arquivos já disponíveis no projeto.

## 2. Preservação dos drivers Windows

O backup contém 5.420 entradas de origem e foi validado integralmente:

```text
Arquivo: windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst
Tamanho comprimido: 835.731.061 bytes
Tamanho descomprimido: 5.324.103.680 bytes
SHA-256: 43fe0b6fd8a0336bd1d9ef02147bd2e2af09ca6d2d41895c20c7d34609716cd4
```

Teste de integridade:

```bash
sha256sum -c windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst.sha256
zstd --long=31 -t windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst
```

A janela longa de 2 GiB é intencional para maximizar a compressão. O arquivo
completo permanece **fora da ISO**.

## 3. Firmware realmente usado

O builder deixou de escolher pacotes por data de modificação. A seleção agora
é determinística e conferida por `firmware/x1407qa-driverstore.sha256`, com 16
hashes exatos provenientes de quatro diretórios do DriverStore:

- `qcdx8380.inf_arm64_e13ac55ddce2b10f` — GPU;
- `qcnspmcdm_ext_cdsp8380.inf_arm64_a2e536ad01025a78` — CDSP;
- `qcsubsys_ext_adsp8380.inf_arm64_dad10e5e4880caf9` — ADSP/battery manager;
- `qcwlanhsp8380.inf_arm64_417e5fdb5950602f` — WCN6855/Wi-Fi.

Destinos principais no live:

```text
/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
/usr/lib/firmware/ath11k/WCN6855/hw2.1/
```

O board file específico `AS_SA_X14QA` é instalado como `board.bin`; o firmware
Wi-Fi vira `amss.bin`, acompanhado de `m3.bin` e `regdb.bin`. ADSP, CDSP e GPU
mantêm os nomes esperados pelos drivers Linux. Comparações `cmp` confirmaram
que os arquivos instalados são byte a byte idênticos aos arquivos manifestados.

O snapshot completo do repositório, o catálogo amplo e o arquivo de drivers
Windows não são copiados para `/opt` nem para qualquer outro ponto da ISO.

## 4. Correções de hardware reconstruídas

Foram adicionados quatro módulos GPL sob `modules/` e fontes correspondentes em
`/usr/src` no live:

### `wcn_regulator_fix`

- mantém os reguladores necessários ao WCN6855;
- declara `softdep` para carregar `pwrseq_qcom_wcn` antes do consumidor;
- espera provedores com `delayed_work`;
- faz rescan PCI tardio quando necessário;
- libera reguladores e dispositivo corretamente na remoção.

### `vivobook_kbd_fix`

- instancia o teclado I2C-HID no barramento `i2c@b94000`, endereço `0x3a`;
- cria o IRQ do GPIO 67 como nível baixo;
- registra primeiro o driver I2C e mantém o módulo carregado;
- usa `delayed_work` para esperar I2C/TLMM/IRQ, em vez de retornar
  `-EPROBE_DEFER` pelo `module_init`, que não seria repetido;
- delega probe, power management, shutdown e remoção ao core `i2c_hid`.

### `vivobook_hotkey_fix`

- associa o HID ASUS `0b05:4543`;
- executa o feature report de handshake ASUS;
- mapeia brilho, microfone, câmera, RF-kill e iluminação do teclado;
- repete o handshake após resume/reset-resume.

### `vivobook_bl_fix`

- expõe backlight raw de 12 bits pelo LPG do PMK8550;
- valida o subtipo de hardware antes de escrever;
- desbloqueia e roteia DTEST3 sem alterar GPIO5;
- salva o valor original de DTEST3 e o restaura em falha ou unload.

Todos os `Makefile`/`dkms.conf` usam o `kernelver` solicitado pelo DKMS, e não
o `uname -r` do host de construção.

## 5. Kernel Linux 7.2 reproduzido

O kernel foi reconstruído do zero em uma árvore isolada e verificado pelo
script `kernel/verify-linux-7.2-x1407qa.sh`.

Configurações críticas exigidas:

```text
CONFIG_ISO9660_FS=y
CONFIG_JOLIET=y
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_DM_SNAPSHOT=m
CONFIG_I2C_QCOM_GENI=m
CONFIG_ATH11K=m
CONFIG_ATH11K_PCI=m
CONFIG_POWER_SEQUENCING_QCOM_WCN=m
CONFIG_USB_USBNET=m
CONFIG_USB_NET_CDCETHER=m
CONFIG_USB_NET_CDC_NCM=m
CONFIG_USB_NET_RNDIS_HOST=m
CONFIG_BT_BNEP=m
CONFIG_QCOM_Q6V5_PAS=m
CONFIG_QCOM_PMIC_GLINK=m
CONFIG_BATTERY_QCOM_BATTMGR=m
```

Os símbolos `tristate` são aplicados por `scripts/config --module` antes de
`olddefconfig`; eles não passam mais por `--enable`. O script falha se o valor
final não for exatamente o esperado.

O verificador confere:

- manifesto `SHA256SUMS` com caminhos relativos;
- imagem de boot e módulos ARM64/AArch64;
- `vermagic` exato `7.2.0-x1407qa`;
- resolução de dependências por `modprobe --show-depends`;
- DTB e Kconfig críticos.

Hashes dos artefatos finais reproduzidos:

```text
0914062002dad2d279b3b16b008b605c72c41a0a4f6c5cfe925f877f48cc69ce  vmlinuz-7.2.0-x1407qa
35763b73052b88433a942b93555a1ce931d81abc67f9e465821c10683ac26199  config-7.2.0-x1407qa
95f7bb2840c7ce831661056c116f8cd9b692cd94b035f8cdde775cc4a976d90a  x1p42100-asus-zenbook-a14.dtb
a5cc3ed68514f581b37279fde0d498578b16c460d7dbcf75d34624a5cb70c87e  wcn_regulator_fix.ko
2e692af4c4219dd751bf13550d85a6cfb277eda0f07311cb4b4cfc2f2c729149  vivobook_kbd_fix.ko
c790d0f129d868a16f808166f53743cedd6e146cb1d16f4a768bc9d9890b6800  vivobook_bl_fix.ko
47c7227f6dc35994c9fbef054bdc002d860036c5dc9b81d7b0e4051831cc5243  vivobook_hotkey_fix.ko
```

## 6. Initramfs e boot live

O initramfs foi regenerado dentro do root Fedora ARM64 com:

```text
dmsquash-live
livenet
pollcdrom
```

`iscsi` e `nvmf` são omitidos. O initramfs reextraído da ISO contém os quatro
módulos locais, `pwrseq_qcom_wcn`, `rndis_host` e os firmwares ADSP/CDSP/GPU
exigidos pelo boot, inclusive `gen71500_sqe.fw` e `gen71500_gmu.bin`.

O GRUB possui três caminhos:

1. **RAM, principal** — `rd.live.ram rd.minmem=4096`;
2. **fallback USB** — sem `rd.live.ram`;
3. **diagnóstico** — `rd.debug`, sem esconder mensagens.

Todas mantêm `modprobe.blacklist=qcom_q6v5_pas` durante a fase inicial e forçam
`pwrseq_qcom_wcn` antes de `wcn_regulator_fix`. Carregar ADSP cedo pode
reinicializar o controlador USB e derrubar a própria mídia.

Na entrada principal, o serviço
`x1407qa-adsp-after-live-ram.service` executa `modprobe qcom_q6v5_pas` somente
quando:

```text
ConditionKernelCommandLine=rd.live.ram
ConditionPathExists=/run/initramfs/squashed.img
```

Assim, o ADSP/battery manager inicia apenas depois que o live está integralmente
em RAM. O fallback continua protegido e não executa esse serviço.

## 7. Instalador

O Fedora 44 usa EROFS e o ambiente live pode não apresentar
`/dev/mapper/live-osimg-min`. O builder valida a versão conhecida de
`/usr/libexec/liveinst-setup.sh` e altera a condição para também aceitar:

```text
/run/initramfs/livedev
```

O script resultante passou por `bash -n`. A abertura e a conclusão do
instalador ainda precisam ser exercitadas no notebook real.

## 8. Segurança e reprodutibilidade dos builders

`kernel/build-linux-7.2-x1407qa.sh` agora:

- canonicaliza tarball, work root e artifact root com `realpath`;
- só aceita work roots dedicados `x1407qa-*`;
- exige artifacts dentro do work root e tarball fora dele;
- impede que `rm -rf` receba uma raiz ampla controlada pelo chamador;
- gera hashes relativos e valida o resultado final.

`tools/build-personal-maximal-iso.sh` agora:

- canonicaliza todas as entradas e saídas;
- rejeita work roots amplos, o repositório e caminhos protegidos dentro do work;
- rejeita entrada igual à saída ou ao arquivo de checksum;
- usa temporário irmão aleatório criado por `mktemp` e `mv` atômico;
- remove apenas o temporário conhecido em falha;
- preserva proprietário e modo ao extrair o EROFS e executa
  `rpm --restore -a` dentro do rootfs;
- exige `sudo` pertencente a root e setuid antes de empacotar;
- inclui e verifica `pwrseq_qcom_wcn`, RNDIS/BNEP e os dois firmwares
  `gen71500`;
- normaliza a ISO final para modo `0644`;
- valida o fallback, o serviço ADSP, módulos, firmware e loader antes de concluir.

Os testes executáveis exigem também a mensagem específica dos guards. Dessa
forma, não passam por acaso devido a tarball ausente ou ferramenta indisponível.

## 9. ISO final

```text
Nome: Fedora-44-X1407QA-Linux-7.2-hardware-ram.iso
Tamanho: 4.668.063.744 bytes
SHA-256: ffd0f459c07e8b5cf5ae591818c6bafae0e626a444b37dae72f1bf113a7a5cbf
Modo: 0644
```

O EROFS foi criado com LZ4HC e a camada ISO atualizada recursivamente por
`xorriso`, preservando o boot EFI original com replay das estruturas de boot.

Verificações feitas diretamente na ISO final:

- checksum SHA-256;
- kernel, initramfs e DTB no loader;
- comparação byte a byte do kernel/initramfs extraídos;
- comparação do EROFS extraído com o EROFS construído;
- presença de módulos, `/usr/src`, serviço e firmware selecionado;
- presença de `bnep`, `rndis_host`, `pwrseq-qcom-wcn` e
  `wcn_regulator_fix.ko` no EROFS;
- UID/GID `0/0`, setuid e modo `4111` de `/usr/bin/sudo` no EROFS;
- presença de `pwrseq_qcom_wcn`, RNDIS e firmware `gen71500` no initramfs;
- ausência de `/opt/vivobook-fixes/repository` e do arquivo de drivers Windows;
- configuração RAM/fallback no GRUB.

## 10. Pendrive final

Alvo identificado imediatamente antes da escrita:

```text
Fabricante/modelo: Kingston DataTraveler 3.0
Serial: E0D55E6CC1DA1661A8AE119F
Dispositivo naquele momento: /dev/sda
Tamanho: 30.995.907.072 bytes
Removível: sim
Somente leitura: não
Partições montadas: nenhuma
```

A ISO foi gravada pelo caminho persistente `/dev/disk/by-id/...` com:

```bash
dd if=Fedora-44-X1407QA-Linux-7.2-hardware-ram.iso \
   of=/dev/disk/by-id/usb-Kingston_DataTraveler_3.0_E0D55E6CC1DA1661A8AE119F-0:0 \
   bs=16M conv=fsync status=progress
```

Foram escritos 4.668.063.744 bytes. Em seguida, exatamente o mesmo número de
bytes foi relido do dispositivo bruto. Resultado:

```text
ISO:      ffd0f459c07e8b5cf5ae591818c6bafae0e626a444b37dae72f1bf113a7a5cbf
READBACK: ffd0f459c07e8b5cf5ae591818c6bafae0e626a444b37dae72f1bf113a7a5cbf
```

`xorriso` abriu diretamente o pendrive e encontrou:

```text
/boot/aarch64/loader/linux
/boot/aarch64/loader/initrd
/boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb
```

Por fim, `udisksctl power-off -b /dev/sda` desligou/ejetou logicamente o
Kingston. O device node desapareceu; o pendrive pode ser removido fisicamente.

## 11. Testes e revisão

Passaram na rodada final:

```text
tests/test-build-regressions.sh
tests/test-live-hardware-contract.sh
bash -n
shellcheck
git diff --check
kernel/verify-linux-7.2-x1407qa.sh
systemd-analyze verify
sha256sum -c
zstd --long=31 -t
lsinitrd
dump.erofs
xorriso
comparações cmp
readback SHA-256 do USB
```

Uma revisão independente encontrou e levou à correção de:

- retry incorreto do teclado via `module_init`;
- firmware escolhido por mtime;
- Kconfig exato e `tristate` contraditório;
- manifesto absoluto/autorreferente e verificação incompleta de módulos;
- ausência de restore de DTEST3;
- DKMS dependente de `uname -r`;
- caminhos destrutivos controláveis e colisões de saída;
- inclusão ampla do repositório na ISO;
- testes de segurança que poderiam falhar pelo motivo errado.

Os testes automatizados e a auditoria da mídia passaram. Isso comprova o
conteúdo gravado, não o funcionamento físico ainda pendente desta reconstrução.

## 12. Arquivos principais alterados/adicionados

```text
kernel/build-linux-7.2-x1407qa.sh
kernel/verify-linux-7.2-x1407qa.sh
tools/build-personal-maximal-iso.sh
tools/resume-personal-iso-repack.sh
tools/verify-live-root.sh
tests/test-build-regressions.sh
tests/test-live-hardware-contract.sh
firmware/x1407qa-driverstore.sha256
modules/wcn-regulator-fix-1.0/
modules/vivobook-kbd-fix-1.0/
modules/vivobook-bl-fix-1.0/
modules/vivobook-hotkey-fix-1.0/
windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst
windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst.sha256
docs/plans/2026-08-19-live-hardware-integration.md
BUILD-STATE.md
docs/BUILD-REPORT-2026-08-20.md
```

Alterações preexistentes do usuário em `README.md`,
`GUIA-FIRMWARE-WINDOWS.md`, `build-vivobook-iso.sh` e
`setup-vivobook.sh` foram preservadas. O trabalho permanece no worktree local;
nenhum commit ou push foi solicitado.

## 13. Limitações conhecidas e próximo passo

- Secure Boot pode exigir desativação porque o kernel local não está assinado
  por uma chave cadastrada no firmware.
- O backup Windows é específico desta família de máquina e não deve ser
  redistribuído sem revisar licença e privacidade.
- USB4/TB3, câmera IR e suspend não foram revalidados nesta execução.
- Integridade de software e mídia não substitui teste no equipamento.
- O percentual da bateria não apareceu no primeiro teste físico e continua
  pendente; a reconstrução atual não deve ser descrita como correção confirmada.

Próximo passo obrigatório: inicializar **RAM, principal** no X1407QA e testar
Wi-Fi, tethering USB, instalador e bateria. Teclado e Bluetooth já funcionaram
na imagem anterior. Se a RAM não for suficiente ou a cópia falhar, usar
**fallback USB**. Em falha de boot, usar **diagnóstico** e guardar
`dmesg`/journal para nova análise.
