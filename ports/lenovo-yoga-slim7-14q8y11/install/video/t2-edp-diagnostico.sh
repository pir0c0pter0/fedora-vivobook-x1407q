#!/bin/bash
# T2 (tela preta com link eDP treinado) - roda NO NOTEBOOK, como root, no slot try
# com o DTB gwnd1. Os tres .ko ficam ao lado deste script (/root/t2).
# uso: t2-edp.sh load | fill white|bars|black | cycle | fps | crc | dump
#                | dpcd r END N | dpcd w END B0 [B1..] | set MOD PARAM VALOR
#                | mdpclk HZ|0 | snap NOME | final
# Numeros do dpcd em hexadecimal. Nada aqui toca em pcie/nvme/reguladores.
set -u
T=$(dirname "$(readlink -f "$0")")
O=$T/out; mkdir -p "$O"
FB=/sys/class/graphics/fb0
BL=/sys/class/backlight/dp_aux_backlight

dri()  { dirname "$(grep -l '^msm' /sys/kernel/debug/dri/*/name 2>/dev/null | head -1)"; }
aux()  { ls -d /sys/bus/dp-aux/devices/aux-* 2>/dev/null | head -1; }
up()   { cut -d' ' -f1 /proc/uptime; }
# linhas novas do dmesg desde a ultima chamada (so as que interessam)
news() {
	local n; n=$(cat "$O/.mark" 2>/dev/null || echo 0)
	dmesg | tail -n +$((n + 1)) | grep -E 'DIAG|DPCD|DUMP|link training|successful|\*ERROR\*|updated bpp|misc settings|DP_CONFIGURATION_CTRL|wide_bus_en|underrun|timeout|WARNING|SError' | grep -vE 'dpu_dp_aux: 0x' | cut -c1-200
	dmesg | wc -l > "$O/.mark"
}

case "${1:-}" in
load)
	grep -q 'yoga/try/' /proc/cmdline || { echo "ABORTA: nao e o slot try"; exit 1; }
	[ -e /proc/device-tree/regulator-edp-3p3 ] || { echo "ABORTA: DTB sem o no do painel (nao e gwnd1)"; exit 1; }
	lsmod | grep -qE '^(msm|phy_qcom_edp|panel_samsung_atna33xc20) ' && { echo "ABORTA: modulo da arvore ja carregado"; exit 1; }
	for k in phy-qcom-edp.ko panel-samsung-atna33xc20.ko msm.ko; do
		[ "$(modinfo -F vermagic "$T/$k" | cut -d' ' -f1)" = "$(uname -r)" ] || { echo "ABORTA: vermagic de $k"; exit 1; }
	done
	dmesg | wc -l > "$O/.mark"; sync
	modprobe dispcc_glymur; sleep 2
	echo "[$(up)] insmod phy fwdump=${FWDUMP:-1}"; sync
	insmod "$T/phy-qcom-edp.ko" fwdump="${FWDUMP:-1}" || exit 1
	sleep 2; dmesg > "$O/00-fwdump-dmesg.txt"; sync
	modprobe -a drm_dp_aux_bus drm_panel drm_display_helper
	insmod "$T/panel-samsung-atna33xc20.ko" || exit 1
	modprobe -a drm_exec drm_gpuvm gpu-sched drm_kms_helper drm_client_lib mdt_loader ocmem ubwc_config llcc-qcom
	echo none > /sys/bus/platform/devices/3d00000.gpu/driver_override
	sync; btrfs filesystem sync /
	echo "[$(up)] insmod msm (a tela apaga agora)"
	insmod "$T/msm.ko" separate_gpu_kms=1; echo "rc=$?"
	sleep 10
	news
	for c in /sys/class/drm/card*-eDP-*; do echo "$c $(cat "$c/status") $(head -1 "$c/modes")"; done
	cat /proc/fb; grep -E 'gpio(18|70|119) ' /sys/kernel/debug/gpio
	;;
fill)
	python3 -I - "${2:-white}" <<'EOF'
