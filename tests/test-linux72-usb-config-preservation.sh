#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard=$root/kernel/verify-linux-usb-config-preservation.sh
prepare=$root/kernel/prepare-linux-7.2-x1407qa-config.sh
manifest_writer=$root/kernel/write-linux-artifact-manifest.sh
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

[[ -x $guard ]] || {
    echo 'Linux USB config preservation guard missing' >&2
    exit 1
}
[[ -x $prepare ]] || {
    echo 'Linux 7.2 stable config preparation helper missing' >&2
    exit 1
}
[[ -x $manifest_writer ]] || {
    echo 'Linux artifact manifest writer missing' >&2
    exit 1
}

reference=$test_root/reference.config
candidate=$test_root/candidate.config

manifest_root=$test_root/artifacts
mkdir -p "$manifest_root/nested"
printf 'artifact\n' > "$manifest_root/nested/example.ko"
"$manifest_writer" "$manifest_root"
grep -Eq '^[[:xdigit:]]{64}  \./nested/example\.ko$' "$manifest_root/SHA256SUMS" || {
    echo 'artifact manifest did not use a canonical relative path' >&2
    exit 1
}
(cd "$manifest_root" && sha256sum --check SHA256SUMS >/dev/null)

cat > "$reference" <<'EOF'
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_DWC3=m
CONFIG_USB_DWC3_QCOM=m
CONFIG_USB_USBNET=m
CONFIG_USB_NET_CDCETHER=m
CONFIG_USB_NET_RNDIS_HOST=m
CONFIG_TYPEC=m
CONFIG_TYPEC_UCSI=m
CONFIG_UCSI_PMIC_GLINK=m
CONFIG_PHY_QCOM_QMP_COMBO=m
CONFIG_ISO9660_FS=y
CONFIG_JOLIET=y
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_DM_SNAPSHOT=m
CONFIG_UNRELATED_REFERENCE=y
# CONFIG_NF_TABLES is not set
# CONFIG_NF_CONNTRACK_BROADCAST is not set
# CONFIG_NF_CONNTRACK_NETBIOS_NS is not set
# CONFIG_NF_TABLES_INET is not set
# CONFIG_NFT_CT is not set
# CONFIG_NFT_NAT is not set
# CONFIG_NFT_REJECT is not set
# CONFIG_NFT_REJECT_INET is not set
# CONFIG_NFT_FIB_IPV4 is not set
# CONFIG_NFT_FIB_IPV6 is not set
# CONFIG_NFT_FIB_INET is not set
EOF

reference_hash=$(sha256sum "$reference" | awk '{print $1}')
old_reference_hash=35763b73052b88433a942b93555a1ce931d81abc67f9e465821c10683ac26199
fake_hash_bin=$test_root/hash-bin
real_sha256sum=$(command -v sha256sum)
mkdir -p "$fake_hash_bin"
cat > "$fake_hash_bin/sha256sum" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == -- && \${2:-} == '$reference' ]]; then
    echo '$old_reference_hash  $reference'
    exit 0
fi
exec '$real_sha256sum' "\$@"
EOF
chmod +x "$fake_hash_bin/sha256sum"
PATH="$fake_hash_bin:$PATH" "$guard" "$reference" "$reference" >/dev/null

test_guard=$test_root/verify-linux-usb-config-preservation.sh
sed "s/^readonly EXPECTED_REFERENCE_SHA256=.*/readonly EXPECTED_REFERENCE_SHA256=$reference_hash/" \
    "$guard" > "$test_guard"
chmod +x "$test_guard"
test_repo=$test_root/repo
mkdir -p "$test_repo/kernel"
cp "$prepare" "$test_repo/kernel/prepare-linux-7.2-x1407qa-config.sh"
cp "$test_guard" "$test_repo/kernel/verify-linux-usb-config-preservation.sh"
test_prepare=$test_repo/kernel/prepare-linux-7.2-x1407qa-config.sh

untrusted_reference=$test_root/untrusted-reference.config
cp "$reference" "$untrusted_reference"
printf 'CONFIG_UNTRUSTED_REFERENCE=y\n' >> "$untrusted_reference"
if "$test_guard" "$untrusted_reference" "$untrusted_reference" >/dev/null 2>&1; then
    echo 'USB guard accepted a reference config with an untrusted identity' >&2
    exit 1
fi

cp "$reference" "$candidate"
sed -i 's/CONFIG_UNRELATED_REFERENCE=y/# CONFIG_UNRELATED_REFERENCE is not set/' "$candidate"
"$test_guard" "$reference" "$candidate" >/dev/null

printf '# CONFIG_USB_NEWER_KERNEL_OPTION is not set\n' >> "$candidate"
"$test_guard" "$reference" "$candidate" >/dev/null

grep -v '^CONFIG_USB_NET_RNDIS_HOST=' "$reference" > "$candidate"
missing_output=$test_root/missing-rndis.output
if "$test_guard" "$reference" "$candidate" >"$missing_output" 2>&1; then
    echo 'USB guard accepted a candidate without RNDIS tethering' >&2
    exit 1
