#!/bin/bash
# Roteiro manual da placa de som do Yoga 14Q8Y11 (rodar NO NOTEBOOK, como root).
# Uma etapa por chamada, na ordem; cada uma para no primeiro erro.
#   prep    qualquer slot, antes do boot de teste: topologia + UCM (so arquivos)
#   adsp    sobe o ADSP com o firmware em staging
#   svc     apr + pd-mapper + q6apm/q6prm (pinctrl LPASS da probe)
#   macros  VA e WSA macros (escrevem em registradores LPASS)
#   amps    reset-gpio + wsa884x + soundwire (tira os amplificadores do reset)
#   card    DAIs + placa de som
#   mixer [DV] [PA]   rotas + volume (padrao DV=54 = -30 dB, PA=0 = minimo)
#   tone    voz "Front Left..." em cada canal, uma vez
#   mic     grava 3 s dos DMIC0/1 em /tmp/mic.wav
#   status  so leitura
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
cset() { amixer -q -c "$C" cset "name=$1" "$2" || die "controle '$1' falhou"; }

case "${1:-}" in
prep)
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
	echo disabled > "$A/recovery"
	echo -n "$STAGE" > /sys/module/firmware_class/parameters/path
	echo start > "$A/state" || true
	echo -n > /sys/module/firmware_class/parameters/path
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
	alive; cat /proc/asound/cards; aplay -l
	;;
mixer)
	C=$(card); [ -n "$C" ] || die "sem placa"
	DV=${2:-54}; PA=${3:-0}
	[ "$DV" -le 81 ] && [ "$PA" -le 12 ] || die "limite: DV<=81 (teto do kernel), PA<=12 (padrao do UCM)"
	cset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1
	for m in WSA WSA2; do
		cset "$m WSA RX0 MUX" AIF1_PB; cset "$m WSA RX1 MUX" AIF1_PB
		cset "$m WSA_RX0 INP0" RX0; cset "$m WSA_RX1 INP0" RX1
		cset "$m WSA_COMP1 Switch" 0; cset "$m WSA_COMP2 Switch" 0
		cset "$m WSA_RX0 Digital Volume" "$DV"; cset "$m WSA_RX1 Digital Volume" "$DV"
	done
	for s in WooferLeft TweeterLeft WooferRight TweeterRight; do
		cset "$s PA Volume" "$PA"
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
		cset "VA_AIF1_CAP Mixer DEC$i" 1; cset "VA_DEC$i Volume" 100
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
