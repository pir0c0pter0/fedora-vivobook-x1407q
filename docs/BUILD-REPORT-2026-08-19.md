# Relatório completo de build — Fedora 44 + Linux 7.2 para ASUS Vivobook X1407QA

Data: **19 de agosto de 2026**

Repositório: `pir0c0pter0/fedora-vivobook-x1407q`

Commit remoto usado como base: `a4f246ea619e60c0863a77701ac1b4bfa9a51e89`.

Resultado: nova ISO ARM64 personalizada construída, auditada, gravada, relida
integralmente do pendrive e inicializada com sucesso no X1407QA.

## 1. Objetivo

Produzir uma mídia live/instalável Fedora Workstation ARM64 específica para o
ASUS Vivobook 14 X1407QA. O Linux 7.2 final é o único kernel oferecido no menu
de boot, em modos normal e diagnóstico. A mídia inclui DTB X1P42100, módulos e
initramfs próprios, firmware extraído deste PC, scripts, módulos DKMS e
documentação do repositório. Recursos experimentais perigosos não são ativados
por padrão.

## 2. Hardware analisado

| Componente | Identificação observada |
|---|---|
| Equipamento | ASUS Vivobook 14 X1407QA (`X1407QA_X1407QA`) |
| SoC | Qualcomm Snapdragon X X1-26-100, 8 núcleos |
| Arquitetura | ARM64 / AArch64 |
| GPU | Qualcomm Adreno X1-45 |
| Memória | 15,61 GiB utilizáveis, comercialmente 16 GB |
| Armazenamento | Micron `MTFDKBA512QGN`, aproximadamente 477 GB |
| Wi-Fi/Bluetooth | Qualcomm FastConnect 6900 / WCN6855 |
| BIOS | ASUS X1407QA.314 |

Identificadores de série do hardware não foram adicionados a este relatório.

## 3. Insumos e proveniência

### Fedora

- Base: `Fedora-Workstation-Live-44-1.7.aarch64.iso`.
- Tamanho observado: `2.689.781.760` bytes.
- SHA-256 verificado antes da integração:
  `162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef`.
- Arquitetura: AArch64.
- Layout interno: EROFS em `LiveOS/squashfs.img`.
- Boot: imagem híbrida GPT/EFI com GRUB ARM64.

### Linux

- Versão: **Linux 7.2 final**, lançado em 16 de agosto de 2026.
- Fonte: `https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz`.
- Lista assinada: `https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc`.
- Registro local: `provenance/sources.json`.
- SHA-256 da fonte:

```text
f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
```

### Firmware do computador

- Backup do DriverStore: 2.084 arquivos verificados.
- Catálogo inventariado: 596 entradas.
- Arquivos classificados como utilizáveis no Linux: 136.
- Pacotes de pesquisa da câmera IR: 49.
- Destino na mídia: `/opt/vivobook-fixes/firmware-catalog`.
- Digest reproduzível do catálogo (SHA-256 da lista ordenada de hashes e
  caminhos relativos):
  `6ca8152f738252275483c59b16e20cdfe581c92a78499e42ec6d3c246b2772c0`.

O firmware Windows é mantido como fonte local para scripts específicos; não é
ativado indiscriminadamente no boot.

## 4. Ambiente de construção

O host era Windows ARM64. WSL2 recebeu uma distribuição Ubuntu ARM64 chamada
`FedoraBuilder`. `tools/Resume-X1407QABuild.ps1` importou o rootfs e instalou o
toolchain. Temporários grandes ficaram no VHD do WSL.

Ferramentas principais: GCC AArch64 nativo, `make`, `bc`, `bison`, `flex`,
`dtc`, `dracut`, `kmod`, `xorriso`, `erofs-utils`, `squashfs-tools`, `rsync`,
`e2fsprogs`, `sha256sum` e `file`.

Versões centrais registradas: GCC `13.3.0`, GNU Make `4.3` e xorriso `1.5.6`.

## 5. Construção do Linux 7.2

Scripts:

- `kernel/build-linux-7.2-x1407qa.sh`;
- `kernel/verify-linux-7.2-x1407qa.sh`.

Identificação final: `7.2.0-x1407qa`.

O build partiu de `defconfig`, aplicou `olddefconfig` e habilitou os subsistemas
Qualcomm importantes: DRM MSM, remoteproc, PMIC GLINK, battery manager, RPMh,
SCMI, DWC3/Type-C, ath11k, Bluetooth QCA, áudio Qualcomm, CAMSS/CCI, FastRPC e
PD mapper. Foram compilados `Image`, `dtbs` e `modules`; os módulos passaram por
`modules_install` e `depmod`.

