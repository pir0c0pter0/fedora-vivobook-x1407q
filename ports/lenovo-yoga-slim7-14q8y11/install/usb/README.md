# USB2 após a conexão Wi-Fi do Yoga X2 Plus

Unidade preparada para o DTB `gwnx2d1`; validar primeiro no slot `try`.
O dispatcher do NetworkManager dispara a unidade com `systemctl --no-block`
quando `wlP4p1s0` recebe o evento `up`. O boot continua enquanto o Wi-Fi
conecta em paralelo, sem espera por link online. Antes de carregar os PHYs,
a unidade exige `operstate=up` e uso maior que zero nos três trilhos
`vreg_l1f1`, `vreg_l2f1` e `vreg_l4f1`. Sem essas condições, falha. Não para
nem descarrega módulos.

No notebook, a partir da pasta do porte já copiada:

```sh
sudo install -m 0644 install/usb/yoga-usb.service /etc/systemd/system/
sudo install -o root -g root -m 0755 install/usb/90-yoga-usb /etc/NetworkManager/dispatcher.d/90-yoga-usb
sudo systemctl disable yoga-usb.service NetworkManager-wait-online.service
sudo systemctl daemon-reload
```

No `args.cfg` do slot em teste, acrescentar `phy_qcom_eusb2_repeater` e
`phy_qcom_m31_eusb2` à lista existente de `modprobe.blacklist`, mantendo os
demais bloqueios, e acrescentar `yoga.usb=1` aos argumentos. Isso deixa a
carga dos PHYs para a unidade, depois do Wi-Fi. Preservar os slots de reserva.
Após o boot, conferir `systemctl status yoga-usb.service` e os três xHCI em
`dmesg`; a enumeração física continua precisando ser conferida por porta.

O DT fixa as três portas em USB2 host. Não oferece USB3, troca de papel nem
DisplayPort. Sem Wi-Fi, os PHYs ficam sem carga por esta unidade. Cada evento
`up` pode dispará-la; depois da primeira carga bem-sucedida ela permanece
ativa, inclusive se o Wi-Fi desconectar. A unidade respeita a ordem de
`yoga-video.service` sem bloquear o dispatcher. Se for instalada com o Wi-Fi
já conectado, `sudo systemctl start yoga-usb.service` inicia a carga sem
esperar outro evento. Sem `yoga.usb=1`, a unidade não executa. Para retirar
sua ativação, remover `/etc/NetworkManager/dispatcher.d/90-yoga-usb`;
reiniciar desfaz a carga dos PHYs.

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
