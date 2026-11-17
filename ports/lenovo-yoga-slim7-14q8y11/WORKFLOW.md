# Workflow do porte Lenovo X2 Plus

## Atual — perfil Windows e sincronização controlada

Pedido de 17/11/2026: aproveitar a coleta Windows, sem referência de cor física.
CCM RGB extraído com estrutura/CRC verificados e revisão independente, instalado
por sensor e validado em 90 quadros com metadados. CCI/OV08X40/CAMSS receberam
correções de retomada, repetição limitada do reset inicial e unwind de falha.
Dez reaberturas rápidas de cada câmera passaram; a configuração foi promovida.
Boot normal em 23,897 s, PipeWire com 1.800 buffers RGB e 1.800 IR até EOS,
WirePlumber PID1718 sem reinícios.

O iluminador passou no ensaio por sinal do sensor com um quadro e limites
50 mA/10 ms, terminando OFF e com o bit PMIC restaurado. Os módulos/DT
diagnósticos foram retirados. Calibração completa do ISP Windows, precisão
colorimétrica e sincronização contínua permanecem pendentes.
Detalhes em [perfil Windows](install/camera/WINDOWS-CALIBRATION.md) e
[sincronização](install/camera/ir/SYNCHRONIZATION.md).

## Etapa anterior — integração RGB, IR e iluminador

Workflow solicitado pelo usuário em 17/11/2026 e concluído com implementação
e revisão separadas. PM8010 identificado, drivers/DTS preparados, correções
CCI/flash reproduzidas e verificadas, câmeras capturando e pulso do iluminador
confirmado opticamente. O travamento inicial com CCI stock exigiu reboot
forçado; a falha de completion foi corrigida antes de retomar os testes.

Inicialização automática aprovada no `try` e no boot normal `current`.
RGB1080 e IR640×480 passaram pelo PipeWire como usuário; WirePlumber usa
CPU e mantém MDWE. Iluminador OFF no boot e ao fim dos testes. `good` e
backups preservados; nenhuma tentativa de boot pendente. Estado, limites,
evidências e rollback em [ESTADO-ATUAL](docs/ESTADO-ATUAL.md) e
[install/camera](install/camera/README.md). Naquela etapa a calibração era
genérica; o avanço posterior está registrado acima.

## Etapa anterior — USB3 permanente

Validado em 17/11/2026: direita Gen1 (5 Gbit/s), esquerdas Gen2 (10 Gbit/s),
nas duas orientações. A direita precisou do patch Qualcomm de calibração
mais o limite Gen1. Passou em 16 GiB por orientação sem resets/erros;
o fallback USB2 na direita e a revalidação USB3 das esquerdas passaram.

O módulo em `updates` carregou automaticamente no `try`, seguido de nova
leitura da direita, e a configuração foi promovida e conferida no boot
normal `current`. `good` ficou intacto; há backup completo da base USB2.
Nenhuma tentativa permanece armada. Wi-Fi continua em paralelo, sem
espera por associação. Não foram alteradas tensões, retimers ou SoCCP.

O requisito USB3 da direita está atendido a 5 Gbit/s. Gen2 na direita,
USB4 e DP alt-mode continuam pendentes; não remover o limite Gen1 sem
revisão e nova evidência física. Estado, hashes e limitações em
[ESTADO-ATUAL](docs/ESTADO-ATUAL.md); build e rollback em
[install/usb](install/usb/README.md).

### Histórico — preparação de referência anterior ao teste

Passagem preparada em 16/11/2026. A fonte do estado é o topo de
[docs/ESTADO-ATUAL.md](docs/ESTADO-ATUAL.md), resumido no [README](README.md).
O suporte USB2 permanente está publicado na `main` em `f8a334f`;
`gwnx2d1` dá boot normal com vídeo real e as três portas USB2, em cerca de
13,2 s pelo systemd. Esta passagem é documental: nenhum teste USB3 foi feito.

