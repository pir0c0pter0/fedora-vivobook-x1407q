# NPU / CDSP V81 — Yoga 14Q8Y11

**Inferencia bloqueada em 17/11/2026 pelo runtime QNN testado.** CDSP
iniciou em391ms e consultas FastRPC passaram. QNN/QAIRT2.52 leu o SoC
nativo729 (Kalambo), mas retornou UNKNOWN_SDM/No Snapdragon SOC detected,
falhando na inicializacao do backend antes de enviar calculo ao DSP.
O perfil nao tem eventos Node. O processo de diagnostico com log verbose
tambem falhou com SIGSEGV durante o tratamento do erro; kernel/DSPs
permaneceram ativos. Nenhuma inferencia, user PD ou calibracao NPU aprovada.

Capacidades anunciadas, todas rc0: DOMAIN_SUPPORT1, UNSIGNED_PD_SUPPORT1,
ARCH_VER0x8081 (V81), HMX_DEPTH0, HMX_SPATIAL0. Os dois zeros nao provam
ausencia fisica de HMX. Nao foi alterado soc_id nem usado soc_model de
outro chip. A falta de remote_system_request no FastRPC nao foi comprovada
como causa: a evidencia direta e a rejeicao da plataforma nativa pelo QNN.

O DT/args do `try` foram restaurados; `current` continua com audio/GPU e
CDSP desabilitado. Nao ha servico NPU instalado nem tentativa pendente.
Runtime em /opt e firmware em staging ficam inativos para investigacao
posterior. Proximo requisito: runtime com suporte nativo ao Kalambo729,
seguido de prova de user PD e inferencia QNN sem fallback CPU.
Evidencias privadas em `local/physical-2026-11-17/audio-gpu-npu/`:
`npu-try-state.txt`, `npu-capabilities.txt`, `qnn-verbose.log`, `qnn.strace`.
26 checks offline e revisoes separadas de DT/startup/modelo passaram.

## Firmware e DT

Usa o pacote Windows ativo `qcnspmcdm8480.inf_arm64_4feba84cfc7ee278`,
versao30.0.220.11010. Os arquivos permanecem privados, fora do Git.

| Arquivo | SHA256 |
|---|---|
| qccdsp8480.mbn | acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794 |
| cdsp_dtbs.elf | 9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d |
| CDSP/fastrpc_shell_3 | 61301ad82965b291d868989bf224ebe464501d38ea786c8f4ef3231eea6f22d5 |
| CDSP/fastrpc_shell_unsigned_3 | b65b25e7c399f5272920e5d2b9f3197164b9eb1818194cb44339bc89f603b1f8 |

Firmware CDSP.HT.3.3-00304-GLYMUR-1, ELF HexagonV81. Segmentos cabem nas
reservas CDSP64MiB e DT512KiB existentes; os dois shells pertencem ao MBN.
`yoga-npu-test.dts` inclui a base de audio validada e muda somente status
do CDSP e os dois nomes de firmware. DTB revisado:
`440278cf7c1dfff2c0bc4f483b2241aa3c0f41d6b5ed4732292d9ad04aff0b7c`.
Nenhum GPIO, regulador, carveout ou mapa SID foi alterado.

O par MBN/DTB fica em `/var/lib/yoga-npu-fw/qcom/glymur/LENOVO/83QR/`,
**separado do staging ADSP**, impedindo autoboot durante a subida do audio.
`yoga-npu-up` exige placa/SoC corretos, `yoga.npu=1`, GPU ativa, CDSPoffline,
firmwares exatos, SoCCPattached e ADSPrunning. Desabilita recovery do CDSP
antes do start e restaura firmware_class.path inclusive em erro.
Nunca parar SoCCP nem descarregar os drivers para repetir: reiniciar.

## Runtime local

Fontes oficiais e versoes usadas:

