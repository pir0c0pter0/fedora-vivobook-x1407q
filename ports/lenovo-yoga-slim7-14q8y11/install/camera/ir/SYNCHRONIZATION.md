# Sincronização IR: ensaio privado de um quadro

Estado em 17/11/2026: **ensaio físico V2 aprovado**. Um quadro foi capturado
com 50 mA totais e limite de 10 ms, sem falhas do flash; o desligamento e a
restauração do registro original foram confirmados por leitura. As variantes
privadas também passaram na compilação W=1, nos testes locais de falha e na
revisão independente.

Os módulos diagnósticos e o DT com `st,leds` continuam exclusivos deste ensaio.
Não foram promovidos para aplicativos ou para o funcionamento normal das câmeras.

## Resultado físico V2 — 17/11/2026, 09:49 BRT

O arquivo privado `ir-sync-v2.raw` contém exatamente 384000 bytes: um quadro
640×480 Y10P, stride 800. Os controles confirmados foram exposição manual de
1166 linhas, ganho analógico 24 e ganho digital 2048. A tentativa foi consumida
pelo driver do sensor; este protocolo usa uma amostra por boot.

| Etapa | Timer canais 1+4 | Corrente canais 1+4 | Módulo / canais | ee67 bit0 |
| --- | --- | --- | --- | --- |
| OFF inicial | `93 / 93` (anterior) | `00 / 00` (anterior) | `00 / 00` | 1 |
| Armado externo | `80 / 80` (10 ms) | `01 / 01` (25 mA por canal) | `80 / 09` | 0 |
| Cleanup final | `80 / 80` | `01 / 01` | `00 / 00` | 1 |

O snapshot após o quadro registrou `faults=0`; cleanup terminou com `errors=[]`.
O kernel confirmou `saved=1` e `restored=1`, sem WARN/Oops durante o ensaio.
A observação óptica é compatível com iluminação disparada por hardware durante
a exposição. A amostra isolada não mede a largura elétrica do pulso, não prova
o rearme contínuo do safety timer e não valida um serviço de iluminação para apps.

Evidências privadas em `local/physical-2026-11-17/camera-calibration/`:
`sync-v2.txt`, `sync-v2-kernel.txt`, `sync-v2-controls.txt` e `ir-sync-v2.raw`.
As imagens e arquivos Windows permanecem locais.

O primeiro ensaio identificou uma falha de restauração em MODE_NONE, apesar de
terminar com ambos os gates desligados. O valor anterior foi recuperado pelo
remove do módulo, confirmado fisicamente. A V2 corrigiu os callbacks OFF usados
pelo wrapper; um teste integrado reproduziu a falha anterior e validou a correção.
O preflight antigo da V2 também foi ajustado para aceitar registradores anteriores
com gates OFF, mantendo a verificação física rigorosa após armar e antes da captura.

## O que os arquivos originais confirmam

O script `inspect-windows-ir.py EXPORT OUTPUT_PRIVADO` extrai inventário,
regsets, perfil da plataforma e hashes sem acessar hardware. Resultados desta
unidade ficam em `local/physical-2026-11-17/camera-calibration/ir/`, fora dos
artefatos distribuídos. Nenhuma calibração binária Windows é instalada.

`CAMP_PCFG_QRD.bin`: bitmap `0x306`, sensor slot 2 com word `0x01000110`:
master 0, CSIPHY0, flash presente, autenticação facial e triggerType 0.
O driver Windows seleciona hardware strobe para esse tipo. O caminho CCI
pinId 0 / ncid 1 / callbackId 6 pertence ao tipo 1, que não está selecionado aqui.
`6` é callbackId, não GPIO6.

O regset VD55G0 alterna dois contextos de um quadro: contexto 0 deixa GPIOs
baixos; contexto 1 coloca GPIO0 em strobe (`0x0497=2`), mantendo os outros baixos.
O PMIC original escolhe entrada de strobe 0 e HW/level/active-high nos canais
1+4. Isso fundamenta a rota sensor GPIO0 → entrada strobe do flash; o ensaio
físico limitado apresentou resposta óptica compatível com essa ligação.

