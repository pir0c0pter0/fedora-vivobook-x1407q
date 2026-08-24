# Binários Hexagon do CDSP (NPU)

Estes arquivos rodam **dentro do Hexagon DSP**, não no ARM. São o shell de
processo (`fastrpc_shell_*`) e as bibliotecas de runtime que o FastRPC carrega
no CDSP para que a NPU execute inferência.

Destino no sistema instalado:

```
hexagon-dsp/cdsp/*  →  /usr/share/qcom/x1p42100/Qualcomm/Purwa-IoT-EVK/dsp/cdsp/
```

Instalados por `tools/setup-npu-runtime.sh`. **Não** vão para `/usr/lib/firmware`
— por isso ficam fora de `firmware/`, que `setup-vivobook.sh` copia inteiro para
lá.

## ⚠️ Regra do whitelist de hash — leia antes de trocar qualquer arquivo

O firmware CDSP assinado (`qccdsp8380.mbn`) carrega embutido o **SHA-256 de cada
segmento ELF** de todo binário Hexagon que ele aceita carregar. Um shell de build
diferente é rejeitado, mesmo sendo do mesmo SoC e da mesma família:

```
fastrpc_apps_user.c: Error 0x8000054f: remote_init failed for domain 3
kernel: qcom,fastrpc ...: No context ID matches response
```

Os arquivos aqui são o par exato do firmware CDSP deste modelo:

| | |
|---|---|
| **Firmware pareado** | `/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn` |
| **Versão** | `CDSP.HT.2.9.c1-00046-HAMOA-1` (`hamoa.cdsp.prodQ`) |
| **SHA-256 do firmware** | `3df4de099b23df0969c172fa2660e02c1ba4e1b5c280eb0198a89194f400d875` |
| **Validação** | 17/17 binários com 100% dos segmentos autorizados |

`tools/setup-npu-runtime.sh` revalida esse pareamento na instalação e **recusa**
instalar se o firmware da máquina não autorizar estes binários.

### Por que não usar os binários públicos

Os builds publicados em [linux-msm/hexagon-dsp-binaries](https://github.com/linux-msm/hexagon-dsp-binaries)
para o `x1e80100`/Hamoa (que o `config.txt` de lá mapeia para Purwa) **não
casam** com o nosso firmware — `fastrpc_shell_unsigned_3` autoriza apenas 1 de 4
segmentos em ambos:

| Build testado | Resultado contra `c1-00046` |
|---|---|
| `CDSP.HT.2.9.c1-00069-HAMOA-1` | ❌ shell 1/4 segmentos |
| `CDSP.HT.2.9.c1-00082-HAMOA-1` | ❌ shell 1/4 segmentos |

Trocar o firmware pelo par público também **não** funciona e já foi testado: o
`x1e80100/cdsp.mbn` (c1-00069) é rejeitado pelo secure boot porque não é assinado
para os fuses do Purwa —

```
qcom_q6v5_pas 32300000.remoteproc: error -22 initializing firmware ...
remoteproc remoteproc1: Boot failed: -22
```

Não repita esse teste. O único par válido é o desta pasta.

## Origem

Extraídos do dump do DriverStore do Windows de fábrica,
`windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst` (fora do git — ver `.gitignore`),
pacote:

`Drivers-Exportados/qcnspmcdm_ext_cdsp8380.inf_arm64_1b18f9dc06e2d351/CDSP/`

> O dump contém **duas** versões desse pacote. A outra
> (`...inf_arm64_897df898806cc42d`) é de outro build e falha na validação.
> Sempre escolher por hash de segmento, nunca pelo nome do diretório.

Para reextrair (o zstd padrão falha, precisa de janela grande):

```bash
tar -I 'zstd -d --long=31' -xf windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst \
    --wildcards '*qcnspmcdm_ext_cdsp8380*/CDSP/*'
```

## SHA-256

| Arquivo | SHA-256 |
|---|---|
| `fastrpc_shell_3` | `a9411d2ff447e285197be2385c89e12123789834a0d9c8974b6e55a3d9cf79dc` |
| `fastrpc_shell_unsigned_3` | `5e15232f86a258e720e34fefb236b25dbd5abedd2300d561401950bfc9595e45` |
| `libc++.so.1` | `153ad58db0a416802bd541be021e7f7a91472b626814cae62e8ced85838e2dc9` |
| `libc++abi.so.1` | `0419222c0b94ab6c031de49fb1d6a8177e7d698ca877963fc18370de2699e89a` |
| `libsysmon_skel.so` | `7edc8c5f5b741bbde94d5b2f8da2fd968824aa3a5145bc4f810420054ef08eb4` |
| `libsysmondomain_skel.so` | `edb1596bd9316416267c651cc6b656e8c4a8df137d2007464299630bce2c0022` |
| `libsysmonquery_skel.so` | `bab9aa2b097ff4f4457a5d504a4bf3dc5236ae61f932259238269344849ee8c4` |
| `libsysmonhvxthrottle_skel.so` | `fd9d499f63f4dbcd5be328ca5eb8a271e29b2354a56a681f6b6ca10d3fa4af20` |
| `libstabilitydomain_skel.so` | `38bd9d1096528291b377b8123f8f9c7d652db39967334c2b1456e116ed9fc168` |
| `libbenchmark_skel.so` | `8a836766fc614834ece9f8b3e48980c5c2f31be4df0db7157ae09916ab84f273` |
| `libloadalgo_skel.so` | `6bafae11c65d5ff31553c2803df2a05e5c337d4e61180f975d23857e869a0e97` |
| `libcrm_test_skel.so` | `22d78ca0aa0aa7726ef7bcabf2335edc47e76406fd6c3a64fea4d6ddeb07ac93` |
| `libQ6MSFR_manager_skel.so` | `eee72823efd1a2a64252a8f3ac38af374905777d2dbe02ae7bfc567c7f4680bb` |
| `libQ6MSFR_manager_skel_intermediate.so` | `05945b571cd3339a22835b72caae701672d049fa9e0a8a012920687179db4d66` |
| `example_image.so` | `14b0b4b742ad8835f222cb9c8aa76c0a04092fdab57d8d95ad87bbf5220c3760` |
| `example_image_runner.so` | `7b3956cab71c2329ea27b2b91ad1af8370dae1238c14b4808d67b907d383497e` |
| `version.so` | `ec4db497fa11365373d634a46de3cabdc2e6997f0ed85569728f00da5d69f03e` |
| `map_SHARED_LIBS_hamoa.cdsp.prodQ.txt` | `fcdd83c346956001ddecc7b98a622ff66daf43f3b1c00d5636e1b25cd221de6d` |

## Licença

Firmware proprietário Qualcomm/ASUS. **Não** coberto pela licença MIT deste
repositório. A inclusão aqui não implica código-fonte nem permissão de
relicenciamento.
