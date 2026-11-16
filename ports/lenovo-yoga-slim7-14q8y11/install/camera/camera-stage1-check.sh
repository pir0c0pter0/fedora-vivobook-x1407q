#!/bin/sh
# Etapa 1 das cameras: so LEITURA. Rodar no notebook depois de subir o DTB de teste.
# Sucesso: aparece o dispositivo "gpio-keys-camera" e o pino 99 muda com a chave.
set -u
echo "== kernel/slot"; uname -r; grep -o 'yoga/[a-z0-9]*/vmlinuz' /proc/cmdline
echo "== no DT"; ls -d /proc/device-tree/gpio-keys-camera /proc/device-tree/leds-camera 2>&1
echo "== dispositivo de entrada"
grep -A8 'Name="gpio-keys-camera"' /proc/bus/input/devices || echo "FALHA: sem gpio-keys-camera"
echo "== pinos (99 chave, 111 LED, 106/109/239 devem seguir intocados)"
grep -E 'gpio(99|106|109|111|239) ' /sys/kernel/debug/gpio
echo "== LED"; ls /sys/class/leds 2>/dev/null | grep -i indicator || echo "(sem LED: DTB sem -DYOGA_CAMERA_PRIVACY_LED)"
echo "== dmesg"; dmesg | grep -iE 'gpio-keys|leds-gpio|gpio99|gpio111' | tail -10