- [FastRPC v1.0.9](https://github.com/qualcomm/fastrpc/releases/tag/v1.0.9),
  commit89508eaeed55833bcb381fafa91e2224201f4ad7.
- [ORT1.29.0 AArch64](https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0),
  tgz SHA256 `e1799098ebc054b370f6176a450f158720f297818c613e5dc99b92e2ec82346f`.
- [QNN plugin2.8.0 / QAIRT2.52](https://github.com/onnxruntime/onnxruntime-qnn/releases/tag/v2.8.0),
  Linux AArch64 tgz SHA256 `a4b695225cecf16402b279ee4a625747ef7a96971c7f0222c5dff2a48832868d`.

Build no PC em container Fedora45 AArch64/QEMU. Dependencias:
gcc, gcc-c++, make, autoconf, automake, libtool, pkgconf-pkg-config,
libyaml-devel e libbsd-devel. FastRPC:

```sh
./gitcompile --prefix=/opt/yoga-npu --libdir=/opt/yoga-npu/lib \
  --with-config-base-dir=/opt/yoga-npu/share/qcom --enable-stricter
make DESTDIR=/work/stage install
```

O pacote local final `local/npu-build/yoga-npu-runtime-final.tar.gz` tem SHA256
`b9ea6cbdb38ca5e2f1270080f03b298a5a452cef6e418e6ec4009b864239db02`;
inclui o probe verbose, healthcheck e licencas. Contem shells privados:
nao publicar esse arquivo.

Selecionar somente libcdsprpc.so e seus links para o prefixo privado
`/opt/yoga-npu/lib`; manter licencas. Nao instalar as unidades/regras
genericas do upstream, que tambem iniciariam servicos ADSP.
ORT fornece headers e libonnxruntime.so da mesma versao. QNN fornece
libonnxruntime_providers_qnn, libQnnHtp, libQnnHtpPrepare, libQnnSystem,
libQnnHtpV81Stub em lib/ e libQnnHtpV81Skel.so em dsp/.

Instalar `yoga-kalambo.yaml` em `/opt/yoga-npu/share/qcom/conf.d/` e os
dois shells em `share/qcom/kalambo/LENOVO/83QR/dsp/cdsp/`. O YAML usa
o model literal do DT; v81 e fallback de arquitetura, sem trocar SoC.
Busca inicial do shell depende do YAML, nao da variavel DSP_LIBRARY_PATH.

Compilar `qnn-abs-test.cc` com g++ C++17, -O2 -Wall -Wextra -Werror,
include/lib do ORT1.29 e -lonnxruntime; rpath `/opt/yoga-npu/lib`.
Gerar `abs.onnx` com `python3 make-abs-model.py abs.onnx`.
O modelo IR8/opset13 possui uma operacao Abs e entrada float32[1,4].
Checker ONNX completo, formas e avaliadores independentes passaram.
SHA256: `f507207a308731a4d9e7ab878b13733437c4d186df8941984bd67baad001d332`.

## Teste e criterio de aprovacao

Depois do boot unico `try` e de `yoga-npu-up`, executar em diretorio
privado para guardar o perfil, inicialmente como root:

```sh
LD_LIBRARY_PATH=/opt/yoga-npu/lib \
DSP_LIBRARY_PATH='/opt/yoga-npu/dsp;/opt/yoga-npu/share/qcom/kalambo/LENOVO/83QR/dsp/cdsp' \
timeout -k 5 60 /opt/yoga-npu/bin/qnn-abs-test /opt/yoga-npu/share/abs.onnx
```

O teste seleciona a NPU QNN, backend HTP e desabilita CPU fallback.
Nao passa soc_model nem substitui soc_id. Exige saida [1,2,3.5,4.25],
finita e dentro de 0,005. Conferir tambem JSON do perfil: evento Node
executado em QNNExecutionProvider e nenhum evento Node na CPU; logs
devem confirmar V81/plataforma nativa. Conferir ausencia de SSR/faults e
preservacao do audio, GPU, bateria e SoCCP.

`fastrpc-healthcheck` e apenas inventario, sempre retorna zero e procura
firmware em /lib/firmware; pode declarar Offline com staging privado.
`fastrpc_test` distribui apenas V68/V75 nesta versao: nao serve como
ensaio V81. Backup dos slots no Yoga: `/root/npu-20261117/`; `current`
e `good` foram preservados; nao promover antes de passar inferencia real.
