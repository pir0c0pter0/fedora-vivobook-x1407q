#!/bin/sh
# Video real (msm/eDP) no slot try - roda NO NOTEBOOK, como root, a partir do
# slot current. Ao lado deste script: kalambo-gwnxd1.dtb e phy-qcom-edp.ko
# (extmod-edp3). NAO reinicia e NAO marca o proximo boot: depois de conferir a
# saida, rode "yoga-boot-once try && systemctl reboot".
#
# O que muda fora de /boot/yoga/try (tudo inerte no slot current, que nao tem
# yoga.video=1 na cmdline nem o no do painel no DTB):
#   /usr/lib/modules/<ver>/updates/phy-qcom-edp.ko  + depmod (updates/ ganha do
#       kernel/: /etc/depmod.d esta vazio, conferido com kmod 34.2)
#   /usr/local/sbin/yoga-video-up, /etc/systemd/system/yoga-video.service
# Desfazer: systemctl disable yoga-video.service; rm os tres arquivos; depmod -a.
set -eu
T=$(dirname "$(readlink -f "$0")")
V=$(uname -r)
M=/usr/lib/modules/$V
DTB_SHA=87d1a723bfb361b130e073acadcc8ba877ab5bc6750aebe7b590fc910e9ff047
KO_SHA=206d11ef20eb1b063d3cf98e4cf92760d033415653ba5899e62ff4b819127710
BL=ucsi_glink,pmic_glink_altmode,qcom_pd_mapper,apr,fastrpc,snd_q6apm,q6prm,q6prm_clocks,q6apm_dai,q6apm_lpass_dais,snd_soc_lpass_wsa_macro,snd_soc_lpass_va_macro,soundwire_qcom,snd_soc_wsa884x,snd_soc_x1e80100,rtc_pm8xxx

die() { echo "ABORTA: $*" >&2; exit 1; }

grep -q 'yoga/current/' /proc/cmdline || die "rode a partir do slot current"
[ "$(sha256sum < "$T/kalambo-gwnxd1.dtb" | cut -d' ' -f1)" = "$DTB_SHA" ] || die "sha256 do DTB"
[ "$(sha256sum < "$T/phy-qcom-edp.ko" | cut -d' ' -f1)" = "$KO_SHA" ] || die "sha256 do phy-qcom-edp.ko"
[ "$(modinfo -F vermagic "$T/phy-qcom-edp.ko" | cut -d' ' -f1)" = "$V" ] || die "vermagic do phy-qcom-edp.ko"
# a linha do slot try parte da do current: se ela mudou, pare e refaca a BL acima
grep -q "modprobe.blacklist=$BL\"" /boot/yoga/current/args.cfg || die "args.cfg do current mudou; atualize BL neste script"

# 1. PHY corrigido em updates/ (o da arvore fica onde esta)
install -D -m 0644 "$T/phy-qcom-edp.ko" "$M/updates/phy-qcom-edp.ko"
depmod -a "$V"
case $(modinfo -n phy_qcom_edp) in */updates/phy-qcom-edp.ko) ;; *) die "depmod nao escolheu updates/";; esac

# 2. carga explicita antes do GDM (a blacklist so vale para carga por alias)
cat > /usr/local/sbin/yoga-video-up <<'EOF'
#!/bin/sh
# Yoga X2 Plus: sobe o video real (dispcc + PHY eDP corrigido + painel + msm).
# msm e dispcc_glymur estao na modprobe.blacklist (grub.cfg, /etc/modprobe.d e
# initramfs) e phy_qcom_edp na do slot: aqui a carga e pelo nome, que a
# blacklist nao impede. Antes do msm nada apaga a tela; depois, so ele acende.
fail() {
	echo "yoga-video: FALHA: $*" >&2
	dmesg > "/var/log/yoga-video-fail-$(date +%Y%m%d-%H%M%S).txt"; sync
	# so no slot de teste: volta sozinho para o current (next_entry ja foi apagado)
	if [ -n "$LOADED" ] && grep -qw yoga.video.failreboot=1 /proc/cmdline; then
		systemctl --no-block reboot
	fi
	exit 1
}
LOADED=
case $(modinfo -n phy_qcom_edp) in */updates/phy-qcom-edp.ko) ;; *) fail "phy_qcom_edp nao vem de updates/ (rode depmod -a)";; esac
if [ -e /sys/module/phy_qcom_edp ] && [ ! -e /sys/module/phy_qcom_edp/parameters/vco_div ]; then
	fail "phy_qcom_edp da arvore ja carregado (falta phy_qcom_edp na modprobe.blacklist do slot)"
