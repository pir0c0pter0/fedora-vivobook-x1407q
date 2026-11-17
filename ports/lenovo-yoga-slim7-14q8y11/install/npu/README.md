# NPU / CDSP V81 — Yoga 14Q8Y11

**Inferencia comprovada em 17/11/2026; reabertura ainda bloqueada.**
QAIRT 2.48.40/QNN plugin 2.4.0 executou Abs no HTP V81, com CPU fallback
desabilitado. Tres ensaios apos boots distintos passaram em 100 inferencias
por processo, variando entradas e conferindo cada resultado. Cada perfil
tem 100 eventos Node em QNNExecutionProvider e nenhum Node na CPU.
Isso prova calculo na NPU, mas nao valida modelos grandes nem desempenho.

Foi necessario reportar SoC 662/Glymur somente ao processo QNN, reutilizando
o [shim existente](../../../../modules/qnn-soc-id-fix/qnn_soc_id_fix.c); sysfs e kernel continuam com 729/Kalambo.
Esse desvio e experimental, nao suporte nativo nem calibracao do Kalambo.
Com 729 nativo, QAIRT 2.52 continua rejeitando UNKNOWN_SDM.

Capacidades anunciadas, todas rc=0: DOMAIN_SUPPORT 1, UNSIGNED_PD_SUPPORT 1,
ARCH_VER=0x8081 (V81), HMX_DEPTH=0, HMX_SPATIAL=0. Os dois zeros nao provam
ausencia fisica de HMX. A falta de remote_system_request no FastRPC nao
foi comprovada como causa.

O DT/args do `try` foram restaurados; `current` continua com audio/GPU e
CDSP desabilitado. Nao ha servico NPU instalado nem tentativa pendente.
Runtime em /opt e firmware em staging ficam inativos para investigacao
posterior. Proximo requisito: corrigir o ciclo de criacao/destruicao do
user PD, depois validar reaberturas e uso sem root antes de promover.
Evidencias novas em `local/physical-2026-11-17/npu-inference/`;
o diagnostico nativo inicial permanece em `audio-gpu-npu/`.
Os 26 checks anteriores do startup permanecem aplicaveis; startup nao mudou.
Rodados novamente ao encerrar: 26/26. Boot current restaurado em 34,441 s,
servicos da base ativos e hashes current/good preservados; registro em
`npu-inference/current-restored.txt`.

## Bloqueio reproduzivel

A primeira abertura funciona; depois de fechar o processo, nova criacao
retorna `0x8000054f` (`AEE_EQURTBADASID`). `fastrpc-open-close.c` reproduz
isso abrindo o `libsysmonquery_skel.so` original do Windows, **sem QNN nem
shim de SoC**. Logo a rejeicao de 729 pelo QNN e um problema separado.
A causa interna do erro QuRT ainda nao foi determinada.

| Comparacao | Resultado |
|---|---|
| QNN 2.4 / QAIRT 2.48.40 + override 662 | Primeira execucao passa; reabertura falha |
| QNN 2.7 / QAIRT 2.51 e QNN 2.8 / QAIRT 2.52 + override 662 | Falha de polling/mapeamento FD 56/272 bytes, graph handle 6001 |
| FastRPC 1.0.7 versus 1.0.9 | Mesma falha de reabertura |
| Driver FastRPC do kernel 7.2 versus 7.4-rc1 | Mesma falha; modulo 7.2 apenas diagnostico |
| Listener root CDSP, bibliotecas pareadas, PID/IDs distintos, outro context bank | Nao corrigiram a reabertura |
| Retirar dma-coherent dos 11 context banks CDSP | Rejeitado: avisos de memoria/vmalloc e falha de fork; DT original restaurado |

Instrumentacao do driver confirmou INIT_RELEASE rc=0, liberacao de
fastrpc_user, lista de invokes pendentes vazia e CMA livre inalterada.
No ensaio QAIRT 2.51, 50 respostas v2 tinham flag NORMAL_RESPONSE; a
notificacao de saida do PD chegou antes de liberar o cliente. Nao houve
evidencia de respostas antecipadas nesse ensaio. Nenhuma alteracao de
kernel experimental foi instalada em updates ou no initramfs.

Um teste anterior de reabertura direta perdeu SSH e exigiu reinicializacao;
sem panic preservado em pstore. Nao executar loops ilimitados nem retirar
dma-coherent. A validacao de uma sessao nao autoriza ativacao automatica.

Reprodutor nativo, somente depois de `yoga-npu-up` em boot `try` novo:

