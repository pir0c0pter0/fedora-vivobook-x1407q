#!/bin/bash
# Roteiro manual da placa de som do Yoga 14Q8Y11 (rodar NO NOTEBOOK, como root).
# Uma etapa por chamada, na ordem; cada uma para no primeiro erro.
#   prep    qualquer slot, antes do boot de teste: topologia + UCM (so arquivos)
#   adsp    sobe o ADSP com o firmware em staging
#   svc     apr + pd-mapper + q6apm/q6prm (pinctrl LPASS da probe)
#   macros  VA e WSA macros (escrevem em registradores LPASS)
#   amps    reset-gpio + wsa884x + soundwire (tira os amplificadores do reset)
#   card    DAIs + placa de som
#   mixer [DV] [PA]   rotas + volume (teto validado DV=66 = -18 dB, PA=6)
#   tone    voz "Front Left..." em cada canal, uma vez
#   mic     grava 3 s dos DMIC0/1 em /tmp/mic.wav
#   status  so leitura
#   up      inicializacao automatica, somente com yoga.audio=1
# Desfazer = reiniciar. Nunca rmmod, nunca escrever no rproc "soccp".
set -euo pipefail

FWDIR=/usr/lib/firmware/qcom/glymur
TPLG=$FWDIR/GLYMUR-LENOVO-Yoga-Slim7x-tplg.bin
TPLG_SHA=ea851335b7e8e13977a597250f2c0f1b6434d68f2248ae85a332e158fd64db57
UCM=/usr/share/alsa/ucm2/conf.d/glymur
STAGE=/var/lib/yoga-fw
BAT=/sys/class/power_supply/qcom-battmgr-bat/capacity

