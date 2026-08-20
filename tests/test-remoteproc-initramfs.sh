#!/usr/bin/env bash
set -euo pipefail

setup=setup-vivobook.sh
verifier=kernel/verify-linux-7.2-x1407qa.sh
updater=vivobook-update.sh

grep -q '^require_remoteproc_early_boot_assets()' "$setup" || {
    echo 'setup missing remoteproc asset helper' >&2
    exit 1
}
grep -q '^require_remoteproc_early_boot_assets$' "$setup" || {
    echo 'setup does not invoke remoteproc asset helper' >&2
    exit 1
}

remoteproc_config=$(sed -n '/cat > \/etc\/dracut.conf.d\/qcom-remoteproc.conf/,/^EOF$/p' "$setup")
[[ -n $remoteproc_config ]] || { echo 'setup does not write qcom-remoteproc.conf' >&2; exit 1; }
for token in qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf; do
    grep -q "$token" <<<"$remoteproc_config" || { echo "remoteproc config missing: $token" >&2; exit 1; }
done

kernel_config_checks=$(sed -n '/for required_config in/,/done/p' "$verifier")
grep -q 'grep -qxF "$required_config"' <<<"$kernel_config_checks" || {
    echo 'kernel verifier does not check its required config list' >&2
    exit 1
}
for required_config in CONFIG_QCOM_Q6V5_PAS=m CONFIG_QCOM_Q6V5_ADSP=m CONFIG_QCOM_PMIC_GLINK=m CONFIG_BATTERY_QCOM_BATTMGR=m; do
    grep -q "$required_config" <<<"$kernel_config_checks" || {
        echo "kernel verifier missing remoteproc config assertion: $required_config" >&2
        exit 1
    }
done

grep -q '^verify_qcom_remoteproc_config()' "$updater" || {
    echo 'vivobook-update missing remoteproc config validator' >&2
    exit 1
}
grep -qE '(! verify_qcom_remoteproc_config|verify_qcom_remoteproc_config \|\|)' "$updater" || {
    echo 'vivobook-update does not invoke remoteproc config validator' >&2
    exit 1
}
updater_validator=$(awk '
    /^verify_qcom_remoteproc_config\(\)/ { in_validator=1 }
    in_validator { print }
    in_validator && /^}$/ { exit }
' "$updater")
for token in qcom-remoteproc qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf; do
    grep -q "$token" <<<"$updater_validator" || { echo "vivobook-update validator missing: $token" >&2; exit 1; }
done
if grep -qE 'qcom-(adsp|cdsp)-firmware' "$updater"; then
    echo 'vivobook-update still expects split ADSP/CDSP dracut configs' >&2
    exit 1
fi

echo 'PASS: remoteproc initramfs contract is explicit'
