# USB2 com a placa Wi-Fi ativa no Yoga X2 Plus

Esta pasta documenta a base USB2 permanente. O próximo trabalho é USB3 em
uma porta por vez, conforme o [processo atual](../../WORKFLOW.md#atual--próxima-sessão-usb-3);
não basta retirar `maximum-speed` do DT nem observar root hubs `10000M`.

Unidade preparada para o DTB `gwnx2d1`; validar primeiro no slot `try`.
A regra udev pede a unidade na criação ou renomeação (`add|move`) da interface
de rede do driver `ath12k_wifi7_pci`. Ela procura o driver nos pais do dispositivo,
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

O DT fixa as três portas em USB2 host. Não oferece USB3, troca de papel nem
DisplayPort. Sem a placa Wi-Fi ativa e os trilhos em uso, a primeira carga
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