die() { echo "ABORTAR: $*" >&2; exit 1; }
alive() {	# o que nao pode ter mudado
	[ "$(cat "$(soccp)/state")" = attached ] || die "SoCCP nao esta attached"
	cat "$BAT" >/dev/null || die "bateria nao responde"
}
rproc() { local n; n=$(grep -lx "$1" /sys/class/remoteproc/*/name) || die "rproc $1 nao existe"; dirname "$n"; }
soccp() { rproc soccp; }
waitfor() {	# waitfor <segundos> <comando...>
	local t=$1; shift
	while ! "$@" >/dev/null 2>&1; do t=$((t - 1)); [ "$t" -gt 0 ] || return 1; sleep 1; done
}
bound() { [ -e "/sys/bus/platform/devices/$1/driver" ]; }
card() { awk '/GLYMUR/ { print $1; exit }' /proc/asound/cards; }
cset() {
	local id
	id=$(amixer -c "$C" controls | awk -F, -v name="name='$1'" '$NF == name { sub(/^numid=/, "", $1); print $1 }')
	[[ "$id" =~ ^[0-9]+$ ]] || die "controle '$1' ausente ou ambiguo"
	amixer -q -c "$C" cset "numid=$id" "$2" || die "controle '$1' falhou"
}

[ "$EUID" = 0 ] || die "execute como root"
tr '\000' '\n' < /sys/firmware/devicetree/base/compatible |
	grep -qx 'lenovo,yoga-slim7x-gen11-x2plus-diag' || die "DT de outra placa"

case "${1:-}" in
up)
	grep -qw yoga.audio=1 /proc/cmdline || die "falta yoga.audio=1"
	systemctl is-active --quiet yoga-camera.service || die "camera/base inativa"
	[ -f "$UCM/HiFi.conf" ] || die "perfil UCM Yoga ausente"
	sha256sum -c - <<EOF
2d4cbfbbabf6323e28ec0159c9d48d0a1c39d0d1ab50fc2884da8aaee6235a60  $UCM/glymur.conf
7c2ba868d66c95be56ffd6fd0d5a94d6971e185d0d3049bed4f972f6285cc956  $UCM/HiFi.conf
EOF
	echo "$TPLG_SHA  $TPLG" | sha256sum -c -
	for step in adsp svc macros amps card mixer; do "$0" "$step"; done
	alive
	card_path=$(readlink -e "/sys/class/sound/card$(card)")
	[[ "$card_path" == /sys/devices/platform/sound/sound/card[0-9]* ]] || die "caminho ALSA inesperado"
	touch /run/yoga-audio.ready
	udevadm trigger --action=change --settle --subsystem-match=sound --parent-match="$card_path"
	udevadm trigger --action=change --settle "$card_path"
	;;
prep)
	[ ! -e "$UCM/HiFi.conf" ] || die "perfil Yoga ja instalado; nao substituir pelo CRD"
	[ -e "$STAGE/qcom/glymur/LENOVO/83QR/qcadsp8480.mbn" ] || die "firmware do ADSP nao esta em $STAGE"
	[ ! -e "$FWDIR/LENOVO/83QR" ] || die "$FWDIR/LENOVO/83QR existe: o ADSP subiria sozinho no boot"
	xz -dc "$FWDIR/GLYMUR-CRD-tplg.bin.xz" > "$TPLG"	# o kernel em uso nao le .xz
	echo "$TPLG_SHA  $TPLG" | sha256sum -c -
	ln -sfn ../../Qualcomm/glymur/GLYMUR-CRD.conf "$UCM/glymur.conf"
	ls -l "$TPLG" "$UCM/glymur.conf"
	;;
adsp)
	alive
	A=$(rproc adsp)
	[ "$(cat "$A/state")" = offline ] || die "adsp em $(cat "$A/state"), esperado offline"
	sha256sum -c - <<EOF
0dd34edabca5c5545728934ab6e75ea6a824c0c85e7b9a895650a78b8a9144f8  $STAGE/qcom/glymur/LENOVO/83QR/qcadsp8480.mbn
7b0b994eed1e32e05a98e3234b362404ecd78cd01a37185d283ec70fea8ddae5  $STAGE/qcom/glymur/LENOVO/83QR/adsp_dtbs.elf
EOF
	FWPATH=$(cat /sys/module/firmware_class/parameters/path)
	# sysfs ignora escrita de zero bytes; newline tambem limpa o caminho vazio.
	trap 'printf "%s\n" "$FWPATH" > /sys/module/firmware_class/parameters/path' EXIT
	echo disabled > "$A/recovery"
	echo -n "$STAGE" > /sys/module/firmware_class/parameters/path
	echo start > "$A/state" || true
	printf "%s\n" "$FWPATH" > /sys/module/firmware_class/parameters/path
	[ "$(cat /sys/module/firmware_class/parameters/path)" = "$FWPATH" ] || die "caminho de firmware nao restaurado"
	[ "$(cat "$A/state")" = running ] || die "adsp nao subiu (dmesg)"
	alive; echo "adsp running"
	;;
svc)
	alive
	modprobe --ignore-install snd-pcm	# dist-alsa.conf pede snd-seq, que este kernel nao tem
	modprobe apr
	modprobe qcom_pd_mapper
	waitfor 10 test -e /sys/bus/aprbus/devices/gprsvc:service:2:1 || die "servico GPR do APM nao apareceu"
	modprobe snd_q6apm	# pode logar 1x "CMD timeout for [1001021]": visto no teste anterior, nao e fatal
	modprobe q6prm
	modprobe q6prm_clocks
	waitfor 15 test -e /sys/kernel/debug/pinctrl/7760000.pinctrl/pins || die "pinctrl LPASS nao deu probe"
	alive; grep -E 'gpio1[23] ' /sys/kernel/debug/gpio | tail -2
	;;
macros)
	alive
	bound 7760000.pinctrl || die "rode a etapa svc antes"
	modprobe snd_soc_lpass_va_macro
	waitfor 5 bound 7660000.codec || die "VA macro sem driver"
	modprobe snd_soc_lpass_wsa_macro
	waitfor 5 bound 6c90000.codec || die "WSA macro sem driver"
	waitfor 5 bound 6cb0000.codec || die "WSA2 macro sem driver"
	alive; echo "macros ok"
	;;
amps)
	alive
	bound 6cb0000.codec || die "rode a etapa macros antes"
	modprobe reset-gpio
	modprobe snd_soc_wsa884x
	modprobe soundwire_qcom
	waitfor 5 bound 6c80000.soundwire || die "swr0 sem driver"
	waitfor 5 bound 6ca0000.soundwire || die "swr3 sem driver"
	sleep 2
	for d in /sys/bus/soundwire/devices/sdw:*; do echo "$d $(cat "$d/status" 2>/dev/null)"; done
	grep -E 'gpio1[23] ' /sys/kernel/debug/gpio | tail -2
	n=$(cat /sys/bus/soundwire/devices/sdw:*/status 2>/dev/null | grep -c Attached || true)
	[ "$n" = 4 ] || die "$n de 4 amplificadores Attached"
	alive; echo "4 amplificadores ok"
	;;
card)
	alive
	[ -e "$TPLG" ] || die "rode a etapa prep antes"
	modprobe q6apm_lpass_dais
	modprobe q6apm_dai
	modprobe snd_soc_x1e80100
	waitfor 10 grep -q GLYMUR /proc/asound/cards || die "placa nao registrou (cat /sys/kernel/debug/devices_deferred)"
	C=$(card)
	udevadm wait --timeout=10 --initialized=yes "/dev/snd/controlC$C"
	alive; cat /proc/asound/cards; aplay -l
	;;
