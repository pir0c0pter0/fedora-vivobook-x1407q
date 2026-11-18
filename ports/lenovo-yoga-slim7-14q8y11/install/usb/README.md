# USB2 e USB3 no Yoga X2 Plus

Suporte permanente validado em 17/11/2026: **direita Gen1 (5 Gbit/s),
esquerdas Gen2 (10 Gbit/s)**, nas duas orientações. A direita leu 16 GiB por
orientação a 296/288 MB/s, sem resets ou erros; hashes de amostras iguais.
O pendrive via adaptador também passou na direita a 480M. USB2 nas esquerdas
já havia sido comprovado; não foi repetido nesta rodada.

A solução combina o patch Qualcomm do QMP combo, o DTS USB3 com direita
limitada a Gen1 e `yoga-usb3.service`, acionado pela mesma regra udev do USB2.
Passou no `try` e no boot normal pelo `current`; `good` permanece USB2 e a
base anterior tem backup. Gen2 na direita continua reprovado, mesmo com o
patch; o ensaio sem LPM também falhou e não foi mantido. USB4/DP alt-mode
não foram ativados. Ver [estado e evidências](../../docs/ESTADO-ATUAL.md).

## Base USB2 preservada

Unidade preparada para o DTB `gwnx2d1`; validar primeiro no slot `try`.
A regra udev pede a unidade na criação ou renomeação (`add|move`) da interface
de rede do driver `ath12k_wifi7_pci`. O mesmo evento ativa o alias
`/sys/subsystem/net/yoga-wifi-ready`, do qual depende a unidade USB2.
A espera pelo alias tem limite de 20 s. A regra procura o driver nos pais do dispositivo,
sem depender do nome inicial `wlan0` ou do nome após a renomeação. O boot não espera por
link online; o Wi-Fi pode associar em paralelo ou continuar sem rede.
Antes de carregar os PHYs, a unidade exige o driver no dispositivo PCIe
`0004:01:00.0`, seu estado de energia `active` e uso maior que zero nos três
trilhos `vreg_l1f1`, `vreg_l2f1` e `vreg_l4f1`. Sem essas condições, falha.
Não para nem descarrega módulos e não altera o controle de energia PCIe.

A carga pela unidade foi comprovada com a rede desconectada e a interface
em `operstate=down`: três xHCI e seis root hubs, mantendo vídeo, bateria e
NVMe. O gatilho automático `add|move` passou no slot `try`: USB entre 13,125
e 13,187 s, antes da associação Wi-Fi em 20,858 s. No boot normal pelo
`current`, USB entre 13,205 e 13,266 s, antes da associação em 20,873 s;
vídeo, RTC, EC e GDM ativos. Esta rodada não repetiu confirmação visual nem
inserções de pendrive por porta.

No notebook, a partir da pasta do porte já copiada:

```sh
sudo install -m 0644 install/usb/yoga-usb.service /etc/systemd/system/
alias_unit=$(systemd-escape --path --suffix=device /sys/subsystem/net/yoga-wifi-ready)
sudo install -D -m 0644 "install/usb/$alias_unit.d/timeout.conf" "/etc/systemd/system/$alias_unit.d/timeout.conf"
sudo rm -f /etc/NetworkManager/dispatcher.d/90-yoga-usb
sudo install -o root -g root -m 0644 install/usb/90-yoga-usb.rules /etc/udev/rules.d/
sudo systemctl disable yoga-usb.service NetworkManager-wait-online.service
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
```

No `args.cfg` do slot em teste, acrescentar `phy_qcom_eusb2_repeater` e
`phy_qcom_m31_eusb2` à lista existente de `modprobe.blacklist`, mantendo os
demais bloqueios, e acrescentar `yoga.usb=1` aos argumentos. Isso deixa a
carga dos PHYs para a unidade, após a placa Wi-Fi estar ativa. Preservar os slots de reserva.
Após o boot, conferir `systemctl status yoga-usb.service` e os três xHCI em
`dmesg`; a enumeração física continua precisando ser conferida por porta.

O DT da base `gwnx2d1` fixa as três portas em USB2 host. A variante
`gwnx2d1-usb3` acrescenta os combos e endpoints descritos abaixo. Troca de
papel e DisplayPort não foram validados. Sem a placa Wi-Fi ativa e os trilhos em uso, a primeira carga
USB fica bloqueada; não é necessária associação a uma rede. Depois de uma
carga bem-sucedida, a unidade permanece ativa. Ela respeita a ordem de
`yoga-video.service` e não tem dependência do NetworkManager. O systemd
processa `SYSTEMD_WANTS` quando o dispositivo fica ativo pela primeira vez:
recarregar a regra não inicia a unidade para uma interface que já existe.
Nesse caso, `sudo systemctl start yoga-usb.service` aplica as mesmas guardas;
o próximo boot exercita o gatilho udev. Sem `yoga.usb=1`, a unidade não
executa. Para retirar sua ativação, remover
`/etc/udev/rules.d/90-yoga-usb.rules` e recarregar as regras; reiniciar desfaz
a carga dos PHYs.

