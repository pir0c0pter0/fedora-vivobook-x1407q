#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin" "$tmp/artifacts/boot/dtb/qcom" \
    "$tmp/artifacts/lib/modules/7.2.0-x1407qa/extra" \
    "$tmp/artifacts/lib/modules/7.2.0-x1407qa/kernel/drivers/net/usb"
printf 'arm64 kernel\nLinux version 7.2.0-x1407qa (mock@fixture) #1 SMP\n' \
    > "$tmp/artifacts/boot/vmlinuz-7.2.0-x1407qa"
printf 'dtb\n' > "$tmp/artifacts/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb"
printf 'modules\n' > "$tmp/artifacts/lib/modules/7.2.0-x1407qa/modules.dep"
for module in wcn_regulator_fix vivobook_hotkey_fix vivobook_kbd_fix vivobook_bl_fix; do
    printf 'arm64 module\n' > "$tmp/artifacts/lib/modules/7.2.0-x1407qa/extra/$module.ko"
done
printf 'arm64 module\n' \
    > "$tmp/artifacts/lib/modules/7.2.0-x1407qa/kernel/drivers/net/usb/rndis_host.ko"
# Reference for the USB config-preservation guard: must hold every USB symbol the
# final candidate config carries, and nothing more, or the drift check trips.
cat > "$tmp/reference-config" <<'EOF'
CONFIG_USB_USBNET=m
CONFIG_USB_NET_CDCETHER=m
CONFIG_USB_NET_CDC_NCM=m
CONFIG_USB_NET_RNDIS_HOST=m
EOF
cat > "$tmp/artifacts/boot/config-7.2.0-x1407qa" <<'EOF'
CONFIG_ISO9660_FS=y
CONFIG_JOLIET=y
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_DM_SNAPSHOT=m
CONFIG_FW_LOADER_COMPRESS=y
CONFIG_FW_LOADER_COMPRESS_XZ=y
CONFIG_HID=y
CONFIG_I2C_HID_CORE=y
CONFIG_BACKLIGHT_CLASS_DEVICE=y
CONFIG_REGULATOR=y
CONFIG_SPMI=y
CONFIG_MFD_SPMI_PMIC=y
CONFIG_REGMAP_SPMI=y
CONFIG_I2C_QCOM_GENI=m
CONFIG_ATH11K=m
CONFIG_ATH11K_PCI=m
CONFIG_QCOM_Q6V5_PAS=m
CONFIG_QCOM_Q6V5_ADSP=m
CONFIG_QCOM_PMIC_GLINK=m
CONFIG_BATTERY_QCOM_BATTMGR=m
EOF
cat > "$tmp/bin/file" <<'EOF'
#!/usr/bin/env bash
echo "$1: ELF 64-bit LSB, ARM aarch64"
EOF
cat > "$tmp/bin/modinfo" <<'EOF'
#!/usr/bin/env bash
case ${2:-} in
    name) echo 'rndis_host' ;;
    vermagic) echo '7.2.0-x1407qa SMP preempt mod_unload aarch64' ;;
    softdep) printf '%s\n' "${MOCK_SOFTDEP:-}" ;;
esac
EOF
cat > "$tmp/bin/modprobe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# ponytail: the guard pins the reference config's sha256 to the trusted 7.2
# baseline, which no fabricated fixture can reproduce — report the pinned hash
# for our mock reference only, pass everything else to the real sha256sum.
real_sha256sum=$(command -v sha256sum)
cat > "$tmp/bin/sha256sum" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == -- && \${2:-} == '$tmp/reference-config' ]]; then
    echo '35763b73052b88433a942b93555a1ce931d81abc67f9e465821c10683ac26199  $tmp/reference-config'
    exit 0
fi
exec '$real_sha256sum' "\$@"
EOF
chmod +x "$tmp/bin/file" "$tmp/bin/modinfo" "$tmp/bin/modprobe" "$tmp/bin/sha256sum"

write_sums() {
    (cd "$tmp/artifacts" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) \
        > "$tmp/artifacts/SHA256SUMS"
}

write_sums
if X1407QA_REFERENCE_CONFIG="$tmp/reference-config" PATH="$tmp/bin:$PATH" \
    "$repo/kernel/verify-linux-7.2-x1407qa.sh" "$tmp/artifacts" >/dev/null 2>&1; then
    fail 'kernel verifier accepted artifacts without USB RNDIS, Bluetooth PAN and WCN power sequencing'
fi

cat >> "$tmp/artifacts/boot/config-7.2.0-x1407qa" <<'EOF'
CONFIG_USB_USBNET=m
CONFIG_USB_NET_CDCETHER=m
CONFIG_USB_NET_CDC_NCM=m
CONFIG_USB_NET_RNDIS_HOST=m
CONFIG_BT_BNEP=m
CONFIG_POWER_SEQUENCING_QCOM_WCN=m
EOF
write_sums
if MOCK_SOFTDEP='' X1407QA_REFERENCE_CONFIG="$tmp/reference-config" PATH="$tmp/bin:$PATH" \
    "$repo/kernel/verify-linux-7.2-x1407qa.sh" "$tmp/artifacts" >/dev/null 2>&1; then
    fail 'kernel verifier accepted wcn_regulator_fix without a pwrseq_qcom_wcn soft dependency'