mixer)
	C=$(card); [ -n "$C" ] || die "sem placa"
	DV=${2:-66}; PA=${3:-6}
	[[ "$DV" =~ ^[0-9]+$ && "$PA" =~ ^[0-9]+$ ]] &&
		[ "$DV" -le 66 ] && [ "$PA" -le 6 ] || die "limites validados: 0<=DV<=66, 0<=PA<=6"
	# Os controles LPASS retornam EBUSY durante runtime-suspend.
	for dev in 6c90000.codec 6cb0000.codec; do
		echo on > "/sys/bus/platform/devices/$dev/power/control"
	done
	for s in WooferLeft TweeterLeft WooferRight TweeterRight; do cset "$s PA Volume" "$PA"; done
	cset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1
	for m in WSA WSA2; do
		cset "$m WSA RX0 MUX" AIF1_PB; cset "$m WSA RX1 MUX" AIF1_PB
		cset "$m WSA_RX0 INP0" RX0; cset "$m WSA_RX1 INP0" RX1
		cset "$m WSA_COMP1 Switch" 0; cset "$m WSA_COMP2 Switch" 0
		cset "$m WSA_RX0 Digital Volume" "$DV"; cset "$m WSA_RX1 Digital Volume" "$DV"
	done
	for s in WooferLeft TweeterLeft WooferRight TweeterRight; do
		cset "$s COMP Switch" 1; cset "$s BOOST Switch" 1; cset "$s PBR Switch" 1
		cset "$s VISENSE Switch" 0; cset "$s WSA MODE" 0; cset "$s DAC Switch" 1
	done
	echo "mixer: Digital Volume $DV (84 = 0 dB), PA Volume $PA"
	;;
tone)
	C=$(card); [ -n "$C" ] || die "sem placa"
	speaker-test -D "plughw:$C,0" -c 4 -r 48000 -t wav -l 1
	alive
	;;
mic)
	C=$(card); [ -n "$C" ] || die "sem placa"
	cset 'MultiMedia2 Mixer VA_CODEC_DMA_TX_0' 1
	for i in 0 1; do
		cset "VA DEC$i MUX" VA_DMIC; cset "VA DMIC MUX$i" "DMIC$i"
		cset "VA_AIF1_CAP Mixer DEC$i" 1; cset "VA_DEC$i Volume" 84
	done
	arecord -D "plughw:$C,1" -c 2 -r 48000 -f S16_LE -d 3 -V stereo /tmp/mic.wav
	alive
	;;
status)
	for r in /sys/class/remoteproc/*; do echo "$r $(cat "$r/name" "$r/state")"; done
	cat "$BAT"; cat /proc/asound/cards; cat /sys/kernel/debug/devices_deferred
	for d in /sys/bus/soundwire/devices/sdw:*; do [ -e "$d" ] && echo "$d $(cat "$d/status")"; done
	dmesg | grep -iE 'apm|prm|gpr|adsp|lpass|wsa|soundwire|asoc|snd|tplg' | grep -v tpd | tail -40
	;;
*)
	sed -n '2,16p' "$0"; exit 2
	;;
esac
