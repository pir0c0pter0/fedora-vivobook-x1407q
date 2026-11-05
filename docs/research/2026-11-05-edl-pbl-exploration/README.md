# Exploração do PBL a016 (Sahara v3) — ASUS X1407QA — 05/11/2026

Exploração ao vivo da superfície completa do Primary Boot Loader do notebook,
via USB EDL (05c6:9008), com as ferramentas locais em
`diagnostico-x1407qa/ferramentas/`. Nenhuma imagem de loader foi enviada e
nenhuma escrita de firmware ocorreu.

## Identidade (reconfirmada nesta sessão)

```text
SoC a016 | MSM 002ad0e1 | OEM 0029 | MODEL 0001 | ROOT_HASH_ALGO 3 (SHA-384)
Serial 0x3cecd4ee | PK hash fd5f133f0db1b899...70f59436a9dd53f8004c37e3340e1f7
Sahara version 3, cmd_packet_length 1024, HELLO mode 0
```

## Mapa completo dos client commands (EXECUTE_REQ 0x0D)

| cmd | função | resultado |
|---|---|---|
| 0x00 | NOP | OK |
| 0x01 | SERIAL_NUM_READ | OK (8B: `eed4ec3c60040000`) |
| 0x02 | MSM_HW_ID_READ | 0x1f não suportado |
| 0x03 | OEM_PK_HASH_READ | OK (48B SHA-384) |
| 0x04 | SWITCH_TO_DMSS_DLOAD | 0x1f não suportado |
| 0x05 | SWITCH_TO_STREAM_DLOAD | 0x1f não suportado |
| 0x06 | READ_DEBUG_DATA | OK (11.808B em 3 chunks) |
| 0x07 | GET_SOFTWARE_VERSION_SBL | 0x1f não suportado |
| 0x08 | GET_COMMAND_ID_LIST | 0x1f não suportado |
| 0x09 | GET_TRAINING_DATA | 0x1f não suportado |
| 0x0A | READ_CHIP_ID_V3 | OK (80B) |
| 0x0B–0x10 | (fora da lista padrão) | 0x1f todos testados |
| 0x11–0x3F | (não varridos até o fim — orçamento de resets) | padrão diz 0x1f |

Conclusão: o PBL implementa somente o conjunto mínimo padrão Qualcomm
{0x00, 0x01, 0x03, 0x06, 0x0A}. Não há comando ASUS oculto no intervalo
explorado e os dois comandos de troca de protocolo (DMSS/STREAM) não existem.

## Rotas de readback — todas fechadas

| Rota | Resultado |
|---|---|
| MEMORY_DEBUG via HELLO_RSP(mode=2) | 0x1b — memory debug NÃO suportado (definitivo) |
| SWITCH_MODE(2) → HELLO(mode=2) → HELLO_RSP(mode=2) | 0x1b |
| SWITCH_MODE(2) → MEMORY_DEBUG 0x10/0x09 do host | 0x01 |
| MEMORY_READ 64-bit (0x11) em command mode | 0x01 |
| MEMORY_READ 64-bit (0x11) no estado mode=2 | 0x01 |
| STREAM dload (exec 0x05) | 0x1f |
| DMSS dload (exec 0x04) | 0x1f |

O PBL do a016 NÃO expõe leitura de memória por nenhum caminho Sahara.

## Falha/maquina de estados do PBL a016 (achados novos)

1. **Um HELLO_RSP por estado**: um segundo HELLO_RSP no mesmo estado derruba
   o command mode (exec passa a responder 0x01).
2. **Perda de estado após NAK**: qualquer exec com NAK tira o PBL do command
   mode. O exec seguinte responde 0x01 (não 0x1f).
3. **Recuperação por software existe**: `RESET_STATE_MACHINE (0x13)` →
   HELLO novo → `HELLO_RSP(mode=3)` → `CMD_READY` restaura o command mode
   sem replug físico. Repetível ~4–5 vezes por power-on; depois o PBL para
   de responder ao 0x13 (orçamento de resets).
4. **SWITCH_MODE 0–3 aceito**: qualquer valor (inclusive 2/memory-debug) faz
   o PBL reenviar HELLO ecoando o modo pedido — é um reset de estado, não
   uma troca real de modo.
5. **Estado "aguardando HELLO_RSP" é estrito**: enviar 0x13 nesse estado
   enverga o USB (escrita timeout). Também enverga com escrita dupla sem
   ler o HELLO intermediário (esse era o "wedge" visto nas sessões iniciais —
   bug do cliente, não do PBL).
6. **Wedge = só power cycle resolve**: clear_halt, reset do xHCI e
   re-enumeração não recuperam; o dispositivo enumera parcialmente
   (05c6:9008 com strings quebradas, error -71).
7. **Watchdog não observado**: wedge não auto-cura em até 8 minutos.

## Estado atual do problema

- O PBL pendura em `SHELF Load+Auth Start` no boot normal.
- Sem programmer ASUS (raiz `fd5f133f...`) não há Firehose; os MELFs IQ-X
  são rejeitados com 0x21 (cadeia de teste, não ASUS). Não existe loader
  público para HWID 002ad0e1/OEM 0029 (bkerler/Loaders e temblast verificados).
- O PBL não dá readback — então não dá para ler a flash, verificar o que
  corrompeu nem fazer backup pela USB.

## Caminhos restantes (fora do Sahara)

1. **Programmer ASUS de serviço** (devprg com software_id=3 assinado pela
   raiz ASUS) — não é público; só via serviço técnico ASUS.
2. **Gravador externo na mídia de boot**: identificar o chip real da mídia
   de boot e ler com CH341A/programmer. `U3003` (Winbond W25Q80EW, 1 MiB,
   1,8 V) é o principal suspeito de XBL core/SHELF; 1 MiB comporta um
   primeiro estágio. Um CH341A (~R$30) + clip lê esse chip sem dessoldar.
3. **UART do PBL**: a placa pode expor console UART com logs do boot;
   o CH340 já presente no PC serviria de adaptador. Isso revelaria a causa
   exata do hang em SHELF Load+Auth.

## Sessões preservadas

- `pbl-exploit-probe-*.txt` — varredura inicial e mapa de NAKs.
- `pbl-stateprobe-*.txt` — descoberta da recuperação via 0x13 e varreduras.
- `pbl-modes-20261105-125736.txt` — SWITCH_MODE 0–3 e NAKs de memory read.
- `pbl-mem2-20261105-125923.txt` — variantes do memory-debug (todas NAK).
- `pbl-stateprobe-20261105-130024/130747/130847.txt` — varredura 0x0D–0x10,
  DMSS e confirmações.
- Ferramentas: `x1407qa-pbl-exploit-probe.py`, `x1407qa-sahara-stateprobe.py`,
  `x1407qa-sahara-modes.py`, `x1407qa-sahara-mem2.py`.

Não publicar serial, senha sudo ou dumps futuros sem revisar dados exclusivos
da unidade.
