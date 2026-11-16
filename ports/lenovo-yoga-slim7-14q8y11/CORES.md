# Perfis de cores Lenovo

## Estado ao pausar em 13/11/2026

R2 preserva o payload live e os sete ICC; R3 modifica só o menu do USB. Perfis exportados, conferidos e incluídos no live/VM; aplicação no painel pelo Niri não validada. Nenhuma mudança de cores nesta pausa.


Requisito incluído em 2026-11-13 a partir da foto do usuário. A foto comprova os nomes disponíveis no menu, mas não contém os bytes dos perfis e não identifica sozinha o painel do novo notebook.

**Atualização:** os sete perfis originais foram obtidos na [coleta Windows de 13/nov](COLETA-WINDOWS-2026-11-13.md), copiados para o PC e conferidos por SHA-256. Suas descrições internas correspondem exatamente aos rótulos da foto. A aplicação no Linux permanece pendente.

| Nome visto na foto | Arquivo original | Aplicação Linux |
|---|---|---|
| `LEN88AE_AdobeRGB` | `TPLCD_88AE_AdobeRGB.icm` preservado | A validar |
| `LEN88AE_DCIP3` | `TPLCD_88AE_DCIP3.icm` preservado | A validar |
| `LEN88AE_Default` | `TPLCD_88AE_Default.icm` preservado; contém `vcgt` | A validar |
| `LEN88AE_DisplayP3` | `TPLCD_88AE_DisplayP3.icm` preservado | A validar |
| `LEN88AE_Native` | `TPLCD_88AE_Native.icm` preservado; contém `vcgt` | A validar |
| `LEN88AE_REC709` | `TPLCD_88AE_REC709.icm` preservado | A validar |
| `LEN88AE_sRGB` | `TPLCD_88AE_sRGB.icm` preservado | A validar |

Os rótulos podem vir da descrição interna do ICC, não do nome do arquivo. Não inventar extensões ou gerar perfis genéricos com esses nomes. **DCI-P3 e Display P3 são perfis diferentes**; preservar ambos como fornecidos.

Na [ISO experimental](iso/README.md), os sete arquivos são instalados intactos
em `/usr/share/color/icc/lenovo/`, com manifesto SHA256. Nenhuma transformação
de saída ou curva `vcgt` é aplicada automaticamente; a associação entre EDID,
modo do painel e perfil, e o suporte efetivo do Niri continuam pendentes.

## 1. Preservar antes de reinstalar

O [coletor Windows](windows/LEIA-ME.md) automatiza a cópia da pasta de cores e dos ICC/ICM disponíveis nas pastas opcionais Lenovo/X-Rite/usuário, além de EDID, associações ICM e DriverStore completo. Os hashes ficam em `manifest-sha256.csv`; os rótulos foram associados às descrições internas na primeira coleta. A versão original foi executada no aparelho; a revisão v2 ainda não. O coletor não aplica os perfis no Linux.