fi
MOCK_SOFTDEP='pre: pwrseq_qcom_wcn' X1407QA_REFERENCE_CONFIG="$tmp/reference-config" \
    PATH="$tmp/bin:$PATH" \
    "$repo/kernel/verify-linux-7.2-x1407qa.sh" "$tmp/artifacts" >/dev/null

root_verifier=$repo/tools/verify-live-root.sh
[[ -x $root_verifier ]] || fail 'live-root verifier is missing'
mkdir -p "$tmp/bad/usr/bin" "$tmp/bad/usr/lib/firmware/qcom"
printf '#!/bin/sh\n' > "$tmp/bad/usr/bin/sudo"
chmod 0755 "$tmp/bad/usr/bin/sudo"
printf 'gpu firmware\n' > "$tmp/bad/usr/lib/firmware/qcom/gen71500_sqe.fw.xz"
printf 'gpu firmware\n' > "$tmp/bad/usr/lib/firmware/qcom/gen71500_gmu.bin.xz"
if "$root_verifier" "$tmp/bad" >/dev/null 2>&1; then
    fail 'live-root verifier accepted sudo without root ownership and setuid'
fi

mkdir -p "$tmp/good/usr/bin" "$tmp/good/usr/lib/firmware/qcom"
ln -s /usr/bin/sudo "$tmp/good/usr/bin/sudo"
printf 'gpu firmware\n' > "$tmp/good/usr/lib/firmware/qcom/gen71500_sqe.fw.xz"
printf 'gpu firmware\n' > "$tmp/good/usr/lib/firmware/qcom/gen71500_gmu.bin.xz"
"$root_verifier" "$tmp/good" >/dev/null

installable=$repo/tools/make-rootfs-installable.sh
[[ -x $installable ]] || fail 'rootfs installable helper is missing'
mkdir -p "$tmp/rootfs/usr" "$tmp/rootfs/boot/dtb/qcom" \
    "$tmp/rootfs/boot/loader/entries" "$tmp/rootfs/boot/grub2"
printf 'arm64 kernel\n' > "$tmp/rootfs/boot/vmlinuz-7.2.0-x1407qa"
printf 'initramfs\n' > "$tmp/rootfs/boot/initramfs-7.2.0-x1407qa.img"
printf 'dtb\n' > "$tmp/rootfs/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb"
printf 'linux /root/var/lib/mock/f44-kiwi-build/boot/vmlinuz\n' \
    > "$tmp/rootfs/boot/loader/entries/junk.conf"
printf 'garbage' > "$tmp/rootfs/boot/grub2/grubenv"
"$installable" "$tmp/rootfs" >/dev/null
[[ ! -e $tmp/rootfs/boot/loader/entries/junk.conf ]] || fail 'installable helper kept kiwi BLS entries'
[[ $(stat -c %s "$tmp/rootfs/boot/grub2/grubenv") -eq 1024 ]] \
    || fail 'installable helper produced an invalid grubenv size'
head -c 24 "$tmp/rootfs/boot/grub2/grubenv" | grep -qF '# GRUB Environment Block' \
    || fail 'installable helper produced an unsigned grubenv'
[[ -s $tmp/rootfs/boot/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb ]] \
    || fail 'installable helper did not stage the stable devicetree'
ks=$tmp/rootfs/usr/share/anaconda/post-scripts/90-x1407qa-bootloader.ks
[[ -s $ks ]] || fail 'installable helper did not write the anaconda post-script'
sed -n '/^%post/,/^%end/p' "$ks" | sed '1d;$d' > "$tmp/postbody.sh"
bash -n "$tmp/postbody.sh" || fail 'anaconda post-script body does not parse'
grep -qF 'devicetree $boot_prefix/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb' "$ks" \
    || fail 'anaconda post-script is missing the devicetree line'
grep -qF 'rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix' "$ks" \
    || fail 'anaconda post-script is missing the WCN driver ordering'
grep -qF 'mem_sleep_default=s2idle' "$ks" \
    || fail 'anaconda post-script cmdline is missing mem_sleep_default=s2idle'
grep -qF 'custom.cfg' "$ks" \
    || fail 'anaconda post-script is missing the custom.cfg fallback'
grep -qF 'search --no-floppy --fs-uuid --set=root' "$ks" \
    || fail 'anaconda post-script custom.cfg fallback lacks the fs-uuid search'
rescue=$repo/tools/rescue-installed-boot.sh
[[ -x $rescue ]] || fail 'rescue-installed-boot helper is missing or not executable'
bash -n "$rescue" || fail 'rescue-installed-boot helper does not parse'
[[ -x $tmp/rootfs/usr/local/sbin/rescue-installed-boot ]] \
    || fail 'installable helper did not embed the rescue tool in the live root'
cmp -s "$rescue" "$tmp/rootfs/usr/local/sbin/rescue-installed-boot" \
    || fail 'embedded rescue tool differs from the repo copy'
"$installable" "$tmp/rootfs" >/dev/null || fail 'installable helper is not idempotent'
mkdir -p "$tmp/rootfs-bad/usr" "$tmp/rootfs-bad/boot"
if "$installable" "$tmp/rootfs-bad" >/dev/null 2>&1; then
    fail 'installable helper accepted a live root without the 7.2 kernel'
fi

echo 'PASS: kernel transport, WCN sequencing, live-root metadata and installable-root regressions covered'
