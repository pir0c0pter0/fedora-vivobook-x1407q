# Alimentação das câmeras do Yoga

`yoga-camera-pmic-identify.dts` deriva do boot USB3 atual e acrescenta somente
BOB1_B_E0 e I2C5 a 100 kHz. Não instancia sensores, PMIC, CAMSS ou iluminador.
Os GPIOs 106/109/239 permanecem intocados pelo DT. Uso apenas no slot `try`.

Fontes da placa: `CAMF_RES_QRD.bin` e `CAMI_RES_QRD.bin` da coleta Windows
pedem BOB1_B_E0 em 3,4 V, depois GPIO106 alto, espera e LDOs I0.
O DSDT (`Device (PML0)`) declara I2C6/QUP0_SE5, endereço 0x08 e 100 kHz.
O driver RPMh local usa `pmic5_bob` para PMH0101: 3 V + n × 32 mV;
por isso o intervalo 3,400–3,416 V seleciona 3,416 V.
A [série DTS Qualcomm v2](https://lore.kernel.org/all/20261015-glymur_camss_dts-v2-4-e7b1f403146f@oss.qualcomm.com/)
corrobora PM8010, GPIO106 e I2C5. A alimentação L6 → L1/L2 foi usada nas
capturas RGB/IR bem-sucedidas de 17/11, embora a ligação física não esteja
declarada no ACPI coletado deste Yoga.

## Teste de identificação — histórico anterior à integração

Esta sequência usou a base USB3 sem câmeras. O `current` de 17/11 já contém
as câmeras e mantém BOB1 ativo. Para repetir a identificação isolada no
`try`, retirar `yoga.camera=1` dos argumentos copiados; não iniciar o serviço
de câmeras nesse DT de identificação.

1. Salvar conteúdo e hashes de `current`, `good` e `try`, além de `grubenv`.
   Preparar `try` copiando o kernel/initramfs/args de `current` e substituindo
   apenas `board.dtb`. Acrescentar à blacklist de `try` os módulos
   `qcom_pm8008,qcom_pm8008_regulator`; usar `yoga-boot-once try`.
   Não promover esse DT de diagnóstico ao boot normal.
2. Após voltar por SSH, conferir o slot, vídeo, bateria, rede, NVMe e USB.
   Conferir `regulator_summary`: `vreg_bob1_e0` deve estar ligado em 3416 mV.
   Localizar o adaptador com caminho `b94000.i2c` e o gpiochip cujo label é
   `f100000.pinctrl`; não presumir números de `/dev/i2c-*` ou gpiochip.
   GPIO109/239 devem permanecer iguais ao baseline.
3. Antes de GPIO106, uma leitura dirigida pode verificar se o PMIC já responde:
   `i2ctransfer -y BUS w2@0x08 0x01 0x00 r8`. Não usar `-f`, `i2cdetect`
   nem `i2cdump`. Essa escrita de dois bytes só seleciona o endereço interno.
4. Se não responde, manter GPIO106 alto com `gpioset` da versão instalada,
   após revisar sua ajuda. Usar drive push-pull e sem pull. Manter o processo
   vivo durante as leituras; esperar ao menos 1 ms antes de repetir o comando.
5. Registrar os 8 bytes de 0x0100 e ler o mesmo intervalo em 0x09. O mapa
   Qualcomm usa tipo em 0x0104 (=0x51) e subtipo em 0x0105
   (`PM8010_SUBTYPE=0x41`, `include/soc/qcom/qcom-spmi-pmic.h`).
   Um ACK isolado não confirma o modelo. Se os IDs não baterem, parar antes
   de carregar os drivers ou programar LDOs.
6. Ler apenas os registradores de identificação/estado necessários dos LDOs
   em 0x09, depois encerrar o controle de GPIO106 levando-o a zero.
   Na base anterior, o reboot normal removia o voto BOB1 desse teste.
   No `current` integrado, o reboot restaura as câmeras e mantém BOB1;
   não equivale a desligar permanentemente a alimentação do PMIC.
   Conferir serviços, hashes dos slots preservados e logs após o retorno.

O teste energiza a entrada do PMIC e seu enable; não programa as saídas dos
LDOs. Se o estado herdado do firmware habilitar saídas, registrá-lo antes de
qualquer alteração.

Identificação comprovada em **17/11/2026** no Yoga: BOB1 em 3416 mV,
GPIO106 alto e ambos os endereços 0x08/0x09 retornando
`13 00 03 01 51 41 01 00` a partir de 0x0100. Tipo 0x51/subtipo 0x41
confirmam PM8010. Com GPIO106 baixo não houve resposta. Ao encerrar, o pino
voltou a zero e GPIO109/239 permaneceram intactos. Evidência privada:
`local/physical-2026-11-17/camera-workflow/pmic-id-enable-high-v2.txt`.
Isso confirma entrada/enable/comunicação, ainda não as saídas dos LDOs.

O teste posterior conjunto confirmou leitura dos IDs dos sensores e captura
RGB/IR com as saídas abaixo. O serviço automático e o boot normal também
passaram; a etapa de identificação isolada acima permanece apenas histórica.

## Fragmento para os sensores

`yoga-camera-power.dtsi` é o estágio posterior: incluir sobre o DT base atual,
em conjunto com os fragmentos CAMSS e de sensores, depois da identificação.
Não incluir o DTS de identificação ao mesmo tempo. Carregar os módulos PM8010
manualmente apenas após confirmar BOB1 ativo, porque o driver MFD não controla
a alimentação da entrada. LDO1/2 recebem LDO6 a 1,8 V conforme a referência
CRD; não há declaração dessa ligação física na coleta ACPI do Yoga.

| Saída | Tensão selecionada | Uso |
|---|---:|---|
| LDO1 | 1,152 V | IR digital (Windows pede 1,15 V) |
| LDO2 | 1,104 V | RGB digital (Windows pede 1,1 V) |
| LDO3 | 2,8 V | IR analógico |
| LDO4 | 1,8 V | I/O compartilhado |
| LDO6 | 1,8 V | Entrada de LDO1/2, conforme CRD |
| LDO7 | 2,8 V | RGB analógico |

Não se atribui tensão a LDO5, sem consumidor neste porte. Nenhuma saída tem
`regulator-always-on`; os sensores devem pedir as saídas quando necessário.
Os valores dos trilhos dos sensores vêm de CAMF/CAMI, ajustados à grade do
driver. Não copiar os 1,2 V de LDO1/2 da referência CRD para este Yoga.