## Compilar e instalar o módulo USB3 calibrado

O [patch Qualcomm](../../patches/phy-qcom-qmp-combo-glymur-usb3-settings.patch)
altera 27 valores das tabelas USB3 do QMP combo. Não altera tensões dos
reguladores, firmware dos PS8830 nem SoCCP. Origem:
[Konrad Dybcio, 27/10/2026](https://lkml.iu.edu/2610.3/06058.html).
Ele sozinho não estabilizou a direita em Gen2; a configuração validada
também limita `usb_2` a `maximum-speed = "super-speed"`.

No PC de build, a partir da raiz do repositório, com o container existente
`yoga-iso-build` rodando e a árvore/configuração/Module.symvers do kernel em uso:

```sh
set -eu
port=ports/lenovo-yoga-slim7-14q8y11
build="$port/local/iso-build"
module="$build/extmod-usb3"
test ! -e "$module"
mkdir "$module"
cp "$build/kernel/drivers/phy/qualcomm/phy-qcom-qmp-combo.c" "$module/"
cp "$build/kernel/drivers/phy/qualcomm/"*.h "$module/"
git apply --check -p4 --directory="$module" "$port/patches/phy-qcom-qmp-combo-glymur-usb3-settings.patch"
git apply -p4 --directory="$module" "$port/patches/phy-qcom-qmp-combo-glymur-usb3-settings.patch"
printf 'obj-m += phy-qcom-qmp-combo.o\n' > "$module/Makefile"
podman exec yoga-iso-build make -C /work/kernel O=/work/kernel-out-edp M=/work/extmod-usb3 ARCH=arm64 LLVM=1 -j4 modules
modinfo -F vermagic "$module/phy-qcom-qmp-combo.ko"
```

Kernel validado: `7.4.0-rc1-yoga-kalambo+`. Módulo de 17/11: SHA256
`7b319dd1bf03d8739d69d60e82874ac8b602956ed927d2801f3fa63cff8d269c`, build-id
`e52a2da3c5cde89b5bee1dc9621f0b7d52a0b09c`. Compare o vermagic com o módulo
original do notebook antes de instalar. Uma recompilação pode produzir outro hash.

No Lenovo, instalar o `.ko` em `/usr/lib/modules/<release>/updates/`,
preservando qualquer arquivo anterior, executar `depmod -a <release>` e
conferir que `modprobe --show-depends phy_qcom_qmp_combo` seleciona `updates`.
Não descarregar o PHY em execução. O original permanece em `kernel/` e
também no initramfs: manter `phy_qcom_qmp_combo` nas listas existentes de
`modprobe.blacklist` e `rd.driver.blacklist` para evitar carga antecipada.

Instalar `yoga-usb3.service` em `/etc/systemd/system/` e a regra desta pasta
em `/etc/udev/rules.d/`, recarregar systemd/udev e acrescentar `yoga.usb3=1`
aos argumentos existentes do slot. Usar o DTB de
[`kalambo-lenovo-yoga-slim7x-gwnx2d1-usb3.dts`](../../dts/kalambo-lenovo-yoga-slim7x-gwnx2d1-usb3.dts),
SHA256 `0a5f45a995b39af9c27b4ce05438abdb3119cd740cbb44ec4ac4d21ef0331551`.
O serviço preserva as guardas USB2, exige vídeo/SoCCP, PCIe Wi-Fi/NVMe ativos
e uso positivo de l3f0/l4h0/l2f0/l1f1/l2f1/l4f1; carrega combo, espera os
três hosts e carrega UCSI. Não espera associação à rede.

Validar uma tentativa pelo `try` antes de promover `current`. Não usar o
drop-in experimental `10-phy-test.conf` na instalação permanente. Conferir
o build-id em `/sys/module/phy_qcom_qmp_combo/notes/.note.gnu.build-id`,
sucesso da unidade, dispositivo externo folha e leituras nas duas orientações.
Preservar `good` e backup completo do `current` anterior. Para retirar USB3,
restaurar DTB e argumentos USB2 e reiniciar; não parar o SoCCP.

## RTC existente

Reutilizar `install/ec-rtc/rtc-fallback/yoga-rtc` e `yoga-rtc.service`, sem
alterá-los. A unidade já exige `/proc/device-tree/aliases/rtc1`, presente no
`gwnx2d1`; não carregar `rtc_pm8xxx` à mão em DTBs sem esse alias, pois pode
registrar `rtc0` e deslocar a hora para 1970.

```sh
sudo install -m 0755 install/ec-rtc/rtc-fallback/yoga-rtc /usr/local/sbin/
sudo install -m 0644 install/ec-rtc/rtc-fallback/yoga-rtc.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable yoga-rtc.service
```

O offset já coletado fica em `/var/lib/yoga-rtc/offset`. No boot com o alias,
conferir a unidade e `rtc1`. Para renovar o offset, executar
`sudo /usr/local/sbin/yoga-rtc save` com `rtc1` disponível e NTP sincronizado.
A instalação dessas unidades não comprova o boot nem o funcionamento físico.