import sys
w, h = 1920, 1200
bars = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(64,64,64)]
if sys.argv[1] == "bars":
    row = b"".join(bytes((b, g, r, 0)) * (w // 8) for r, g, b in bars)
else:
    v = 255 if sys.argv[1] == "white" else 0
    row = bytes((v, v, v, 0)) * w
open("/dev/fb0", "wb").write(row * h)
EOF
	echo "fb0 = ${2:-white}"
	;;
cycle)
	# ciclo de energia completo do painel (EL_ON3 e 3V3 caem; autosuspend nao entra: unprepare e sincrono)
	echo "[$(up)] blank"; echo 4 > $FB/blank; sleep 4
	grep -E 'gpio(18|70) ' /sys/kernel/debug/gpio | tr '\n' ' '; echo
	echo "[$(up)] unblank"; echo 0 > $FB/blank; sleep 3
	[ -e $BL/brightness ] && cat $BL/max_brightness > $BL/brightness
	news
	grep -E 'gpio(18|70) ' /sys/kernel/debug/gpio | tr '\n' ' '; echo
	sh "$0" fill white
	;;
fps)
	D=$(dri); a=$(cat "$D"/encoder-*/status 2>/dev/null | head -1)
	n=$(timeout 10 cat "$D/crtc-0/crc/data" | wc -l)
	echo "quadros em 10 s: $n (esperado ~600 = 60 Hz; ~1200 => divisor de pixel /2; ~400 => /6; ~300 => /8)"
	echo "antes : $a"; echo "depois: $(cat "$D"/encoder-*/status | head -1)"
	;;
crc)
	D=$(dri)
	for s in lm encoder; do
		echo $s > "$D/crtc-0/crc/control" 2>/dev/null
		echo "-- fonte $s:"; timeout 2 cat "$D/crtc-0/crc/data" | tail -2
	done
	echo auto > "$D/crtc-0/crc/control" 2>/dev/null
	;;
dump)	cat "$(aux)/dpcd_dump" ;;
dpcd)	shift; echo "$*" > "$(aux)/dpcd"; cat "$(aux)/dpcd" ;;
set)	echo "$4" > "/sys/module/$2/parameters/$3"; echo "$2.$3=$(cat "/sys/module/$2/parameters/$3")"; news ;;
mdpclk)
	P=$(dri)/debug/core_perf
	if [ "${2:-0}" = 0 ]; then echo 0 > "$P/perf_mode"; else echo "$2" > "$P/fix_core_clk_rate"; echo 2 > "$P/perf_mode"; fi
	cat "$P/perf_mode"; echo "(vale no proximo cycle; conferir disp_cc_mdss_mdp_clk)"
	;;
snap)
	N=$O/${2:-snap}; D=$(dri)
	dmesg > "$N-dmesg.txt"
	{
		echo "== uptime $(up)"; grep . /sys/module/{msm,phy_qcom_edp,panel_samsung_atna33xc20}/parameters/* 2>/dev/null
		echo "== dp_debug"; cat "$D"/eDP-1/dp_debug 2>/dev/null
		echo "== state"; cat "$D/state"
		echo "== encoder"; cat "$D"/encoder-*/status
		echo "== clocks"; for c in disp_cc_mdss_dptx3_pixel0_clk disp_cc_mdss_dptx3_link_clk disp_cc_mdss_dptx3_link_intf_clk disp_cc_mdss_mdp_clk disp_cc_pll0 faac00.phy::link_clk faac00.phy::vco_div_clk tcsr_edp_clkref_en; do echo "$c rate=$(cat "/sys/kernel/debug/clk/$c/clk_rate" 2>/dev/null) en=$(cat "/sys/kernel/debug/clk/$c/clk_enable_count" 2>/dev/null)"; done
		echo "== irq"; grep -E 'msm|dp_display|mdss' /proc/interrupts
		echo "== gpio"; grep -E 'gpio(18|70|119) ' /sys/kernel/debug/gpio
		echo "== backlight"; grep . $BL/{brightness,actual_brightness,max_brightness,bl_power} 2>/dev/null
		echo "== reguladores"; grep -E 'vreg_l1f1|vreg_l2f1|vreg_l4f1|VREG_EDP_3P3|faac00|af6c000' /sys/kernel/debug/regulator/regulator_summary
		echo "== dpcd"; cat "$(aux)/dpcd_dump" 2>&1
	} > "$N-state.txt" 2>&1
	sync; echo "gravado $N-*.txt"
	;;
final)
	"$0" snap 99-final
	cat /sys/kernel/debug/clk/clk_summary > "$O/99-clk-summary.txt"; sync; btrfs filesystem sync /
	# por ultimo e ja com tudo no disco: snapshot dos registradores DPU/DP do Linux (par do fwdump)
	cat "$(dri)/kms" > "$O/99-kms.txt" 2>&1; dmesg > "$O/99-final-dmesg.txt"; sync
	ls -la "$O"
	;;
*)	sed -n 2,8p "$0" ;;
esac