Artefatos produzidos em `/var/lib/x1407qa-kernel-7.2/artifacts`:

- `boot/vmlinuz-7.2.0-x1407qa`;
- `boot/config-7.2.0-x1407qa`;
- `boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb`;
- `lib/modules/7.2.0-x1407qa/`;
- `SHA256SUMS`.

Hashes dos três artefatos de boot principais:

```text
ca8d31c8e92b89de9d233e0387dc5454b06394965ba9e9cd55030dabac58d90f  config-7.2.0-x1407qa
95f7bb2840c7ce831661056c116f8cd9b692cd94b035f8cdde775cc4a976d90a  x1p42100-asus-zenbook-a14.dtb
ee6e18e3dd61e1dd91f53d0fb99744d09cfc679a5eef50aa6dc744beb690e9fa  vmlinuz-7.2.0-x1407qa
```

O verificador confirmou imagem de boot Linux ARM64, `modules.dep`, DTB,
configuração e todos os hashes.

Antes de alterar a imagem Fedora, o pipeline também verifica o SHA-256 exato da
ISO de entrada e executa o verificador dos artefatos do kernel, incluindo seu
`SHA256SUMS`. Uma divergência encerra o build antes da integração.

## 6. Integração da ISO

Scripts:

- `tools/build-personal-maximal-iso.sh` — pipeline completo;
- `tools/resume-personal-iso-repack.sh` — retoma a recompressão;
- `tools/finalize-personal-iso.sh` — finaliza a camada ISO.

Fluxo executado:

1. extrair Fedora com `xorriso`;
2. detectar EROFS em vez do antigo SquashFS com `rootfs.img`;
3. extrair com `fsck.erofs --extract`;
4. instalar kernel, configuração, DTB e módulos no root live;
5. copiar repositório e catálogo de firmware para `/opt/vivobook-fixes`;
6. executar `depmod 7.2.0-x1407qa` no root Fedora;
7. gerar `initramfs-7.2.0-x1407qa.img` com os módulos dracut live e sem
   iSCSI/NVMf;
8. instalar Linux 7.2, initramfs e DTB no loader live;
9. criar entradas GRUB normal e de diagnóstico;
10. recriar EROFS com LZ4HC;
11. atualizar a ISO com `xorriso -update_r`;
12. preservar El Torito/EFI com `-boot_image any replay`;
13. gerar e validar SHA-256.

### Menu GRUB

Entrada padrão: `Fedora 44 X1407QA — Linux 7.2 (principal)`. Usa kernel 7.2,
initramfs correspondente, `x1p42100-asus-vivobook-x1407qa.dtb`,
`rd.live.image`, `clk_ignore_unused` e `pd_ignore_unused`.

Entrada alternativa: `Fedora 44 X1407QA — Linux 7.2 (diagnóstico)`. Usa o mesmo
kernel, initramfs e DTB auditados, sem `quiet rhgb` e com `rd.debug`.

## 7. Problemas encontrados e correções

### Identificação ARM64

`file` retornou `Linux kernel ARM64 boot executable`; o verificador esperava
somente `ARM aarch64`. Ele passou a aceitar as duas descrições.

### Manifesto autorreferente

O primeiro `SHA256SUMS` incluía a si próprio enquanto era escrito. O gerador
agora exclui explicitamente `SHA256SUMS`.

### Nomes de configuração do Linux 7.2

Os nomes válidos no Linux 7.2 foram confirmados na árvore do kernel e corrigidos
para `CONFIG_BATTERY_QCOM_BATTMGR` e `CONFIG_ARM_SCMI_CPUFREQ`.

### Fedora 44 usa EROFS

O pipeline pressupunha SquashFS. Foi adicionada detecção de formato e suporte a
`fsck.erofs`/`mkfs.erofs`, preservando compatibilidade com SquashFS.

### Permissões na extração EROFS

Preservar permissões imediatamente tornava diretórios não graváveis antes do
fim. A extração passou a usar `umask 000` e `--no-preserve-perms`.

### Espaço físico do C:

O VHD informava muito espaço lógico, mas crescia sobre o C:. Sem espaço físico,
ext4 foi remontado como somente leitura e o WSL gerou erros de I/O. A execução
foi retomada após liberar mais de 30 GB físicos.

### Rótulo EROFS

`Fedora-WS-Live-44` excedia 16 caracteres. Foi usado `Fedora-WS-44`.

### Atualização não recursiva

`xorriso -update` alterou apenas a raiz e manteve o GRUB original. A auditoria
detectou a ausência do DTB e do loader personalizados. A correção crítica foi
`-update_r`.

