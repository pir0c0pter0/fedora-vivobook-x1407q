# Yoga 14Q8Y11 Live 45

ISO experimental ARM64 de **1,87 GiB** para o Lenovo Yoga Slim 7 14Q8Y11 (83QR), Snapdragon X2 Plus, baseada no Fedora 45. O GRUB espera **1 s** e carrega a raiz live em RAM a partir do pendrive. A gravação usa a ISO inteira e substitui o conteúdo do pendrive escolhido.

1. Baixe a ISO e o arquivo de SHA-256 na [release do Yoga](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/releases/tag/yoga14q8y11-live-2026.11.18).
2. Confira a imagem com `sha256sum -c Yoga-14Q8Y11-Live-45-20261118.iso.sha256`.
3. Grave a ISO no pendrive como imagem bruta e selecione o pendrive no menu UEFI com Secure Boot desligado.
4. A entrada padrão abre o GNOME. A entrada de vídeo de compatibilidade do GRUB evita a inicialização do painel acelerado. A entrada UEFI AArch64 abre um console para diagnóstico.

O kernel e os módulos do painel, GPU, USB e câmera vêm da configuração testada no SSD do Yoga. A mídia oferece a sessão live. O firmware ADSP específico do notebook e os perfis de cor extraídos do Windows ficam fora da distribuição. O áudio dos amplificadores depende dos [arquivos ADSP e da calibração](../install/audio/README.md). O NPU fica desligado, o SSH fica desabilitado e o SELinux usa modo permissivo.

## Construção

O [script de build](build-live.sh) usa o container e as entradas descritas na [receita de base](README.md). A raiz parte do EROFS da ISO oficial Fedora Workstation Live 45-1.4 aarch64, fixada por SHA-256. Na raiz extraída, instale `generic-release`, `generic-release-notes` e `generic-logos` com `dnf5 --forcearch=aarch64 --releasever=45 --installroot <raiz> --use-host-config --allowerasing`. Copie o diretório `install/` deste porte para `port/install/` e coloque `grub-live.cfg` e uma cópia de `LEIA-ME-LIVE.txt` com nome `release-readme.txt` na área de build.

O arquivo `yoga-hardware.tar` contém o DTB compilado em `boot/yoga/current/board.dtb`, os módulos GPL em `usr/lib/modules/<release>/updates/`, as regras Yoga de câmera e SoCCP, as unidades Yoga de EC, RTC, SoCCP, USB3 e vídeo, os arquivos modprobe do porte e os scripts RTC e vídeo. O arquivo de fontes da release inclui a árvore Linux exata, a configuração, o DTS pré-processado e o código dos módulos externos. A árvore e o Mesa devem ser compilados com as instruções incluídas nesse arquivo.

O script elimina a imagem de resgate do kernel Fedora anterior, o instalador de base e pacotes de firmware de outros dispositivos. O SquashFS usa XZ, filtro ARM64 e blocos de 1 MiB. A ISO guarda uma única cópia do sistema live, em um CPIO carregado pelo GRUB. A estrutura EFI continua servindo tanto para mídia USB quanto para CD-ROM virtual. [Código e fontes da base Fedora](https://archives.fedoraproject.org/pub/archive/fedora/linux/)

O SHA-256 do arquivo local confere com o registrado no GitHub. A ISO chegou ao login via USB emulado no QEMU ARM64 em modo UEFI. O primeiro boot da ISO gravada em um pendrive físico do Yoga precisa de confirmação.
