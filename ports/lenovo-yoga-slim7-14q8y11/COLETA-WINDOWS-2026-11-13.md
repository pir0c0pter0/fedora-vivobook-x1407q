# Resultado da primeira coleta Windows — 2026-11-13

> Relatório histórico da aquisição: a montagem somente leitura descrita abaixo ocorreu antes das gravações de ISO autorizadas. A coleta permanece preservada no PC; o pendrive hoje contém o diagnóstico R3-CONS. Ver [retomada](RETOMADA.md).

**A coleta foi preservada integralmente no PC de build.** Os 6.430 arquivos do manifesto Windows passaram na conferência SHA-256. A cópia local contém 6.433 arquivos, todos comparados com os bytes lidos do pendrive, totalizando **6.783.459.253 bytes**. Os arquivos da raiz do USB foram preservados separadamente e também conferidos.

O pendrive foi montado **somente para leitura**. Nenhum resultado nele foi sobrescrito, atualizado ou removido.

## Onde estão os dados locais

Caminhos relativos a esta pasta do porte:

```text
local/windows/2026-11-13/
  Yoga-14Q8Y11-20261113-090057-d44470f5/         coleta completa original
  Yoga-14Q8Y11-20261113-090057-d44470f5-verification.json
  usb-root/                                    conteúdo do USB fora de Coletas/
  usb-root-verification.json
  analysis/preliminary-analysis.json
  analysis/edid-registry-0000-decode.txt
  analysis/edid-registry-0001-decode.txt
```

`usb-root/` preserva os launchers, ZIP, instruções, manifesto da preparação e metadados presentes na raiz do USB. A única subpasta em `Coletas/` foi copiada integralmente para o diretório com o mesmo nome mostrado acima; não há dependência do pendrive para continuar a análise.

As evidências locais são ignoradas pelo Git. Contêm identificadores do aparelho, EDID e arquivos dos fabricantes; não publicar os dumps ou perfis sem revisão de conteúdo/licença.

## O que significou “parcial”

O journal registra **25 etapas `ok`, uma `incomplete` e duas pastas opcionais `not-present`**. `hash-errors.json` está vazio.

A única etapa incompleta foi `edid-registry`: a enumeração recursiva encontrou três recusas de acesso a subchaves protegidas `Properties`. Apesar disso, foram salvos **dois EDIDs** com seus caminhos de origem no índice. Esse aviso não invalida as exportações de drivers, os perfis ou a aquisição ACPI anterior.

Resultados relevantes dos logs:

- PnPUtil: **188 pacotes encontrados, 188 exportados**.
- Cópia do DriverStore: **3.275 arquivos copiados**, zero falhas e zero divergências informadas pelo Robocopy.
- Inventário, propriedades PnP, recursos, ACPI nativa e do registro, associações ICM e pasta de cores: etapas `ok`.
- Ausentes: pasta opcional de ICC do usuário e pasta opcional `ProgramData/X-Rite`. A pasta de cores Windows contém os sete perfis pedidos.

O script `collector.ps1` da aquisição é idêntico ao que foi distribuído no ZIP inicial. A correção EDID v2 permaneceu no PC de build e não foi executada no Lenovo nesta coleta.

Um arquivo adicional, `drivers/System32-drivers/Msft_User_WpdFs_01_11_00.Wdf`, estava no USB mas não no manifesto Windows. Ele foi preservado e recebeu SHA-256 na verificação local. Os outros dois arquivos fora do manifesto são `manifest-sha256.csv` e `hash-errors.json`, excluídos intencionalmente pelo coletor. Portanto, “manifesto válido” e “todos os arquivos presentes copiados” foram verificados separadamente.

**Não é necessário repetir DriverStore/exportação completa apenas por esse aviso EDID.** Usar os dados existentes e só solicitar complemento quando uma lacuna concreta for identificada.

## Hardware confirmado pelo Windows

| Item | Observado |
|---|---|
| Família/modelo | Lenovo Yoga Slim 7 14Q8Y11 / `83QR` |
| CPU | Snapdragon X2 Plus **X2P42100**, Qualcomm Oryon, ARM64 |
| Núcleos/threads | **6 / 6** |
| Memória | Aproximadamente **16 GB** de classe instalada; valor exposto pelo Windows registrado no inventário |
| BIOS | **TCCN37WW** |
| Windows | Windows 11 Home ARM64, build **28000** |
| PowerShell da coleta | **5.1.28000.1** |
| GPU | **Qualcomm Adreno X2-45**, driver Windows `32.0.152.6` |
| Modo de vídeo observado | **1920 × 1200, 60 Hz** |
| Rede | Qualcomm **FastConnect 7800 Wi-Fi 7** e Dual Bluetooth |
| Armazenamento interno | Samsung `MZAMX512HDLV-00BL2`, aproximadamente **512 GB**, GPT |
| Entrada | Há dispositivo HID de tela touch no inventário; a identificação dos controladores e sua ligação à placa exige análise dos recursos |