### Escrita bruta no Windows ARM64

`\\.\PhysicalDrive1` rejeitou escrita por `FileStream`, e este Windows não
suportava `wsl --mount` para disco físico. Foi usado Rufus 4.15 portátil oficial,
com assinatura Authenticode válida da Akeo Consulting.

### Initramfs personalizado sem suporte live

O primeiro boot do Linux 7.2 parou em aproximadamente 1,15 segundo com
`dracut: FATAL: Don't know how to handle 'root=live:CDLABEL=Fedora-WS-Live-44'`.
O kernel, o DTB e o pendrive estavam íntegros; o initramfs personalizado tinha
`rootfs-block`, mas não `dmsquash-live`. O initramfs Fedora preservado mostrava
o padrão correto: `--add 'dmsquash-live livenet pollcdrom'`.

O primeiro reparo adicionou esses módulos copiando amplamente o initramfs
Fedora. A ISO corrigida e a leitura direta completa do Kingston produziram o
mesmo SHA-256, mas o boot seguinte revelou um segundo erro antes de montar o
sistema live.

### Hook iSCSI indevido e kernel sem os filesystems live

O segundo boot parou em `iscsiroot requested but kernel/initrd does not support
iscsi`. A cópia ampla havia trazido `iscsi`, `nvmf` e
`90-parse-iscsiroot.sh`; esse hook tentava carregar `iscsi_tcp` antes de
confirmar a existência de um `netroot` iSCSI.

A auditoria do `.config` embutido também encontrou três bloqueadores que seriam
os erros seguintes: ISO9660 e EROFS estavam desativados, assim como DM snapshot.
O Linux 7.2 foi recompilado com `CONFIG_ISO9660_FS=y`, `CONFIG_JOLIET=y`,
`CONFIG_EROFS_FS=y`, `CONFIG_EROFS_FS_ZIP=y` e `CONFIG_DM_SNAPSHOT=m`. Os 1.665
arquivos da árvore de módulos foram substituídos no EROFS e o initramfs foi
gerado novamente por `dracut`, adicionando somente os módulos live necessários
e omitindo explicitamente `iscsi nvmf`.

O initramfs reextraído contém `dmsquash-live`, `livenet`, `pollcdrom`,
`dm-snapshot` e `overlay`, não contém o hook iSCSI e possui somente a árvore
`7.2.0-x1407qa`. O pipeline agora falha se o `.config` final ou o initramfs não
cumprirem esses contratos.

## 8. Resultado final

```text
Nome: Fedora-44-X1407QA-Linux-7.2-livefix-reviewed.iso
Tamanho: 4.473.094.144 bytes (4,166 GiB)
SHA-256: 114bc4bd5034096cee8c89369bd8c8b41abc03f93298ae5fa15b8dc9b2e11341
```

Arquivos críticos auditados:

```text
boot/aarch64/loader/linux
boot/aarch64/loader/initrd
boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb
boot/grub2/grub.cfg
LiveOS/squashfs.img
```

O GRUB foi inspecionado quanto a duas entradas do mesmo Linux 7.2, normal e de
diagnóstico. Ambas carregam o DTB do VivoBook; a segunda remove `quiet rhgb` e
adiciona `rd.debug` para tornar eventual falha legível. A recuperação com o
kernel Fedora foi removida porque não inicia neste equipamento.

## 9. Pendrive e validação

O alvo foi um Kingston DataTraveler 3.0 de 32 GB, sempre verificado como USB,
não-sistema e não-boot antes de ações destrutivas. O Rufus produziu GPT com
partição de dados e partição EFI.

O hash bruto total divergiu porque o Rufus ajustou GPT/MBR ao tamanho físico. A
comparação posterior de blocos de 1 MiB mostrou:

```text
DIFFERENT_1M_BLOCKS=1
DIFF_OFFSET=0
```

Somente o primeiro MiB de metadados mudou. Todos os bytes de 1 MiB ao fim da
ISO — kernels, initramfs, EROFS, firmware, DTB e payload — são idênticos.

Essa validação corresponde à tentativa anterior. A nova ISO revisada foi então
gravada no mesmo Kingston e os seus 4.473.094.144 bytes foram relidos diretamente
do dispositivo. A leitura física produziu o mesmo SHA-256 da seção 8. Kernel,
initramfs, DTB e GRUB também foram extraídos do pendrive e comparados byte a
byte com os artefatos revisados; o dispositivo permaneceu desmontado.

### Boot físico confirmado