A linha de base somente de leitura já foi salva em
`local/physical-2026-11-16/handoff-usb3/baseline-readonly.txt` (19:21 UTC).
Ela confirmou os três hosts limitados a USB2, os combos QMP desabilitados,
o módulo combo instalado e somente root hubs, sem periféricos externos.
Nenhum PHY foi carregado, DTB alterado ou reboot feito nesta passagem.

O alvo seguinte é **USB3 SuperSpeed em uma porta por vez**. Som permanente,
GPU/Mesa e kernel R4 ficam para depois; USB4 e DP alt-mode estão fora desta
rodada. O DT atual força `high-speed`, somente `usb2-phy` e
`qcom,select-utmi-as-pipe-clk`: retirar apenas `maximum-speed` não basta.

### Processo

1. Capturar uma linha de base somente de leitura no Lenovo: kernel/cmdline,
   hashes e argumentos dos três slots, `lsusb -t`, módulos, reguladores,
   clocks, dispositivos adiados e logs de kernel. Confirmar eDP, Wi-Fi,
   NVMe, SoCCP anexado, bateria e serviços EC/RTC/USB. Preservar os logs em
   `local/`; root hubs `480M`/`10000M` sem dispositivo externo não provam
   um link SuperSpeed.
2. Auditar o caminho de **uma** porta contra o DSDT desta placa e as fontes
   do kernel: driver QMP combo, bindings, supplies e trilhos compartilhados,
   clocks/PIPE, orientação, mux e retimer. O mapa inicial dos três combos
   fica em [ESTADO-ATUAL](docs/ESTADO-ATUAL.md#próxima-sessão--usb3-superspeed).
   O driver é `phy-qcom-qmp-combo.c`, com
   `CONFIG_PHY_QCOM_QMP_COMBO=m` já instalado; não confundir com o driver
   QMP USB standalone/"uni". A referência Glymur/Elite serve para comparação,
   sem comprovar a fiação do Kalambo/Plus.
3. Preparar uma variante DTB para só essa porta, com edição e revisão
   separadas. Revisar os dois PHYs, seus nomes, PIPE e orientação antes de
   trocar as limitações USB2. Preservar USB2, eDP, Wi-Fi, NVMe e SoCCP;
   não escrever em `current` ou `good`. Guardar a cópia do `try` e seus
   hashes antes de instalar a variante, e usar uma única tentativa pelo
   `yoga-boot-once try`. Um reboot deve voltar ao `current` preservado.
4. No Lenovo, comprovar um **dispositivo externo folha** a `5000M` ou
   `10000M` nas duas orientações do conector. Conferir fallback USB2,
   estabilidade dos subsistemas preservados e leitura do dispositivo sem
   gravar nele. Registrar dispositivo, porta, orientação, velocidade e logs.
   Hubs virtuais, a capacidade anunciada pelo xHCI ou USB4 não substituem
   esse resultado.
5. Se houver regressão de vídeo, rede, NVMe ou SoCCP, salvar o que for
   possível e reiniciar para a base. Não descarregar PHYs nem tentar
   compensar alterando tensões. Só promover depois da revisão e de evidência
   física suficiente; atualizar o topo do estado com o resultado real.

### Regras que continuam valendo

- Agentes separados para editar e revisar foram autorizados pelo usuário,
  como substituição ao Workflow indisponível; quem edita não verifica.
- Reboot autorizado sem aviso. Travamento duro pode exigir o botão de energia;
  manter `current`, `good`, backups e recuperação utilizáveis.
- Não esperar link online durante o boot. A guarda USB2 atual exige a placa
  PCIe ativa e os trilhos em uso, sem exigir associação Wi-Fi; manter essa
  proteção até a auditoria justificar qualquer alteração.
- Não tocar nos M.2 do PC. O PC prepara fontes/builds; só o Lenovo valida
  hardware. Não publicar firmware, coleta ou dados privados de `local/`.
- Não carregar `pmic_glink_altmode` nem parar/reiniciar o SoCCP. UCSI já
  registrou três portas, mas carga e troca de papel não foram validadas;
  investigar sua necessidade para USB3, sem presumir que seja obrigatório.

## Histórico — planejamento de 13/11/2026

> **Histórico (13/11/2026).** A partir deste ponto, o conteúdo descreve o planejamento e os testes anteriores ao bring-up físico de 16/11. O estado atual está no [README do porte](/ports/lenovo-yoga-slim7-14q8y11/README.md) e em [docs/ESTADO-ATUAL.md](/ports/lenovo-yoga-slim7-14q8y11/docs/ESTADO-ATUAL.md).

Pausa solicitada pelo usuário; retomada prevista para **16/11/2026**, sem agendamento automático.

### Próximo teste — R3-CONS

Pendrive atualizado, relido e ejetado. Escolher `1. Yoga: ACPI menos logs (teste R3)`, avançar com Esc e medir/filmar desde BOOT. R2 já mostrou Linux e seis CPUs, depois reiniciou; a causa não está identificada. Secure Boot desativado foi confirmado. A R3 remove apenas initcall_debug/ignore_loglevel e ainda não foi testada no Lenovo. Ver [análise](iso/RESULTADO-R3-CONS.md). Não regravar a ISO R2 por cima da ESP R3.

Alvo: Yoga Slim 7 14Q8Y11, X2P-42-100/Kalambo, Fedora 45 aarch64, Niri, Noctalia **5.5.0** e perfis Lenovo. Pesquisa, coleta Windows e tentativas físicas em 2026-11-13. Este é o roteiro de engenharia, não um instalador liberado.

### Estado das etapas

| Etapa | Estado em 13/11/2026 | Evidência para concluir |
|---|---|---|
| 0. Isolar e identificar pelo catálogo | Feita | Worktree, branch, PSREF e revisões em `sources.json` |
| 1. Preservar Windows/firmware/cores e coletar hardware | Primeira aquisição preservada e conferida; ressalvas EDID/SSDT documentadas | [Relatório](COLETA-WINDOWS-2026-11-13.md), 6.430 hashes Windows válidos, 6.433 arquivos locais, 188 pacotes e sete ICC |
| 2. Fechar kernel e DTS Kalambo da placa | Kernel compilado; DTS de placa ainda pendente | DTS revisado, build e checagem de bindings |
| 3. Fechar firmware/initramfs e mídia live Fedora | [ISO experimental ACPI gerada; integridade e boot em VM conferidos](iso/RESULTADO.md); firmware de DSP preservado como candidato | Seleção final de firmware/DTB e testes físicos ainda dependem de 2 |
| 4. Boot USB de diagnóstico | R2 executou Linux e seis CPUs; reinício sem causa identificada. R3 pendente | Boot até live estável, captura de logs e validação de armazenamento/energia |
| 5. Instalar Fedora e validar reboot/recuperação | Depende de 4 | Boot do NVMe e recuperação por USB demonstrados |
| 6. Niri + Noctalia 5.5.0 | Userspace aarch64 instalado; versão Noctalia e configuração Niri verificadas; sessão depende de GPU funcional | Sessão acelerada, portais, áudio e bloqueio testados |
| 7. Aplicar e validar os perfis de cores | Exportação em 1; validação após 6 | Perfis originais íntegros e efeito correto comprovado |

### 1. Coleta Windows concluída — procedimentos de referência

A rodada de imagem está documentada em [iso/README.md](iso/README.md). O boot
experimental em RAM por ACPI foi acrescentado a pedido do usuário para obter
evidências do primeiro boot antes de fechar o DTS. Isso não conclui as etapas
de hardware nem autoriza instalar no NVMe sem as verificações seguintes.

Preparar uma pasta em unidade externa, por exemplo `E:\Yoga-14Q8Y11`. Guardar backup dos dados, mídia Lenovo de recuperação e chave de recuperação BitLocker fora do repositório. Alterações de Secure Boot e partições podem pedir essa chave. Antes de reduzir o Windows, preservar ESP, GPT e partições OEM; usar a gestão de discos do Windows para a redução.

#### Coleta automatizada

Usar o [coletor Windows](windows/LEIA-ME.md), criado para esta etapa. Extrair o pacote no Lenovo, executar `Coletar-Yoga.cmd` como administrador e informar o destino externo. O script `Collect-Yoga14Q8Y11.ps1` usa Windows PowerShell 5.1 ARM64, gera uma subpasta exclusiva e preserva DriverStore completo, exportação PnPUtil, firmware, inventário/recursos PnP, ACPI, EDID, ICC/ICM e associações ICM, com hashes e erros por etapa. Não baixa nem instala ferramentas no aparelho.

Enviar inicialmente `RESUMO.txt`, `inventory/identification.json` e `hash-errors.json`. Manter a pasta completa privada e depois copiá-la para `local/windows/<data>/`. As tabelas ACPI repetidas continuam sujeitas ao limite da API Windows; o dump do registro complementa a coleta e registra as lacunas. Não tratar a coleta como dump completo garantido de todos os SSDTs.

Os testes de parser, cópia com fixtures, hashes, ACPI e compilação do wrapper C# passaram no host. Os relatórios da primeira coleta já foram recebidos e conferidos; a revisão v2 não foi executada no Lenovo.

Primeira execução observada em 2026-11-13: a enumeração ampla de `edid-registry` alcançou subchaves protegidas `Properties`, gerou aviso e continuou para `copy-colors/windows`. A revisão v2 limita a busca aos caminhos `Device Parameters` e passou na regressão com fixture. Os logs finais já foram recebidos: somente essa etapa ficou marcada como incompleta, e dois EDIDs foram preservados. A validação da v2 no Lenovo continua pendente e não é necessária uma repetição completa para aproveitar os dados obtidos.

Na retomada com o USB, a coleta foi recebida e copiada integralmente para `local/windows/2026-11-13/`, incluindo arquivos fora do manifesto. A comparação dos 6.430 hashes Windows passou, e os 6.433 arquivos da cópia local foram comparados com a origem. Há apenas uma etapa marcada incompleta (`edid-registry`), embora dois EDIDs tenham sido salvos. Drivers e cores foram obtidos; não repetir toda a coleta apenas por esse aviso. Ver o [relatório](COLETA-WINDOWS-2026-11-13.md) e a [retomada atualizada](RETOMADA.md).

#### Coleta manual alternativa

Os comandos seguintes consultam o hardware e escrevem relatórios na pasta escolhida no **Lenovo**; ajustar a letra da unidade externa:

```powershell
$captureRoot = 'E:\Yoga-14Q8Y11'
New-Item -ItemType Directory -Path $captureRoot -ErrorAction Stop
Get-CimInstance Win32_ComputerSystem |
    Select-Object Manufacturer, Model, SystemSKUNumber |
    ConvertTo-Json | Set-Content "$captureRoot\system.json"
Get-CimInstance Win32_Processor |
    Select-Object Name, NumberOfCores, NumberOfLogicalProcessors |
    ConvertTo-Json | Set-Content "$captureRoot\cpu.json"
Get-CimInstance Win32_BIOS |
    Select-Object SMBIOSBIOSVersion, ReleaseDate |
    ConvertTo-Json | Set-Content "$captureRoot\bios.json"
pnputil /enum-devices /connected /deviceids > "$captureRoot\devices.txt"
```

Se a pasta já existir, usar outra pasta por coleta para preservar a anterior. Conferir CPU X2P-42-100 e seis núcleos; uma diferença reabre a seleção do SoC. Os IDs PnP podem incluir identificadores de instância: revisar os relatórios antes de compartilhar.

No terminal elevado, exportar os drivers instalados para uma subpasta nova:

```powershell
New-Item -ItemType Directory -Path "$captureRoot\drivers" -ErrorAction Stop
pnputil /export-driver * "$captureRoot\drivers"
if ($LASTEXITCODE -ne 0) { throw 'A exportação dos drivers falhou' }
```

Salvar também uma cópia da árvore `C:\Windows\System32\DriverStore\FileRepository` se a exportação não trouxer os blobs referenciados pelos pacotes Qualcomm. Manter os caminhos originais para evitar colisões de nomes. Baixar os pacotes BIOS/chipset/GPU/áudio/rede/display do [suporte Lenovo deste modelo](https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/yoga-series/yoga-slim-7-14q8y11/downloads/driver-list), registrando versão e hash, sem executá-los no PC de build.

Coletar ACPI com a ferramenta ACPICA `acpidump` para Windows obtida de sua distribuição oficial. Guardar dump binário, DSDT/SSDT e versão da ferramenta; usar `iasl` no host para decompilar. Os recursos I2C/GPIO/IRQ, reguladores, sensores, painel e memória reservada alimentam o DTS. Não inferir GPIOs a partir do ASUS. Extrair EDID bruto e IDs do monitor; confrontar com a resolução/touch observados.

Executar a preservação dos perfis descrita em [CORES.md](CORES.md) **antes** de alterar ou remover o Windows. Depois, copiar as evidências para `local/windows/<data>/` nesta pasta, que é ignorada pelo Git. Firmware, ACPI e perfis de fábrica permanecem locais até revisão do conteúdo e das licenças.

### 2. Fixar fontes e portar a placa

Usar uma árvore de kernel separada dos artefatos ASUS. Ponto de partida consultado:

```bash
git clone --filter=blob:none --no-checkout \
  https://kernel.googlesource.com/pub/scm/linux/kernel/git/qcom/linux \
  /tmp/yoga-qcom-linux
git -C /tmp/yoga-qcom-linux checkout --detach \
  6a876df4686788cd39128b62d7fcbff62f39278f
```

Esse checkout contém Kalambo SoC/CRD. Não aplicar novamente a série v9 sobre os mesmos arquivos. Fixar uma nova revisão se forem necessárias correções posteriores e registrar o motivo.

Portar a placa em um DTS próprio com `kalambo.dtsi`, binding que distinga a variante e firmware correto. Usar o Yoga Glymur apenas como comparação. Revisar:

- Mapa dos seis CPUs, domínios SCMI, mailbox/IMEM/PDC e suporte UBWC de Kalambo.
- Memória reservada, SMMU, armazenamento/PHYs, USB e fontes de alimentação.
- Painel/EDID, GPU chip ID, GPIOs, IRQs e IDs de teclado/touchpad/touch.
- EC, sensores térmicos, bateria, carga, áudio e subsistemas remotos.

Não publicar um DTB com `qcom,glymur` como se fosse suporte Plus. Não ativar nós de reguladores/IR/EC cujos recursos ainda não foram identificados.

Gerar kernel arm64, módulos e DTB a partir do mesmo checkout/configuração. Começar com `arm64 defconfig` e revisar dependências na árvore selecionada; não copiar `.config` ou patches do ASUS em bloco. Habilitar os drivers da [matriz](DRIVERS.md), filesystem do live Fedora, NVMe/USB, firmware loader e initramfs. Fazer `dtbs_check` com schemas e revisar os avisos aplicáveis à placa.

Artefatos exigidos: commit e patches, configuração final, toolchain, log de build, `Image`, DTB, módulos com `vermagic` correspondente e hashes. O `kernel/write-linux-artifact-manifest.sh` legado é referência de formato; revisar seu contrato ASUS antes de reaproveitar código.

### 3. Montar a mídia Fedora

A [ISO oficial Lenovo Diagnostics ARM 5.2.1 foi inspecionada](ISO-LENOVO-DIAGNOSTICS-5.2.1.md). Seu hash confere com o site Lenovo, mas os 32 DTBs embutidos não incluem o Yoga Kalambo. Ela serve de referência de boot Stubble/UEFI; não libera esta etapa nem substitui os artefatos de 2.

Base proposta: [Fedora Workstation 45 aarch64](https://fedoraproject.org/workstation/download/), lançado em 03/nov/2026. A imagem stock é fonte do userspace/instalador; seu boot neste modelo não foi validado. Obter ISO e CHECKSUM na página oficial e verificar a assinatura Fedora e SHA-256 antes do remaster.

Construir o conjunto live com kernel, módulos e DTB de 2 e os firmwares do próprio Lenovo. Incluir na imagem os drivers/firmwares necessários **antes de montar a raiz live**, inclusive as dependências de USB/remoteproc identificadas no bring-up. Inspecionar o initramfs com `lsinitrd`; confirmar cada caminho de firmware, módulo e versão.

Usar UEFI arm64 (`BOOTAA64.EFI`) e entrada de boot com o DTB exato e parâmetros documentados para a placa. O remaster deve preservar El Torito/ESP, conteúdo do instalador e suporte de mídia do Fedora. Não copiar GRUB/DTB/quirks `x1p42100` do builder ASUS.

Preparar também a persistência do mesmo conjunto na instalação: o Anaconda pode instalar o kernel stock e não levar o DTB ou firmware do live. A etapa 5 deve garantir kernel, módulos, firmware, initramfs e entrada UEFI do sistema instalado, preservando o boot Windows.

Inspeção offline obrigatória: checksums, ISO/ESP legíveis, arquitetura arm64, DTB e `compatible` esperados, dependências do initramfs, firmware, correspondência dos módulos e payload de instalação. Um boot em QEMU valida apenas a estrutura; não valida periféricos Kalambo.

### 4. Primeiro boot USB no Lenovo

Com backup e recuperação preservados, usar boot UEFI temporário de mídia externa. A primeira sessão é de diagnóstico; não particionar nem gravar firmware. Se o kernel de desenvolvimento não tiver cadeia de assinatura aceita, ajustar Secure Boot no Lenovo após preservar a chave BitLocker e registrar a configuração para restauração.

Começar em console/TTY com logs visíveis; teclado USB e rede externa podem ajudar no diagnóstico. Registrar no Lenovo:

```bash
uname -a
lscpu
tr '\0' '\n' < /proc/device-tree/compatible
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
lspci -nnk
lsusb
sudo journalctl -b -k --no-pager
```

Conferir seis CPUs, ausência de erros de IOMMU/falhas de armazenamento, acesso ao NVMe sem escrita, USB estável, fonte/bateria e temperaturas coerentes. Verificar primeiro a transferência de energia/controle térmico; não alterar manualmente ventoinhas. Capturar nomes de firmware ausente e corrigir sua origem/seleção em 3.

Avançar para DRM/GPU, teclado/touchpad, Wi-Fi/Bluetooth e áudio conforme a matriz. Documentar cada teste com kernel/DTB/firmware e resultado. Só liberar instalação quando mídia USB permanecer estável, o armazenamento estiver íntegro, a entrada e o caminho de recuperação forem utilizáveis e não houver problema térmico/energético conhecido.

### 5. Instalação e recuperação

Escolher particionamento no Anaconda somente após 4. Preservar Windows/OEM e a ESP existente; registrar UUIDs e plano antes de confirmar as alterações. Não há comando de formatação ou instalação automática neste roteiro.

Antes do primeiro reboot, verificar no sistema instalado:

- Kernel e módulos do porte, firmware e DTB da variante Kalambo presentes.
- Initramfs reconstruído para esse kernel e dependências presentes.
- Entrada UEFI aponta para os artefatos/UUIDs corretos; Windows permanece acessível.
- Uma entrada de recuperação e a mídia USB permitem voltar ao sistema sem depender do boot NVMe.

Testar boot frio, reboot, Windows pelo menu UEFI e retorno à mídia USB. Verificar inicialização após uma atualização de kernel: preservar kernel anterior e não promover um kernel stock sem DTB/firmware correspondente. O helper `rescue-installed-boot` ASUS precisa de adaptação antes de servir aqui.

### 6. Niri e Noctalia 5.5.0

Fazer esta etapa no Fedora aarch64 instalado, depois do teste de aceleração DRM/EGL. [Niri exige aceleração de hardware funcional](https://niri-wm.github.io/niri/Packaging-niri.html). Conferir renderer EGL/OpenGL e evitar considerar renderização por software como aprovação do requisito.

Consultar as versões disponíveis para a arquitetura real:

```bash
dnf repoquery --available niri noctalia
```

O userspace live já contém Niri 26.04 e Noctalia nativo 5.5.0 aarch64, verificados em VM. Os procedimentos abaixo são referência para reconstrução ou instalação futura; não são nova pendência de empacotamento.

A [página Fedora 45 consultada](https://packages.fedoraproject.org/pkgs/noctalia/noctalia/fedora-45.html) apresentava Noctalia **5.2.1**; a [Rawhide](https://packages.fedoraproject.org/pkgs/noctalia/noctalia/fedora-rawhide.html) já mostrava 5.5.0, com metadados exibidos de x86_64. Isso não comprova um RPM estável aarch64 5.5.0. Verificar o repositório atual antes de instalar; não misturar dependências de Rawhide no Fedora 45.

Instalar Niri e integração do desktop pelos repositórios Fedora:

```bash
sudo dnf install niri xwayland-satellite \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
  gnome-keyring nautilus alacritty \
  pipewire wireplumber NetworkManager bluez \
  mesa-dri-drivers mesa-libEGL
```

Se `noctalia` **5.5.0 aarch64** estiver disponível, instalar a versão exata oferecida pelo Fedora e registrar seu NEVRA. Se não estiver, construir a [tag oficial v5.5.0](https://github.com/noctalia-dev/noctalia/releases/tag/v5.5.0), commit `c2573248a89470383e41b8e1ac432424691cbc1f`, em prefixo de usuário ou pacote RPM revisado. A [documentação de build](https://docs.noctalia.dev/noctalia/getting-started/installation/) lista dependências Fedora e comandos `just`; registrar qualquer adaptação de bibliotecas necessária ao Fedora 45. Não substituir silenciosamente por 5.2, snapshot git ou Quickshell v4.

Usar a sessão fornecida pelo pacote Niri no gerenciador de login, ou `niri-session` em TTY. Ela é necessária para os portais. Acrescentar apenas esta linha à configuração Niri existente, preservando seus atalhos:

```kdl
spawn-at-startup "noctalia"
```

O executável da v5 é `noctalia`. Não usar instruções antigas de `qs -c noctalia-shell`. Evitar dois daemons de notificação/agentes de autenticação concorrentes. Confirmar um agente polkit funcional e bloqueio de tela antes de habilitar suspensão automática.

Validar `niri validate`, versões instaladas, launcher/barra, autenticação, notificações, áudio/microfone, rede, brilho, clipboard, aplicativos X11 e seletor de arquivos/compartilhamento de tela pelos portais. Preservar uma sessão de recuperação até essas verificações passarem.

### 7. Cores e conclusão

Executar [CORES.md](CORES.md). A entrega precisa separar perfis exportados, instalados e efetivamente aplicados no painel correto. Se o compositor não oferecer o caminho necessário, manter esse requisito como bloqueado e documentar o trabalho restante, preservando Niri como escolha do usuário.

Depois, completar câmera/IR, vídeo, NPU, suspensão e USB4 conforme a prioridade e a matriz; esses recursos têm resultados próprios. Registrar consumo, temperaturas, carga, saída de suspensão e estabilidade do desktop em uso prolongado. Não chamar o sistema de pronto para uso diário apenas porque chegou ao login.