Isso confirma o X2P-42-100 escolhido pelo catálogo. A associação desse SKU a Kalambo continua baseada nas fontes do SoC; um ID SMEM/SoC lido no Linux ainda não foi medido. Funcionamento no Windows não demonstra funcionamento dos drivers Linux.

## Perfis Lenovo obtidos

Os sete arquivos de fábrica foram encontrados em `colors/windows/`. A inspeção de cabeçalho e tags ICC confirmou a correspondência entre nome de arquivo e descrição interna:

| Arquivo original | Descrição interna ICC | Tag `vcgt` |
|---|---|---|
| `TPLCD_88AE_AdobeRGB.icm` | `LEN88AE_AdobeRGB` | Não |
| `TPLCD_88AE_DCIP3.icm` | `LEN88AE_DCIP3` | Não |
| `TPLCD_88AE_Default.icm` | `LEN88AE_Default` | Sim |
| `TPLCD_88AE_DisplayP3.icm` | `LEN88AE_DisplayP3` | Não |
| `TPLCD_88AE_Native.icm` | `LEN88AE_Native` | Sim |
| `TPLCD_88AE_REC709.icm` | `LEN88AE_REC709` | Não |
| `TPLCD_88AE_sRGB.icm` | `LEN88AE_sRGB` | Não |

Os sete são perfis RGB. Não foram editados, convertidos ou instalados em nenhum Linux. `vcgt` em Default/Native não fornece uma solução geral de gamut para os demais perfis; o bloqueio de aplicação integral no Niri continua separado da aquisição bem-sucedida dos arquivos.

## EDID e ACPI: dados úteis, limites preservados

- EDID Lenovo `LEN88AE`, nome `LEN140WUXGA`: **384 bytes**, timings 1920×1200 a aproximadamente 60 Hz; checksums dos blocos válidos.
- EDID Samsung `SDC4208`: **128 bytes**, mesmos timings base; checksum válido.
- O `edid-decode --check` apontou inconsistências de conformidade: o primeiro declara uma extensão mas contém dois blocos após a base, incluindo bloco não reconhecido; o segundo declara uma extensão que não está presente. Há também avisos de CTA/strings. **Não normalizar ou corrigir os bytes originais para esconder esses avisos.** A relação entre EDID físico, override Lenovo e dados expostos pelo driver precisa ser esclarecida.
- Foram preservados **22 arquivos de tabelas ACPI**, correspondentes a **20 hashes distintos**. A cópia via API tem 17 entradas; o complemento do registro tem cinco. Há DSDT, FACS, FACP, XSDT, SSDT, IORT, MCFG, CSRT e outras tabelas. As duplicatas entre métodos foram mantidas.
- Os arquivos ACPI inspecionados têm comprimento coerente e checksum válido quando aplicável. Isso não comprova cobertura de todos os SSDTs/overlays dinâmicos. A aquisição nativa só retorna a primeira tabela de uma assinatura repetida.

Ainda não foram decompiladas e auditadas as tabelas para construir o DTS da placa.

## Firmware e próximo trabalho

A inspeção preliminar encontrou **127 ocorrências de `.mbn`, `.elf`, `.jsn`, `.fw` e `.tplg`, com 45 hashes distintos**, entre cópias de pacotes e caminhos preservados. Exemplos: `qcadsp8480.mbn`, `adsp_dtbs.elf`, `qccdsp8480.mbn`, `cdsp_dtbs.elf`, `qcdxkmsuc8480.mbn`, `qcvss8480.mbn` e imagens de câmera. Arquivos `.bin` e outros formatos ainda precisam ser catalogados conforme os drivers reais.

Próximo passo: usar ACPI, propriedades/recursos PnP e pacotes instalados para mapear GPU, painel, IRQs/GPIOs, reguladores, armazenamento, rede e áudio ao DTS Kalambo da placa. Não selecionar blobs pela semelhança do nome com a variante Elite.

Não houve boot Linux, instalação Fedora ou teste de aplicação dos perfis no Lenovo nesta etapa. As pendências agora são de análise/porte, não de recuperar novamente toda a exportação já preservada.