Após a regravação e a auditoria completa, o usuário confirmou que a entrada
Linux 7.2 inicializou no ASUS Vivobook X1407QA. Isso valida o caminho crítico
UEFI → GRUB → DTB → kernel → initramfs → `root=live:` que havia falhado nas
tentativas anteriores. A validação não implica que todos os periféricos ou
recursos experimentais tenham sido exercitados.

## 10. Testes

Testes existentes executados: `Test-BootstrapBuildEnv.ps1`,
`Test-CameraIRSafety.ps1`, `Test-CoreModuleGate.ps1`,
`Test-EnableX1407QABuildEnvironment.ps1`, `Test-ExportX1407QAFirmware.ps1`,
`Test-ResumeX1407QABuild.ps1` e `Test-SourceProvenance.ps1`.

Testes adicionados:

- `tests/Test-Linux72KernelScripts.ps1`;
- `tests/Test-PersonalIsoBuilder.ps1`.

Esses testes agora acompanham o repositório. Além dos parâmetros, o pipeline
confere os valores finais do Kconfig e inspeciona o initramfs gerado para exigir
os módulos live, rejeitar iSCSI/NVMf e aceitar somente a árvore de módulos
`7.2.0-x1407qa`. Scripts Bash relevantes também passaram por `bash -n`, a ISO
foi auditada diretamente conforme as seções 8 e 9 e o boot físico básico foi
confirmado no equipamento.

## 11. Limitações e segurança

- Secure Boot pode precisar ser desativado: o kernel personalizado não foi
  assinado com chave cadastrada no firmware do usuário.
- Câmera IR continua indisponível por ausência física do PMIC necessário.
- USB4/TB3 e suspend continuam experimentais e desativados por padrão.
- Use a entrada Linux 7.2 de diagnóstico se a entrada normal ainda falhar.
- Nenhuma partição do NVMe interno foi modificada durante este trabalho.
- A ISO já gravada contém o snapshot do repositório disponível no momento do
  empacotamento, anterior a este relatório e às correções finais do pipeline.
  Os kernels, initramfs, DTB e firmware auditados não mudam por isso; para obter
  uma mídia com a documentação e os scripts finais dentro de `/opt`, gere uma
  nova ISO a partir do commit publicado por este trabalho.
- O boot básico foi confirmado no X1407QA, mas isso não comprova compatibilidade
  funcional de todos os dispositivos, suspend, USB4/TB3 ou câmera IR.

## 12. Reprodução

Em ambiente ARM64 com dependências instaladas, clone o repositório e forneça os
insumos locais. Os padrões abaixo permitem colocar a fonte e a ISO na raiz do
clone; caminhos explícitos podem ser usados por variáveis/argumentos:

```bash
git clone https://github.com/pir0c0pter0/fedora-vivobook-x1407q.git
cd fedora-vivobook-x1407q

cp /caminho/linux-7.2.tar.xz ./linux-7.2.tar.xz
cp /caminho/Fedora-Workstation-Live-44-1.7.aarch64.iso ./

FIRMWARE_CATALOG=/caminho/firmware-catalog \
  kernel/build-linux-7.2-x1407qa.sh ./linux-7.2.tar.xz /var/tmp/x1407qa-kernel

INPUT_ISO="$PWD/Fedora-Workstation-Live-44-1.7.aarch64.iso" \
KERNEL_ARTIFACTS=/var/tmp/x1407qa-kernel/artifacts \
FIRMWARE_CATALOG=/caminho/firmware-catalog \
WORK_ROOT=/var/tmp/x1407qa-iso \
OUTPUT_ISO="$PWD/Fedora-44-X1407QA-Linux-7.2.iso" \
  sudo -E tools/build-personal-maximal-iso.sh
```

Para retomar após integração ou finalizar somente a camada ISO:

```bash
sudo env WORK_ROOT=/var/tmp/x1407qa-iso \
  OUTPUT_ISO="$PWD/Fedora-44-X1407QA-Linux-7.2.iso" \
  tools/resume-personal-iso-repack.sh
sudo env WORK_ROOT=/var/tmp/x1407qa-iso \
  OUTPUT_ISO="$PWD/Fedora-44-X1407QA-Linux-7.2.iso" \
  tools/finalize-personal-iso.sh
```

O tarball do kernel deve ser conferido contra a lista assinada indicada na
seção 3. A ISO Fedora é rejeitada automaticamente se não tiver o hash registrado.
O firmware é específico deste equipamento e não é distribuído pelo repositório.

Antes de usar a mídia, valide SHA-256 e confirme que o alvo é um USB que não
pertence ao sistema.