O [PSREF Lenovo](https://psref.lenovo.com/syspool/Sys/PDF/Yoga/Yoga_Slim_7_14Q8Y11/Yoga_Slim_7_14Q8Y11_Spec.pdf) declara calibração de fábrica X-Rite e diferentes painéis OLED. Os perfis devem ser os do próprio aparelho e do modo de tela correspondente.

No Windows original:

1. Abrir Gestão de Cores (`colorcpl`) e as configurações de vídeo. Registrar o monitor escolhido, o perfil padrão, os sete rótulos/arquivos, estado SDR/HDR, brilho e o modo selecionado no utilitário Lenovo/X-Rite, quando existir.
2. Copiar **a pasta inteira** `C:\Windows\System32\spool\drivers\color` para `E:\Yoga-14Q8Y11\color`, preservando nomes. Fazer isso mesmo se nenhum arquivo se chamar `LEN88AE`: o nome interno pode ser diferente.
3. Preservar os pacotes de display/calibração do [suporte Lenovo](https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/yoga-series/yoga-slim-7-14q8y11/downloads/driver-list) e a exportação dos drivers descrita no workflow. Se algum perfil não estiver na pasta de cores, localizar o arquivo real no pacote/DriverStore ou utilitário Lenovo e copiar mantendo sua origem. Não baixar um ICC aleatório de outro painel.
4. Exportar o EDID bruto do painel e registrar fabricante, product ID, resolução e touch. Confrontar `LEN88AE` com esse EDID; o prefixo da foto não deve ser imposto ao equipamento sem confirmação.
5. Calcular SHA-256 dos arquivos copiados. Nesta coleta, os originais estão em `local/windows/2026-11-13/Yoga-14Q8Y11-20261113-090057-d44470f5/colors/windows/`, com hashes conferidos. Os blobs permanecem fora do Git.

Hash no PowerShell, depois de copiar:

```powershell
Get-ChildItem -LiteralPath 'E:\Yoga-14Q8Y11\color' -Recurse -File |
    Get-FileHash -Algorithm SHA256 |
    Export-Csv -NoTypeInformation -Path 'E:\Yoga-14Q8Y11\color-sha256.csv'
```

Criar um manifesto com uma linha por perfil: rótulo, caminho/arquivo original, SHA-256, descrição ICC, versão, classe, espaço de cor, PCS, presença de `vcgt`, EDID/painel de destino, modo SDR/HDR e origem/pacote. Não expor número de série do painel ao publicar o relatório.

## 2. Registrar a diferença entre preservar e aplicar

**Não foi localizado suporte documentado de ICC completo por saída no Niri consultado.** Foram inspecionadas a [configuração de outputs](https://github.com/niri-wm/niri/blob/73a04441fccc78294c3899af8f8cdd2a1e38fa33/docs/wiki/Configuration%3A-Outputs.md), a [estrutura da configuração](https://github.com/niri-wm/niri/blob/73a04441fccc78294c3899af8f8cdd2a1e38fa33/niri-config/src/output.rs) e o [protocolo gamma-control](https://github.com/niri-wm/niri/blob/73a04441fccc78294c3899af8f8cdd2a1e38fa33/src/protocols/gamma_control.rs), na revisão de 2026-11-13. Há também a [discussão upstream sobre ICC](https://github.com/niri-wm/niri/discussions/2458). A documentação Context7 não retornou instrução de ICC para esse compositor.

Isso deixa a aplicação integral dos perfis como **bloqueio de integração a verificar na versão instalada**. Não adicionar uma chave KDL `icc-profile` inventada nem marcar suporte com base em gamma-control.

| Caminho | O que comprova | Limite para este requisito |
|---|---|---|
| Copiar ICC/ICM para `~/.local/share/icc` | Preservação e disponibilidade dos arquivos | Não transforma a imagem sozinha |
| Importar/associar em colord | Registro e associação ao dispositivo | Não obriga o compositor Wayland a usar o perfil |
| Aplicativo que aceita perfil de monitor | Gestão de cor dentro daquele aplicativo | Não cobre todo o desktop; verificar se o app usa corretamente o perfil selecionado |
| `vcgt` por gamma-control, se houver e se o driver aceitar | Calibração das curvas de canal | Não implementa a transformação de gamut/LUT do ICC completo; pode conflitar com night light |
| Compositor com pipeline ICC completo | Transformação por saída, conforme implementação | Precisa ser implementado/confirmado no Niri para cumprir a combinação pedida |

Noctalia fornece a shell; não substitui a pipeline de cores do compositor. A documentação do projeto para **Umbriel** tem opções de perfil de saída, mas essas opções pertencem a outro compositor e não são configuração Niri. Não trocar o compositor pedido silenciosamente.

Guardar os perfis já permite seu uso em aplicações compatíveis, enquanto o suporte global é investigado. Um modo de emulação sRGB aplicado pelo firmware da tela pode ser outra parte do comportamento Windows: só assumir equivalência após verificar persistência entre sistemas e medir o resultado.

## 3. Instalar os arquivos depois da coleta

No Fedora, criar `~/.local/share/icc/lenovo-yoga-14q8y11/` e copiar os perfis exportados preservando seus nomes. Comparar os hashes com os originais antes de associar qualquer perfil. Manter `Default`/`Native` disponíveis para reversão e registrar qual perfil foi associado a cada saída.

Inspecionar os ICC com ferramenta apropriada de perfis, verificando assinatura/cabeçalho e tags. O critério de aceite é ter correspondência comprovada entre **os sete rótulos e seus arquivos**; a simples contagem de sete arquivos não basta.

Não converter, editar primárias, gerar um `vcgt` artificial ou substituir a calibração de fábrica por um perfil padrão. Caso o arquivo não seja um ICC/ICM convencional, preservar o original e identificar seu formato antes de tentar aplicação.

## 4. Testar o efeito

Registrar versões de kernel, Mesa, Niri e Noctalia, saída DRM/EDID, perfil/hash, modo SDR/HDR e brilho. Para cada um dos sete perfis:

- Confirmar que a seleção afeta a saída correta e persiste depois de logout/reboot.
- Validar escala de cinza, ponto de branco, gradientes, tons de pele e patches saturados com conteúdo sRGB, Display P3 e Adobe RGB conhecido.
- Distinguir transformação global de comportamento de um aplicativo; evitar aplicação duplicada do mesmo ajuste.
- Desativar night light e outros ajustes durante a comparação, depois testar sua convivência.
- Medir com colorímetro/espectrofotômetro quando disponível, registrando alvo e erro; comparação visual e screenshot não certificam a saída física.

HDR/10-bit deve ter teste próprio de compositor/driver/painel. O nome de um ICC, a etiqueta HDR do painel ou o tema Noctalia não demonstram HDR funcional.

Estado atual: **sete arquivos exportados, preservados localmente e verificados; aplicação global no Niri não comprovada**. O requisito completo só estará concluído com evidência do caminho de aplicação na tela correta. Os EDIDs LEN88AE/SDC4208 obtidos têm checksums válidos, mas avisos de conformidade/extensões registrados no relatório; seus bytes foram mantidos intactos.

A [ISO Lenovo Diagnostics ARM 5.2.1 foi inspecionada](ISO-LENOVO-DIAGNOSTICS-5.2.1.md): seus 52 ICC de distribuição não incluem marcadores LEN88AE nos nomes ou conteúdo examinado. Ela não fornece os sete perfis originais pedidos.
