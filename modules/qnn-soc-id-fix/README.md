# qnn-soc-id-fix — SoC ID que o QNN reconhece

## Problema

`onnxruntime-qnn` registra a NPU, mas toda sessao HTP com
`session.disable_cpu_ep_fallback=1` falha antes de tocar o DSP:

```
FAIL : This session contains graph nodes that are assigned to the default CPU EP,
but fallback to CPU EP has been explicitly disabled by the user.
```

## Causa raiz

`libQnnHtp.so` le `/sys/devices/soc0/soc_id` (via `std::ifstream`), obtem `635`
(X1P42100, die "Purwa"), nao acha esse ID na tabela interna de SoCs e aborta em
`logCreate` — comprovado por `strace`. Nao existe env var de override na lib, e o
caminho alternativo `/sys/devices/system/soc/soc0/id` nao existe nesta maquina.
`555` (X1E80100 / SC8380XP) e conhecido pelo QNN e usa o mesmo Hexagon v73.

## Solucao

Shim `LD_PRELOAD` (mesmo padrao de `vk_pool_fix.so`) que intercepta
`open/open64/openat/openat64/fopen/fopen64` do caminho exato do `soc_id` e
devolve um `memfd` com `555\n`. Qualquer outro caminho passa direto. Nada em
disco, nada persistente: `tools/npu-run` aplica o preload so no processo que usa
a NPU — o CLAUDE.md proibe spoof global de SoC.

```bash
make && sudo make install     # -> /usr/local/lib64/qnn_soc_id_fix.so
make check                    # self-check sem depender do sysfs real
tools/npu-run python meu_script.py
```

## Propriedades

| Item | Valor |
|------|-------|
| Lib | `/usr/local/lib64/qnn_soc_id_fix.so` |
| Wrapper | `tools/npu-run` (escopa o `LD_PRELOAD`) |
| Caminho interceptado | `/sys/devices/soc0/soc_id` (env `QNN_SOC_ID_PATH`) |
| Valor reportado | `555` (env `QNN_SOC_ID_OVERRIDE`) |
| Backing store | `memfd_create` — nada em disco, morre com o processo |
| Funcoes hookadas | `open`, `open64`, `openat`, `openat64`, `fopen`, `fopen64` |
| Escopo | processo + filhos; sysfs real intacto (`cat` avulso ainda le `635`) |
| Validado | `Abs` no HTP sem fallback de CPU, kernel 7.2.0-x1407qa |