fi
modprobe dispcc_glymur || fail "dispcc_glymur"
modprobe phy_qcom_edp || fail "phy_qcom_edp"
[ -e /sys/module/phy_qcom_edp/parameters/vco_div ] || fail "phy_qcom_edp carregado nao e o corrigido"
modprobe panel_samsung_atna33xc20 || fail "panel_samsung_atna33xc20"
# como no teste T2: a GPU nao entra (Mesa nao conhece o chip; gpucc_glymur bloqueado)
echo none > /sys/bus/platform/devices/3d00000.gpu/driver_override 2>/dev/null
LOADED=1
modprobe msm separate_gpu_kms=1 || fail "msm"
i=0
while [ $i -lt 200 ]; do
	for c in /sys/class/drm/card*-eDP-1; do
		if [ "$(cat "$c/status" 2>/dev/null)" = connected ] && [ -e /sys/class/backlight/dp_aux_backlight ]; then
			# O primeiro modeset sai em 18 bpp; a imagem so foi vista apos um ciclo blank/unblank (30 bpp).
			# Aqui ainda nao ha DRM master (GDM/kmscon sobem depois), entao o fbdev consegue fazer o ciclo.
			sleep 1; echo 4 > /sys/class/graphics/fb0/blank; sleep 4; echo 0 > /sys/class/graphics/fb0/blank; sleep 3
			cat /sys/class/backlight/dp_aux_backlight/max_brightness > /sys/class/backlight/dp_aux_backlight/brightness
			echo "yoga-video: ok $c $(head -1 "$c/modes")"
			exit 0
		fi
	done
	sleep 0.1; i=$((i + 1))
done
fail "eDP-1 nao conectou em 20 s"
EOF
chmod 0755 /usr/local/sbin/yoga-video-up

cat > /etc/systemd/system/yoga-video.service <<'EOF'
[Unit]
Description=Yoga X2 Plus: video real (dispcc + PHY eDP corrigido + msm) antes do GDM
# So com o DTB de video (gwnxd1) e com o slot pedindo; nos outros slots nao faz nada.
ConditionKernelCommandLine=yoga.video=1
ConditionPathExists=/proc/device-tree/regulator-edp-3p3
After=systemd-modules-load.service
# o msm tira o simpledrm (card0): tem de acontecer antes de alguem virar DRM master
Before=display-manager.service kmsconvt@tty1.service getty@tty1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/yoga-video-up
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable yoga-video.service

# 3. slot try = kernel e initramfs do current + DTB gwnxd1 + args
install -m 0644 /boot/yoga/current/vmlinuz /boot/yoga/try/vmlinuz
install -m 0600 /boot/yoga/current/initramfs.img /boot/yoga/try/initramfs.img
install -m 0644 "$T/kalambo-gwnxd1.dtb" /boot/yoga/try/board.dtb
cat > /boot/yoga/try/args.cfg <<EOF
# Video real (msm/eDP): DTB gwnxd1 + phy-qcom-edp de updates/ carregado pelo yoga-video.service.
# phy_qcom_edp bloqueado: o initramfs tem o da arvore (divisor errado) e o udev o carregaria pelo alias.
# yoga.video.failreboot=1 so no slot try (reinicia e volta ao current se o video nao subir).
set yoga_slot_args="panic=30 pcie_aspm=off nvme_core.default_ps_max_latency_us=0 modprobe.blacklist=$BL,phy_qcom_edp yoga.video=1 yoga.video.failreboot=1"
EOF
sync
cmp /boot/yoga/current/vmlinuz /boot/yoga/try/vmlinuz
cmp /boot/yoga/current/initramfs.img /boot/yoga/try/initramfs.img
[ "$(sha256sum < /boot/yoga/try/board.dtb | cut -d' ' -f1)" = "$DTB_SHA" ] || die "DTB gravado no slot try"
echo "== slot try"; ls -la /boot/yoga/try; cat /boot/yoga/try/args.cfg
echo "== phy: $(modinfo -n phy_qcom_edp)"
echo "== servico: $(systemctl is-enabled yoga-video.service)"
echo "PRONTO. Proximo passo: yoga-boot-once try && systemctl reboot"
