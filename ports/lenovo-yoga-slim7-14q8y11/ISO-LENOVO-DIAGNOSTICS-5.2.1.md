# Análise da ISO Lenovo Diagnostics ARM 5.2.1

Inspeção offline em **2026-11-13**, solicitada pelo usuário. Arquivo original:

```text
~/Downloads/ldiag_5.2.1_linux_arm64.iso
SHA-256: 053a9a276bdd5c3da9d3023a88c6ffa3b24dddab598e166740bb9a1f337a75b8
```

**O hash calculado coincide com o publicado pela Lenovo** na [página DS025448](https://pcsupport.lenovo.com/us/en/products/workstations/thinkstation-p-series-workstations/thinkstation-p300/downloads/DS025448). Isso verifica a correspondência com a imagem distribuída; não demonstra suporte ao Yoga X2 Plus.

Conclusão: é uma referência útil de mídia UEFI arm64, seleção de DTB e diagnóstico. **Não foi encontrado nela o conjunto específico para boot do Yoga Slim 7 14Q8Y11/X2P-42-100/Kalambo**, nem os perfis LEN88AE pedidos. Não substitui o DTS de placa e a coleta do Lenovo previstos no workflow.

## Conteúdo observado

| Componente | Resultado |
|---|---|
| Volume ISO | `Lenovo_Diag_Public_Linux-0.iso` |
| Estrutura de mídia | ISO9660, MBR protetora/GPT, boot El Torito UEFI e ESP FAT anexada |
| Carregadores | `EFI/boot/bootaa64.efi`, `grubaa64.efi`, `mmaa64.efi` |
| Sistema live | Ubuntu **26.04 LTS**, SquashFS/Casper |
| Kernel do live | **7.0.0-29-generic** |
| Kernel anterior no filesystem | `7.0.0-14-generic` |
| Mesa | `26.0.3-1ubuntu1` no manifesto |
| Kernel em `/casper/vmlinuz` | Executável PE arm64 com wrapper **Stubble 9-1**, seção `.linux`, `.hwids`, `.uname` e **32 seções `.dtbauto`** |
| Diagnóstico | Aplicativos arm64 em `/opt/lenovo/ldiag`, incluindo testes de CPU, memória, armazenamento, áudio, câmera, bateria e interfaces |
| Perfis de cor | **52 ICC** na árvore selecionada de cores; sem marcador `LEN88AE` nos nomes ou bytes inspecionados |

As [notas de versão oficiais ARM](https://download.lenovo.com/pccbbs/thinkvantage_en/ldiag_5.2.1_linux_release_notes_arm64.txt) corroboram a atualização da base para Ubuntu 26.04/kernel 7.0. O [guia ARM da versão](https://download.lenovo.com/pccbbs/thinkvantage_en/ldiag_5.2.1_linux_user_guide_arm64.pdf), seção 1.4, cita suporte oficial da aplicação aos ThinkPad X13s e T14s. A presença de outros DTBs não equivale a certificação de todos os modelos.

## O que o boot realmente seleciona

O GRUB da ISO detecta por SMBIOS alguns aparelhos e acrescenta parâmetros:

- ThinkPad X13s: `clk_ignore_unused pd_ignore_unused arm64.nopauth`.
- ThinkPad T14s Gen 6: `clk_ignore_unused pd_ignore_unused cma=128M`, com uma exclusão de memória específica.
- Yoga **Slim 7 14Q8X9**: `clk_ignore_unused pd_ignore_unused cma=128M`.

**14Q8X9 é diferente do 14Q8Y11 deste porte.** Não importar a exclusão de memória do T14s nem esses parâmetros como correção automática do Yoga X2.

O menu passa kernel e initrd Casper; não apresenta um comando explícito de `devicetree`. A seleção dos DTBs embutidos é feita pelo wrapper Stubble, com informações de hardware em `.hwids`. Foram extraídas as 32 seções e lidas suas propriedades raiz `model`/`compatible`.

O Yoga encontrado nesse conjunto é:

```text
model: Lenovo Yoga Slim 7x
compatible: lenovo,yoga-slim7x, qcom,x1e80100
```

É a variante X1. Há também T14s Gen 6 LCD/OLED, X13s, ThinkBook 16 Gen 7 QOY, Miix 630, Yoga C630, Flex 5G e aparelhos de outros fabricantes. **Nenhum dos 32 DTBs declara `qcom,kalambo`, `qcom,mahua` ou `lenovo,yoga-slim7x-gen11`.**

A listagem completa do SquashFS, incluindo os DTBs instalados para os dois kernels, também não revelou nomes `kalambo`, `mahua`, `83QR` ou `14Q8Y11`. Os aliases de módulos do kernel 7.0.0-29 incluem suporte parcial de blocos Glymur/Mahua, mas nenhum alias Kalambo nem Yoga Gen 11. Blocos de SoC presentes isoladamente não constituem suporte à placa.

## Firmware e initramfs

No filesystem existem imagens genéricas em `usr/lib/firmware/qcom/glymur/`, incluindo ADSP/CDSP, seus DTBs e `gen80100_zap.mbn.zst`. A existência desses arquivos não os transforma em firmware validado do Yoga Plus.

Não foram encontrados os caminhos específicos Lenovo `83QR` usados como referência no DTS Elite, nem firmware identificado como Kalambo. O initramfs inspecionado contém drivers de blocos Glymur e material X1, sem correspondência específica Kalambo/Yoga Gen 11. Os hooks `ubuntu-x1e-settings` copiam firmware dos diretórios `x1e80100` e `x1p42100`: são uma referência do processo, não uma configuração pronta para X2.

Os ICC encontrados são perfis de distribuição, incluindo AdobeRGB1998, Rec709 e outros. **Não substituem `LEN88AE_AdobeRGB`, `LEN88AE_Default` etc.** A exportação dos originais do Windows continua necessária.

A base SQLite PSREF incluída no diagnóstico contém aproximadamente 1,38 milhão de registros de MTM/portas, mas a consulta por prefixo `83QR` não retornou registros. Essa base não fornece um DTS nem calibração de painel.

## Integridade e limites da verificação

- O SHA-256 de toda a ISO corresponde ao valor oficial Lenovo.
- Os MD5 internos de kernel, initrd, manifesto, marcador `ubuntu` e `README.diskdefines` passaram.
- A entrada de `md5sum.txt` para **ele próprio** espera o hash de arquivo vazio e falha. É compatível com uma falha na ordem de geração do manifesto; não é evidência de alteração desta cópia, cujo SHA-256 completo confere.
- O SquashFS não está listado nesse manifesto MD5; seu hash SHA-256 foi registrado separadamente na auditoria local.
- Não foram executados binários Lenovo, feito boot físico, testada a cadeia Secure Boot contra as chaves do aparelho ou avaliado o código interno dos diagnósticos.

## Aproveitamento no porte Fedora

Manter como referência de **layout UEFI e Stubble/CHID**, manifestos, licença e organização de diagnóstico. Um mecanismo equivalente de seleção automática pode ser avaliado quando existir o DTB correto do Yoga Kalambo; ele não cria a descrição de hardware ausente.

Continuar com kernel/DTB/firmware próprios do porte e Fedora como userspace alvo. Copiar o kernel 7.0 desta ISO ou trocar o SquashFS por Fedora não fecha as dependências do X2 Plus. A ISO stock também não deve ser tratada como mídia de recuperação validada para o novo Lenovo sem teste no aparelho.

Evidências e arquivos extraídos ficam em `local/ldiag-5.2.1/`, ignorados pelo Git: `audit-summary.json`, `embedded-dtbs.json`, `pe-sections.json`, inventários de SquashFS/initramfs, notas/guia e extrações selecionadas. O arquivo original em Downloads foi apenas lido.
