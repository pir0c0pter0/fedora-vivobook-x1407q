# Calibração de cor da câmera RGB — lead para desenvolvimento futuro

**Data:** 2026-08-24
**Status:** oportunidade identificada e caracterizada; **não implementada**
**Escopo:** OV02C10 (câmera RGB frontal), `libcamera` pipeline `simple`

---

## Resumo

A câmera RGB funciona (conquista #17), mas roda **sem nenhuma calibração de
cor**. O tuning oficial da Qualcomm para este sensor exato existe no dump dos
drivers Windows, não está comprimido e é auto-descritivo. Extrair dele uma
matriz de correção de cor (CCM) e o nível de preto melhoraria a imagem de forma
visível.

O que falta é decodificar o layout das seções de dados do formato "QTI
Chromatix". Os nomes dos módulos já são legíveis; os **valores** não foram
localizados.

---

## O problema

`/usr/share/libcamera/ipa/simple/ov02c10.yaml`, instalado por
`vivobook-camera.service` a partir de `modules/vivobook-cam-fix-2.0/ov02c10.yaml`,
é este arquivo inteiro:

```yaml
# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Adjust:
  - Agc:
...
```

É **idêntico ao `uncalibrated.yaml`** que o libcamera 0.7.1 instala como
fallback genérico, menos o bloco comentado de CCM. Ou seja: não há dado de
calibração nenhum específico do OV02C10. O próprio comentário do libcamera no
`uncalibrated.yaml` diz:

> Color correction matrices can be defined here. The CCM algorithm has a
> significant performance impact, and should only be enabled if tuned.

Nunca foi tunado. As cores saem do que o AWB estimar sobre o Bayer cru.

---

## A fonte: tuning Chromatix da Qualcomm

No dump `windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst` (fora do git —
ver `.gitignore`), pacote `qccamfrontsensor_extension8380`:

| Arquivo | Bytes | SHA-256 |
|---|---|---|
| `com.qti.tuned.ov02c10.bin` (`_S3`) | 2 967 297 | `8242dc91e7f848a3df5549113424956951261352dabddf9ffdbafaf070eb8f65` |
| `com.qti.tuned.ov02c10.bin` (`_X1`) | 1 557 934 | `0ebaa01ad1adb6d2cba79138b7bc9d82877d16fd55c268ce58b0716984bcdf98` |
| `com.qti.sensormodule.ov02c10.bin` | 111 486 | `c1295a4fa8bcdc50b7e600971329d1c86c675eaf04587048aeb04dbe07cc39d2` |

Extrair (o zstd padrão falha, precisa de janela grande):

```bash
tar -I 'zstd -d --long=31' -xf windows-drivers/X1407QA_DRV-full-2026-08-19.tar.zst \
    --wildcards '*qccamfrontsensor_extension8380*/com.qti.*ov02c10*'
```

Cópias idênticas aparecem em `Firmware-Catalog/linux-usable/`, que a pesquisa da
câmera IR já havia marcado como aproveitável (`firmware-catalog.json`,
`linux_usable: true`).

### O formato é navegável

```
00000000: 5154 4920 4368 726f 6d61 7469 7820 4865  QTI Chromatix He
00000010: 6164 6572 0000 0000 0000 0000 fd46 2d00  ader.........F,.
00000020: 0300 0000 0100 0000 5061 7261 6d65 7465  ........Paramete
00000030: 7220 5061 7273 6572 2056 332e 342e 3020  r Parser V3.4.0
00000040: 2832 3130 3633 3031 3031 3029 0000 0000  (2106301010)....
00000050: 0000 0000 0000 0000 636f 6d2e 7174 692e  ........com.qti.
```

- `@0x18` = `0x2d46fd` = 2 967 293 = tamanho do arquivo − 4
- Entropia **3,26 bits/byte** no tuned e **2,57** no sensormodule — não é
  comprimido nem cifrado (8,0 seria)

### Módulos presentes (64 no total)

Relevantes para nós:

| Módulo | O que é | Aproveitável no libcamera `simple`? |
|---|---|---|
| `mod_cc13` | **Color correction (CCM)** | **Sim** — algoritmo `Ccm` |
| `mod_bls12` | **Black level subtraction** | **Sim** — algoritmo `BlackLevel` |
| `mod_wb20` | White balance | Parcial — o `Awb` é automático |
| `mod_lsc35` / `36` / `41`, `mod_lscgolden36` / `41` | Lens shading | **Não** — sem algoritmo no IPA `simple` |
| `mod_gamma15` / `16`, `mod_gtm13`, `mod_bgtm10`, `mod_ltm16` | Gamma / tone map | **Não** |
| `mod_demosaic36`, `mod_asf34`, `mod_anr10`, `mod_tf21`, `mod_hnr10` | Demosaico / nitidez / ruído | **Não** |

Lista completa dos 64:

```
anr10 aonbls12 aondemosaic36 aongamma16 asf34 bgtm10 bincorr10 bls12 bltm10
blur10 bpcabf41 cac23 cc13 cs20 cv12 demosaic36 demuxblklevel14 depth10 dme30
dmm10 dpp10 dsx10 gamma15 gamma16 gic31 gra10 gtm13 gtmfd13 hdr10p10 hdr40
hdr50 hnr10 ica40 jbu10 lcac11 ldc11 lenr10 lsc35 lsc36 lsc41 lscgolden36
lscgolden41 ltm16 mf12 mrc10 nrm11 pdpc31 qll20 qpdpc10 remosaic10 sce11 sgm10
shdr10 swabf10 swasf10 tdl10 tf21 tintless23 tmc14 upscale20 uvg10 video12
vse10 wb20
```

---

## Onde a investigação parou

`mod_cc13` aparece em 6 offsets no arquivo `_S3`:
`0x1288`, `0x5070`, `0xa908`, `0x76068`, `0xc3ca8`, `0xcdde0`.

**Todos os 6 são entradas de tabela de símbolos, não os dados.** O registro tem
formato fixo:

```
000760 50: ................ ffff ffff 2e16 0000   ← sentinela + campo
000760 60: 1400 0000 fc22 0000 6d6f 645f 6363 3133 ← tipo, id, início do nome
000760 70: 5f74 7269 6767 6572 5f64 6174 6100 0000 ← "mod_cc13_trigger_data" + padding
```

Ou seja: `ffffffff | <u32> | <u32 tipo> | <u32 id> | <nome em campo fixo de 32 bytes>`.
Os valores dos parâmetros vivem em seções separadas, ainda não mapeadas.

### O que foi descartado com evidência

Duas varreduras do arquivo inteiro em passo de 4 bytes procurando 9 float32
consecutivos:

1. **Com normalização clássica** (cada linha da 3×3 somando 1,0 ± 0,02,
   diagonal positiva) → **0 candidatos**
2. **Com forma de CCM sem exigir soma 1,0** (diagonal positiva e dominante sobre
   as off-diagonais da própria linha, somas entre 0,5 e 2,0, descartando
   identidade) → **0 candidatos**

Conclusão: os coeficientes **não são float32**. Provavelmente ponto fixo
(Q-format inteiro), como o CamX usa nos registradores do IFE/BPS. Próximo passo
natural é varrer int16/int32 com fatores Q candidatos (Q7, Q8, Q10, Q12).

### O `sensormodule` pode ser o alvo mais fácil

`com.qti.sensormodule.ov02c10.bin` tem só 111 KB e um schema com nomes de campo
totalmente legíveis, incluindo coisas úteis muito além de cor:

```
sensorDriverData cameraModuleData EEPROMDriverData calibrationInfo
activeArrayCropInfo resolutionInfo resSettings initSettings regSetting
registerData registerSettingsGroupInfo exposureInfo integrationInfo delayInfo
frameLengthLines laneAssign i2cFrequencyMode sensorSlaveAddress
digitalGainRedAddr digitalGainGreenRedAddr digitalGainGreenBlueAddr
digitalGainBlueAddr digitalGlobalGainAddr realToRegGain regToRealGain
referenceMasterColorTemp WBOffset noiseCoefficientBayer QSCSettings SPCSettings
PDAFOffsetMaps temperatureReadInfo qValue
```

Note `qValue` — confirma que o formato carrega fatores Q, reforçando a hipótese
de ponto fixo. E `p@m24c64x_ov02c10` indica a EEPROM do módulo (M24C64), o que
sugere que parte da calibração é **por unidade**, gravada na EEPROM do
dispositivo — não no blob.

---

## Questão aberta: qual variante é a nossa

Existem duas tunings, com identificadores internos diferentes:

- `com.qti.tuned.ov02c10_S3` — 2 967 297 bytes
- `com.qti.tuned.ov02c10_X1` — 1 557 934 bytes

Ambas com os mesmos 64 módulos. Não foi determinado qual corresponde ao
X1407QA. Os arquivos `SCFG_FRONT_*.bin` / `CAMF_RES_*.bin` do mesmo pacote
(`MTP`, `QRD`, `D2L_QRD`, `Pw`) são configs por variante de placa e podem conter
a chave dessa escolha. **Aplicar a tuning errada é pior que não aplicar
nenhuma.**

---

## O teto realista

O IPA `simple` do libcamera 0.7.1 expõe apenas `BlackLevel`, `Awb`, `Adjust`,
`Agc` e `Ccm`. Mesmo decodificando o blob inteiro, **só CCM e black level
entram**. Lens shading, gamma, tone map e redução de ruído — que é onde está a
maior parte dos 64 módulos — não têm consumidor.

Ganho esperado: fidelidade de cor e ponto preto corretos. **Não** é uma
reescrita do pipeline de imagem.

---

## Caminho alternativo, sem engenharia reversa

O libcamera tem infraestrutura própria de tuning (`utils/tuning`, `libtuning`).
Uma CCM pode ser derivada empiricamente:

1. Fotografar um alvo de cor conhecido (ColorChecker) em iluminante controlado
2. Rodar o gerador de tuning do libcamera sobre os RAWs
3. Emitir o bloco `Ccm:` no `ov02c10.yaml`

Custo: precisa de um alvo físico e de fotos — trabalho humano, não de código.
Vantagem: resultado válido e verificável sem depender de decodificar formato
proprietário, e é o caminho que o upstream aceitaria numa contribuição.

**Recomendação:** se o objetivo é melhorar a imagem, o caminho empírico é mais
curto e mais seguro. A engenharia reversa do Chromatix só compensa se o alvo for
extrair também dados que o empírico não dá (ex.: `initSettings` do sensor, mapas
PDAF, coeficientes de ruído).

---

## Apêndice — resto da mineração do dump (2026-08-24)

Varredura dos ~130 pacotes atrás de melhorias para o que **já funciona**:

| Achado | Veredito |
|---|---|
| **ADSP `ADSP.HT.5.9-00831-HAMOA-1`** disponível no dump (pacote `a71bd08806a83345`, 22 075 832 B) contra **`-00810`** instalado | Mais novo e assinado pela própria ASUS, então — diferente do CDSP Hamoa — deve carregar. **Mas não há bug conhecido que ele conserte**; ADSP é áudio + bateria, ambos funcionando. Trocar sem alvo é risco sem retorno. Testável de forma reversível pelo sysfs do `remoteproc`. |
| `qcvss8380.mbn` `rel0092` disponível vs `rel0090` instalado | **Irrelevante** — o VSS não é carregado no Linux (`dmesg` sem qualquer menção a vss/venus/iris). |
| `qcdxkmsuc8380.mbn` / `qcdxkmsucpurwa.mbn` | Byte-idênticos em todas as versões do pacote GPU. Nada a ganhar. |
| Pacote CDSP alternativo `qcnspmcdm_ext_cdsp8380...897df898806cc42d` | Build diferente, não autorizado pelo nosso firmware (shell 1/4 segmentos). Já estava correto usarmos o `1b18f9dc06e2d351`. Ver `hexagon-dsp/README.md`. |
| `qcav1e8380.mbn` (encoder AV1), `qcdxkmbase8380*.bin` | Blobs do KMD Windows / encoder sem driver Linux correspondente. Fora de alcance. |

---

## Referências

- `hexagon-dsp/README.md` — regra do whitelist de hash (mesmo dump, outro caso)
- `docs/research/CAMERA_STATUS.md` — estado geral das câmeras
- `docs/research/2026-04-11-ir-camera-discovery.md` — origem do `firmware-catalog.json`
- README seção 17 — o fix da câmera RGB em produção