fi
grep -qF 'CONFIG_USB_NET_RNDIS_HOST=m' "$missing_output" || {
    echo 'USB guard did not identify the missing RNDIS tethering contract' >&2
    exit 1
}

cp "$reference" "$candidate"
sed -i 's/CONFIG_USB_DWC3=m/# CONFIG_USB_DWC3 is not set/' "$candidate"
drift_output=$test_root/usb-drift.output
if "$test_guard" "$reference" "$candidate" >"$drift_output" 2>&1; then
    echo 'USB guard accepted a changed USB controller configuration' >&2
    exit 1
fi
grep -qF 'USB/Type-C configuration drift' "$drift_output" || {
    echo 'USB guard did not report protected configuration drift' >&2
    exit 1
}

cp "$reference" "$candidate"
sed -i 's/CONFIG_PHY_QCOM_QMP_COMBO=m/# CONFIG_PHY_QCOM_QMP_COMBO is not set/' "$candidate"
if "$test_guard" "$reference" "$candidate" >/dev/null 2>&1; then
    echo 'USB guard accepted a disabled Qualcomm USB3/DP combo PHY' >&2
    exit 1
fi

rm -f "$candidate"
ln -s "$reference" "$candidate"
if "$test_guard" "$reference" "$candidate" >/dev/null 2>&1; then
    echo 'USB guard accepted a symlink candidate config' >&2
    exit 1
fi

source_root=$test_root/linux-7.2
build_root=$test_root/build
fake_bin=$test_root/bin
mkdir -p "$source_root/scripts" "$build_root" "$fake_bin"
cat > "$source_root/scripts/config" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --file && $# == 4 ]]
config_file=$2
symbol=CONFIG_$4
case "$symbol" in
    CONFIG_NF_TABLES|CONFIG_NF_CONNTRACK_BROADCAST|\
    CONFIG_NF_CONNTRACK_NETBIOS_NS|CONFIG_NF_TABLES_INET|\
    CONFIG_NFT_CT|CONFIG_NFT_NAT|\
    CONFIG_NFT_REJECT|CONFIG_NFT_REJECT_INET|CONFIG_NFT_FIB_IPV4|\
    CONFIG_NFT_FIB_IPV6|CONFIG_NFT_FIB_INET) ;;
    *) exit 0 ;;
esac
case "$3" in
    --enable) value=y ;;
    --module) value=m ;;
    *) exit 1 ;;
esac
if grep -q "^$symbol=" "$config_file"; then
    sed -i "s/^$symbol=.*/$symbol=$value/" "$config_file"
elif grep -q "^# $symbol is not set$" "$config_file"; then
    sed -i "s/^# $symbol is not set$/$symbol=$value/" "$config_file"
else
    printf '%s=%s\n' "$symbol" "$value" >> "$config_file"
fi
EOF
cat > "$fake_bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
build_root=
for argument in "$@"; do
    case "$argument" in
        O=*) build_root=${argument#O=} ;;
    esac
done
[[ -n $build_root && -f $build_root/.config ]]
grep -qxF 'CONFIG_USB_NET_RNDIS_HOST=m' "$build_root/.config"
if [[ ${X1407QA_TEST_USB_DRIFT:-0} == 1 ]]; then
    sed -i 's/CONFIG_USB_DWC3=m/# CONFIG_USB_DWC3 is not set/' "$build_root/.config"
fi
EOF
chmod +x "$source_root/scripts/config" "$fake_bin/make"

PATH="$fake_bin:$PATH" \
    "$test_prepare" "$source_root" "$build_root" "$reference" >/dev/null
"$test_guard" "$reference" "$build_root/.config" >/dev/null
for required_config in \
    CONFIG_NF_TABLES=m CONFIG_NF_CONNTRACK_BROADCAST=m \
    CONFIG_NF_CONNTRACK_NETBIOS_NS=m \
    CONFIG_NF_TABLES_INET=y CONFIG_NFT_CT=m \
    CONFIG_NFT_NAT=m CONFIG_NFT_REJECT=m CONFIG_NFT_REJECT_INET=m \
    CONFIG_NFT_FIB_IPV4=m CONFIG_NFT_FIB_IPV6=m CONFIG_NFT_FIB_INET=m; do
    grep -qxF "$required_config" "$build_root/.config" || {
        echo "config preparation omitted firewalld dependency $required_config" >&2
        exit 1
    }
done

drift_build=$test_root/drift-build
mkdir -p "$drift_build"
if PATH="$fake_bin:$PATH" X1407QA_TEST_USB_DRIFT=1 \
    "$test_prepare" "$source_root" "$drift_build" "$reference" >/dev/null 2>&1; then
    echo 'config preparation accepted USB drift after olddefconfig' >&2
    exit 1
fi

echo 'PASS: Linux candidate configs preserve the stable USB tethering contract'
