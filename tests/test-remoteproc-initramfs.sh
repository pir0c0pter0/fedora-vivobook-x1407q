#!/usr/bin/env bash
set -euo pipefail

for token in qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf; do
    grep -q "$token" setup-vivobook.sh || { echo "setup missing early boot item: $token" >&2; exit 1; }
done

grep -q 'CONFIG_QCOM_Q6V5_PAS=m' kernel/verify-linux-7.2-x1407qa.sh || {
    echo 'kernel verifier does not enforce PAS module' >&2
    exit 1
}

echo 'PASS: remoteproc initramfs contract is explicit'