A configuração também escreve pedestal de preto 64 (`0x0416`), mantém exposição
manual inicial de 1166 linhas e largura de linha 1200. O regset inicial contém
ganho digital 0 e metadata maxAnalogGain 8, mas o manual define ganho digital
unitário como 256 e mapa analógico 0..24 como 1..4×. Esses valores iniciais e
metadata não devem ser copiados cegamente como calibração operacional. O driver
Linux já usa darkcal automático e duster; ainda não portamos tuning temporal
proprietário Qualcomm.

## Limite do ensaio

O [manual ST UM2829](https://www.st.com/resource/en/user_manual/um2829-how-to-integrate-and-configure-the-vd55g0-device-from-a-hardware-and-software-perspective-stmicroelectronics.pdf)
§15/p.38 e tabela 51/p.61 descrevem COUNT/NEXT: COUNT=1 com NEXT=0xff termina
após um quadro em standby. §18/p.45 define strobe como envelope da exposição;
GPIOs ficam ativos apenas durante streaming. Essa parada pelo sensor não depende
de um temporizador do processo.

`vd55g0-single-frame-test.patch` é aplicado a uma cópia privada do driver:

- `diagnostic_one_frame=1` aceita exposição manual de até 10 ms;
- zera os deslocamentos das duas bordas e confirma COUNT=1/NEXT=0xff por leitura;
- consome a tentativa antes de START, inclusive se a escrita falhar;
- bloqueia nova tentativa e alterações de controle após START, permitindo OFF;
- aceita que o estado streaming já tenha terminado ao verificar o comando;
- o caminho com parâmetro false mantém o comportamento original.

Com link de 420 MHz, o clock de temporização do driver é 140 MHz e linha 1200:
1166 linhas ≈ 9,994 ms; 1167 linhas é rejeitado. O clock de saída RAW10 de 84 MHz
do arquivo Windows é outra grandeza e não deve calcular o tempo da exposição.

`qcom-flash-external-strobe.patch`, após `qcom-flash-cleanup.patch`, desliga
canais antes de trocar HW/SW, programa corrente e safety timer com ambos os
gates desligados, depois arma. Falhas tentam desligar ambos os gates. É
necessário porque o caminho original external_strobe apenas armava o flash,
e o OFF da função torch usado pelo wrapper V4L2 desabilita o timer.

O wrapper `yoga-camera-sync-test.dts` acrescenta `st,leds=<0>` e a referência
V4L2 `flash-leds`; reduz a corrente máxima total para 50 mA e mantém 10 ms. O driver
sensor já usa `v4l2_async_register_subdev_sensor`, que processa essa referência.
Esse DT precisa dos módulos de teste; não habilitar carregamento automático
nem instalar `st,leds` no DT usado por aplicativos.

## Reprodução privada do bit ee67

O chamador Windows `qccamflash8480.sys` em VA `0x140006134` seleciona hardware
strobe e envia o payload `[1,1,0,1,0]` pelo IOCTL `0x802f0fd0`. Na implementação
PMH0101/modelo `0x5d` de `qcpmic8480.sys`, VA `0x140027370` escreve o último
booleano em `0xee67`, máscara 1, somente quando hardware strobe está selecionado.
Assim, o perfil desta placa exige bit0=0; o baseline Linux medido tinha bit0=1.
O significado funcional exato desse bit e o rearme do safety timer não foram
recuperados. O mapa de registradores de PMICs de três canais não foi extrapolado.

`qcom-flash-windows-ee67-test.patch` é uma terceira camada **privada de teste**,
aplicada após cleanup e external-strobe. Requer `diagnostic_windows_ee67=1`;
valida PMH0101, modelo 0x5d, periférico de quatro canais, revisão 1, base ee00 e
um único LED. No armamento exige canais 1+4, corrente total até 50 mA e timer de
10 ms. Com os gates desligados, salva e registra o bit anterior, escreve somente
bit0=0 e confirma a leitura antes de armar. As outras posições do registro são
preservadas por regmap_field.

OFF tenta desligar canais e módulo independentemente. A restauração só acontece
após leitura física confirmando ambos desligados; divergência ou falha mantém
o valor salvo pendente e retorna erro. Falhas durante preparação também passam
por esse OFF. Na versão corrigida, brightness=0 e flash_strobe=false também
chamam essa rotina: são os callbacks usados pelo MODE_NONE do wrapper V4L2.
Mudar SOURCE para software depois de MODE_NONE apenas atualiza o cache; por isso
não se pode depender só de external_strobe_set(false). O helper verifica o bit
restaurado ao terminar. `remove` tenta OFF e restauração, mas sua assinatura void permite apenas registrar uma falha:
**confirmar cleanup OFF e bit restaurado antes de descarregar/trocar o módulo**.

## Build e operação

Cópias locais compiladas sem alterar kernel/configuração do baseline:

- `local/iso-build/extmod-vd55g0-single/vd55g0.ko`;
- `local/iso-build/extmod-yoga-flash-sync-test/leds-qcom-flash.ko`;
- `local/iso-build/extmod-yoga-flash-sync-test/v4l2-flash-led-class.ko`.

O wrapper V4L2 foi compilado externamente da mesma árvore, com
`ccflags-y += -DCONFIG_V4L2_FLASH_LED_CLASS_MODULE=1` nos dois módulos flash.
Carregar o wrapper V4L2 antes do flash privado com `diagnostic_windows_ee67=1`;
carregar VD55G0 privado com `diagnostic_one_frame=1`. O módulo e DT `current`
permanecem preservados. Hashes estão no manifesto privado `ir/build-manifest.json`.

A [API V4L2 de flash](https://github.com/torvalds/linux/blob/master/Documentation/userspace-api/media/v4l/ext-ctrls-flash.rst)
oferece source external, LED mode flash e intensidade/timeout. O helper
`sync-pulse-test.py` mantém o FD do flash aberto durante a captura de um quadro;
fechar esse FD retorna a fonte a software e desarma o modo externo. Comandos
`v4l2-ctl` separados para armar perderiam o estado ao fechar o dispositivo.

O helper usa OFF/preflight por padrão; `--fire` é explícito. Recebe os caminhos
sensor, flash, video e arquivo privado de saída. Requer câmera previamente
configurada para 640×480/Y10P/stride 800, exposição manual ≤1166 linhas, sem outro
consumidor. Fazer a transição `auto_exposure=1` em um comando e definir
`exposure=1166` em outro; o lote único observado preservou o valor automático
anterior. Confirmar a leitura manual antes do ensaio. Verifica a identidade
qcom-camss do vídeo antes de armar. Com gates OFF, confirma intensidade/timeout
solicitados no cache sysfs e V4L2;
aceita os registradores de corrente/timer anteriores. Depois de armar e antes
de iniciar a captura, confirma timers 0x80, correntes 0x01 nos canais 1+4,
resolução 12,5 mA, fonte/polaridade e
identidade do hardware. Aceita o bit ee67 original em preflight; exige zero
armado e o original ao terminar. Executa captura `--stream-count=1`, limita a
espera a 8 s, exige 384000 bytes e tenta OFF por V4L2 e sysfs com leitura final.
A espera é por conclusão da captura; não sincroniza nem determina o pulso.
O operador também deve verificar `faults=0`: esse valor é registrado pelo helper,
mas um fault não causa exceção automaticamente.

Nenhum modo contínuo foi implementado. O comportamento de rearme do safety timer
por borda ainda não foi provado; o limite de um quadro evita depender disso.

## Verificação local

`test_external_strobe.py FONTE_PATCHED` executa funções C reais com 12 falhas de
escrita injetadas; `test_single_frame.py FONTE_PATCHED` cobre 15 falhas, limite de
exposição, leitura divergente e tentativa única. `test_windows_ee67.py FONTE_TESTE`
cobre 15 posições de falha no armamento e 9 em OFF, com bit inicial zero/um e
escritas que podem ter sido aplicadas apesar do erro. Também verifica rejeição
de readback OFF divergente, limites, campos não modificados e opt-out inalterado.
`test_flash_wrapper.py FONTE_TESTE FONTE_WRAPPER` executa o s_ctrl/close reais
com os callbacks do driver: reproduz a falha da primeira variante e valida a
correção, 14 posições de falha no OFF (com e sem escrita aplicada), close direto
e retries por sysfs. A camada de dispatch LED síncrono e regmap é simulada.
`test_sync_pulse_test.py` cobre OFF com registradores anteriores, rejeição de
gates ativos e 12 configurações armadas incorretas.
Os testes não demonstram duração óptica medida ou estabilidade CCI.