```sh
gcc -O2 -Wall -Wextra -Werror -I/caminho/fastrpc/inc fastrpc-open-close.c \
  -L/opt/yoga-npu/lib -lcdsprpc -o fastrpc-open-close
for attempt in 1 2; do
  LD_LIBRARY_PATH=/opt/yoga-npu/lib \
  DSP_LIBRARY_PATH=/opt/yoga-npu/share/qcom/kalambo/LENOVO/83QR/dsp/cdsp \
  timeout -k 5 20 ./fastrpc-open-close || break
done
```

Primeiro processo: unsigned/open/close=0. Segundo: open=0x8000054f.
Logs: `native-open-close-{1,2}.log`, `native-open-close-journal.txt`,
`qnn24-lifetime-journal.txt`, `responses-dmesg.txt`,
`noncoherent-dmesg.txt`. Perfis de 100 inferencias aprovados:
`yoga-npu-profile_2026-11-17_{13-51-32_608,13-54-56_981,13-58-45_185}.json`.

## Firmware e DT

Usa o pacote Windows ativo `qcnspmcdm8480.inf_arm64_4feba84cfc7ee278`,
versao 30.0.220.11010. Os arquivos permanecem privados, fora do Git.

| Arquivo | SHA256 |
|---|---|
| qccdsp8480.mbn | acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794 |
| cdsp_dtbs.elf | 9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d |
| CDSP/fastrpc_shell_3 | 61301ad82965b291d868989bf224ebe464501d38ea786c8f4ef3231eea6f22d5 |
| CDSP/fastrpc_shell_unsigned_3 | b65b25e7c399f5272920e5d2b9f3197164b9eb1818194cb44339bc89f603b1f8 |

Firmware CDSP.HT.3.3-00304-GLYMUR-1, ELF Hexagon V81. Segmentos cabem nas
reservas CDSP 64 MiB e DT 512 KiB existentes; os dois shells pertencem ao MBN.
`yoga-npu-test.dts` inclui a base de audio validada e muda somente status
do CDSP e os dois nomes de firmware. DTB revisado:
`440278cf7c1dfff2c0bc4f483b2241aa3c0f41d6b5ed4732292d9ad04aff0b7c`.
Nenhum GPIO, regulador, carveout ou mapa SID foi alterado.

O par MBN/DTB fica em `/var/lib/yoga-npu-fw/qcom/glymur/LENOVO/83QR/`,
**separado do staging ADSP**, impedindo autoboot durante a subida do audio.
`yoga-npu-up` exige placa/SoC corretos, `yoga.npu=1`, GPU ativa, CDSP offline,
firmwares exatos, SoCCP attached e ADSP running. Desabilita recovery do CDSP
antes do start e restaura firmware_class.path inclusive em erro.
Nunca parar SoCCP nem descarregar os drivers para repetir: reiniciar.

## Runtime local

Fontes oficiais e versoes usadas:

