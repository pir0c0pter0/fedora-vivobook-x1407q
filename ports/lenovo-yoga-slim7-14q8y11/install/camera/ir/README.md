# VD55G0 do Yoga

`vd55g0.c` reutiliza sem alteração funcional o driver GPL-2.0 proposto por
STMicroelectronics/Sergey Lebedev em **[PATCH v5 2/6] media: i2c: Add ST VD55G0
global shutter sensor driver**, de 14/11/2026:

- [Mensagem original](https://lore.kernel.org/all/20261114095815.74012-3-lsa.uz@pm.me/).
- [Espelho usado para obter o patch](https://lkml.indiana.edu/2611.1/21581.html).
- Git blob: `99bfb05225dbed943798eb40068ac3d06a529d77`, igual ao índice do patch.
- SHA-256: `ae58074928eacfaf96a58ebd4042463e61fbec880e40ccf5eace02dc4f009133`.

O espelho mascara os emails; os quatro emails dos autores foram restaurados,
e o hash Git confirma o arquivo original byte a byte. O firmware para as
revisões cut1/cut2 faz parte da fonte GPL; nenhum firmware Windows é incluído.

Compilação fora da árvore, usando o container e o kernel já preparados:

```sh
# A partir da raiz deste porte; o diretório local/iso-build é /work no container.
mkdir -p local/iso-build/extmod-vd55g0
cp install/camera/ir/vd55g0.c install/camera/ir/Kbuild local/iso-build/extmod-vd55g0/
podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp \
  M=/work/extmod-vd55g0 ARCH=arm64 LLVM=1 -j4 modules
```

O módulo compilou para `7.4.0-rc1-yoga-kalambo+`. Em 17/11/2026, o teste
físico confirmou captura real Y10P 640×480, aproximadamente 60 fps.
O fragmento `yoga-camera-ir.dtsi` depende de `camss/glymur-camera-soc.dtsi`
e `power/yoga-camera-power.dtsi`. O DT conjunto revisado passou no `try`
e no boot normal em 17/11; novas alterações devem voltar ao slot de teste.

## Evidência da placa

`CAMI_RES_QRD.bin`: clock 24 MHz, reset TLMM109, alimentação LDO1_I0
1,15 V, LDO4_I0 1,8 V, LDO3_I0 2,8 V. O PM8010 representa 1,15 V como
1,152 V. `CAMP_PCFG_QRD.bin` indica master0 e CSIPHY0. `SCFG_AUX_QRD.bin`
indica endereço I²C de 7 bits 0x10.

Em `com.qti.sensormodule.st_vd55g0.bin`, base de dados 0x1c024:

- `resolutionData`, offset relativo787: outputPixelClock em +52 = 84000000,
  numLanes em +80 = 1.
- `streamConfiguration`, offset relativo1039: tipo CSI-2 em +8 = 0x2b,
  largura/altura em +20/+24 = 640/480, bitWidth em +28 = 10.
- 84 MHz × 10 bits ÷ (1 lane × 2) = **420 MHz de link**. É uma inferência
  da configuração Windows, não uma medição. O driver aceita esse valor com
  XCLK24 MHz (840 MHz de dados / 24 MHz = 35).

O driver inicialmente oferece Y8; configurar explicitamente Y10 e 640×480
em toda a cadeia para reproduzir o formato Windows. Não definir `st,leds`
até comprovar a ligação ao iluminador: sem essa propriedade, o driver mantém
seus quatro GPIOs em entrada e não oferece controle de LED.

## Iluminador

O export original Windows `qccamflash_ext8480.inf` fixa a corrente IR em
700 mA. A análise de `qccamflash8480.sys` mostra que o caminho IR configura
LED lógico 1, habilita o safety timer e oferece disparo por software ou
via callback CCI. O nó ACPI FLSH/QCOM0F27 tem recursos vazios; nenhum GPIO
TLMM nem GPIO `st,leds` foi presumido.

`qcpmic8480.sys` mapeia LED lógico 1 para os canais físicos **1+4** nos
modelos PMIC 0x31/0x49/0x5d. A leitura dirigida no Yoga confirmou o modelo
**0x5d**, bloco flash em **0xee00**, revisão 1, tipo 0x18 e subtipo 7: o
bloco de quatro canais suportado por `leds-qcom-flash`. Antes dos testes,
0xee46 e 0xee4e estavam em zero (módulo e canais desligados). Os registros
foram lidos individualmente com `pread`, sem varrer o PMIC.

O safety timer Windows recebe 1270 ms e codifica `(timeout_ms - 10) / 10`
com bit 7 de enable; esse limite de emergência não define o duty cycle do
emissor. O driver vendor Qualcomm confirma código 0x13 = 200 ms e
`timeout_to_code(timeout) = DIV_ROUND_CLOSEST(timeout, 10) - 1`:
[fonte Qualcomm 4ch](https://android.googlesource.com/kernel/msm.git/+/9ff7a030ce757458f966dc3d5ae4f557077a122b/drivers/leds/leds-qti-flash.c).

`qcom-flash-cleanup.patch` corrige três problemas no driver Linux:

- timer de flash com um passo de 10 ms a mais: 10 ms deve produzir 0x80;
- acesso fora do array e liberação incompleta nos caminhos de erro/remove;
- destruição do mutex antes que o unregister gerenciado desligue os LEDs.

A compilação testada usa uma cópia privada, sem alterar a árvore compartilhada:

```sh
mkdir -p local/iso-build/extmod-yoga-flash
cp local/iso-build/kernel/drivers/leds/flash/leds-qcom-flash.c \
  local/iso-build/extmod-yoga-flash/
patch -d local/iso-build/extmod-yoga-flash -p4 \
  < install/camera/ir/qcom-flash-cleanup.patch
printf 'obj-m += leds-qcom-flash.o\n' > local/iso-build/extmod-yoga-flash/Kbuild
podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp \
  M=/work/extmod-yoga-flash ARCH=arm64 LLVM=1 -j4 modules
```

`yoga-camera-all-test.dts` reúne o DTB de teste RGB+IR e o fragmento do
iluminador. Manter `leds_qcom_flash` na blacklist; carregar manualmente o
módulo corrigido somente após a validação dos sensores.

`yoga-ir-illuminator-test.dtsi` habilita só 1+4, limita o flash a 100 mA
**totais**, com timeout máximo de 10 ms. O teste inicial de `pulse-test.py`
usa 50 mA totais, divididos em 25 mA por canal, durante um único pulso.
`default-state = "off"` não é interpretado por esse driver; o script escreve
OFF explicitamente e confirma os registros antes de qualquer disparo.

No Yoga, após carregar o módulo corrigido e o DTB de teste:

```sh
# Prepara e valida timer/corrente/modo/OFF; não emite pulso.
python3 pulse-test.py --led /sys/class/leds/ir:flash
# Uma única emissão, seguida de duas tentativas de OFF e leitura dos registros.
python3 pulse-test.py --led /sys/class/leds/ir:flash --fire
```

O script recusa outro DT, outro modelo PMIC, caps diferentes, trigger ativo,
fault prévio, timer diferente de 0x80, corrente ou modo divergentes. A saída
JSON registra baseline, configuração preparada, estado após o pulso e OFF.
Nunca escreve `brightness > 0`: torch desabilita o safety timer. O atributo
`flash_strobe` é estado em cache e não comprova estado elétrico; por isso
as leituras de 0xee46/0xee4e são obrigatórias. A emissão óptica foi confirmada na captura descrita abaixo; a sincronização
automática CCI e a largura elétrica/óptica medida ainda não foram validadas.

Validação offline: módulos VD55G0 e flash compilados; cinco
testes do fluxo do script passaram, incluindo timer errado, interrupção e
falha do primeiro OFF. Harness C com páginas de guarda reproduziu o acesso
fora do array original e passou com o loop corrigido. Harness do timer,
extraído da função compilada, passou para 0/10/20/1270/1280 ms, saturação,
limite do LED e falhas de escrita. Revisões independentes aprovaram o driver/DT IR, o patch de flash e o
script de pulso. Exit 0 do script comprova fluxo e OFF; o campo `faults`
precisa ser avaliado em cada ensaio e não comprova emissão óptica.

```sh
python3 -m unittest discover -s install/camera/ir -p test_pulse_test.py -v
```

Os binários Windows não são redistribuídos. Hashes dos arquivos analisados:

- `qccamflash8480.sys`: `83c490c4597f64cb595fe4d2ef64ee48accc5efcc4887ba09435c90cb16631b1`.
- `qcpmic8480.sys`: `f4c13385c1aa7316ce6ab6eb8fbb76749e03f5004fe8e48a6c8272f84d395e25`.

Os dumps privados e os pontos de análise estão em
`local/physical-2026-11-17/camera-workflow/ir/`. A corrente Windows de
700 mA permanece evidência da configuração original, sem autorização
implícita para uso contínuo.

## Resultado físico — 17/11/2026, 11:28 UTC

O parent executou um pulso de 50 mA totais/10 ms durante captura IR manual de
120 quadros. Os quadros 23/24 foram os dois mais claros e coincidiram com a
janela do comando. O pico teve +22,54% na média global e +66,34% no centro,
retornando ao basal no quadro 25. Exposição e ganhos permaneceram fixos.

`flash-timeout-exceeded` foi a única indicação após o pulso. O driver lê
esse evento no status físico, mas não limpa automaticamente os bits de
habilitação; o cleanup confirmou ee46=00 e ee4e=00. Isso comprova emissão e
OFF no ensaio limitado; não é uma medição elétrica da largura do pulso.

Dados privados e análise reproduzível: `local/physical-2026-11-17/
camera-workflow/ir/ir-pulse-validation.md`, `ir-pulse-stats.{json,csv}` e
`ir-pulse-response.{png,svg}`. A investigação posterior identificou duas rotas no driver Windows. O perfil
desta placa seleciona hardware strobe via GPIO0 do sensor; a rota alternativa
CCI usa pinId 0 / ncid 1 / callbackId 6. O 6 é callback, não uma saída GPIO.

## Sincronização: ensaio físico de um quadro

A extração adicional do Windows confirmou a configuração de hardware strobe via
GPIO0 do sensor. O ensaio V2 capturou um quadro 640×480 Y10P com 50 mA totais e
limite de 10 ms, `faults=0`, gates OFF finais e bit PMIC restaurado de 0 para 1.
A resposta óptica é compatível com iluminação por hardware. Detalhes, evidências
e patches estão em [SYNCHRONIZATION.md](SYNCHRONIZATION.md).

O protocolo usa uma amostra por boot. Não mede largura elétrica nem comprova
rearme contínuo. Os módulos diagnósticos e o DT com `st,leds` permanecem privados
de teste, sem instalação para aplicativos; o baseline normal continua separado.