- [FastRPC v1.0.9](https://github.com/qualcomm/fastrpc/releases/tag/v1.0.9),
  commit 89508eaeed55833bcb381fafa91e2224201f4ad7.
- [ORT 1.29.0 AArch64](https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0),
  tgz SHA256 `e1799098ebc054b370f6176a450f158720f297818c613e5dc99b92e2ec82346f`.
- [QNN plugin 2.8.0 / QAIRT 2.52](https://github.com/onnxruntime/onnxruntime-qnn/releases/tag/v2.8.0),
  Linux AArch64 tgz SHA256 `a4b695225cecf16402b279ee4a625747ef7a96971c7f0222c5dff2a48832868d`.
- [QNN plugin 2.4.0 / QAIRT 2.48.40](https://github.com/onnxruntime/onnxruntime-qnn/releases/tag/v2.4.0),
  pacote que passou, tgz SHA256 `1116ea07caee562e25ad581b7571997d42300bdc92371b10c914acc9f5ff2cea`.
- [QNN plugin 2.7.0 / QAIRT 2.51](https://github.com/onnxruntime/onnxruntime-qnn/releases/tag/v2.7.0),
  tgz SHA256 `a552228bed212fb072c301c968b1ba35c6ee9184d10c90e52eee4f2de4a54ae4`.

Build no PC em container Fedora 45 AArch64/QEMU. Dependencias:
gcc, gcc-c++, make, autoconf, automake, libtool, pkgconf-pkg-config,
libyaml-devel e libbsd-devel. FastRPC:

```sh
./gitcompile --prefix=/opt/yoga-npu --libdir=/opt/yoga-npu/lib \
  --with-config-base-dir=/opt/yoga-npu/share/qcom --enable-stricter
make DESTDIR=/work/stage install
```

No Yoga foi instalado `libatomic` (16.2.1-3.fc45), exigido pelo stub V81.
DNF invalidou uma transacao offline pendente do dnf5daemon-server durante
essa instalacao; a fila de atualizacoes nao foi reconstruida nesta rodada.

O pacote local inicial `local/npu-build/yoga-npu-runtime-final.tar.gz` tem SHA256
`b9ea6cbdb38ca5e2f1270080f03b298a5a452cef6e418e6ec4009b864239db02`;
inclui o probe verbose, healthcheck e licencas. Contem shells privados:
nao publicar esse arquivo.

Selecionar somente libcdsprpc.so e seus links para o prefixo privado
`/opt/yoga-npu/lib`; manter licencas. Nao instalar as unidades/regras
genericas do upstream, que tambem iniciariam servicos ADSP.
ORT fornece headers e libonnxruntime.so da mesma versao. QNN fornece
libonnxruntime_providers_qnn, libQnnHtp, libQnnHtpPrepare, libQnnSystem,
libQnnHtpV81Stub em lib/ e libQnnHtpV81Skel.so em dsp/.

Instalar `yoga-kalambo.yaml` em `/opt/yoga-npu/share/qcom/conf.d/` e o
diretorio CDSP pareado em `share/qcom/kalambo/LENOVO/83QR/dsp/cdsp/`.
Os 17 arquivos passaram em hexagon-authcheck contra o MBN original; incluir
libc++.so.1/libc++abi.so.1, sem misturar pacotes Windows. O YAML usa
o model literal do DT; v81 e fallback de arquitetura, sem trocar SoC.
Busca inicial do shell depende do YAML, nao da variavel DSP_LIBRARY_PATH.

Compilar `qnn-abs-test.cc` com g++ C++17, -O2 -Wall -Wextra -Werror,
include/lib do ORT 1.29 e -lonnxruntime; rpath `/opt/yoga-npu/lib`.
Gerar `abs.onnx` com `python3 make-abs-model.py abs.onnx`.
O modelo IR8/opset13 possui uma operacao Abs e entrada float32[1,4].
Checker ONNX completo, formas e avaliadores independentes passaram.
SHA256: `f507207a308731a4d9e7ab878b13733437c4d186df8941984bd67baad001d332`.

## Teste e criterio de aprovacao

O prefixo /opt conserva QNN 2.8; o comando nativo abaixo continua falhando
na identificacao de 729. Depois do boot unico `try` e de `yoga-npu-up`,
executar em diretorio privado para guardar o perfil, inicialmente como root:

```sh
LD_LIBRARY_PATH=/opt/yoga-npu/lib \
DSP_LIBRARY_PATH='/opt/yoga-npu/dsp;/opt/yoga-npu/share/qcom/kalambo/LENOVO/83QR/dsp/cdsp' \
timeout -k 5 60 /opt/yoga-npu/bin/qnn-abs-test /opt/yoga-npu/share/abs.onnx
```

O teste seleciona a NPU QNN, backend HTP e desabilita CPU fallback.
A fonte atual executa 100 inferencias com entradas distintas, exige forma
[1,4], valores finitos e erro absoluto ate 0,005 em cada resultado.
Conferir tambem os 100 eventos Node em QNNExecutionProvider, sem Node CPU,
ausencia de SSR/faults e preservacao do audio, GPU, bateria e SoCCP.

Nos ensaios aprovados, libs e skel 2.4 foram montados sobre /opt/yoga-npu
somente dentro de `unshare --mount --propagation private`, a partir de
`/root/npu-20261117/identify/qnn24/{lib,dsp}`. O processo recebeu
`QNN_SOC_ID_OVERRIDE=662` e `LD_PRELOAD=.../identify/qnn_soc_id_fix.so`.
O binario novo e `.../identify/qnn-abs-repeat-test`, SHA256
`a792a26b9a4508b55db3897a6497a6b2d0e75ffc3888242f34277a97e245e5a4`.
O binario inicial em /opt ainda faz uma unica inferencia.

`fastrpc-healthcheck` e apenas inventario, sempre retorna zero e procura
firmware em /lib/firmware; pode declarar Offline com staging privado.
`fastrpc_test` distribui apenas V68/V75 nesta versao: nao serve como
ensaio V81. Backup dos slots no Yoga: `/root/npu-20261117/`; `current`
e `good` foram preservados; nao promover antes de passar reabertura,
uso sem root e novo boot, alem de inferencia real.
