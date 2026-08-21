#!/usr/bin/env bash
set -euo pipefail

REFERENCE_CONFIG=${1:?usage: verify-linux-usb-config-preservation.sh REFERENCE_CONFIG CANDIDATE_CONFIG}
CANDIDATE_CONFIG=${2:?usage: verify-linux-usb-config-preservation.sh REFERENCE_CONFIG CANDIDATE_CONFIG}
readonly EXPECTED_REFERENCE_SHA256=35763b73052b88433a942b93555a1ce931d81abc67f9e465821c10683ac26199

for config_file in "$REFERENCE_CONFIG" "$CANDIDATE_CONFIG"; do
    [[ -f $config_file && ! -L $config_file && -r $config_file ]] || {
        echo "ERROR: kernel config is missing or unsafe: $config_file" >&2
        exit 1
    }
done

reference_sha256=$(sha256sum -- "$REFERENCE_CONFIG" | awk '{print $1}')
[[ $reference_sha256 == "$EXPECTED_REFERENCE_SHA256" ]] || {
    echo 'ERROR: reference config does not match the trusted 7.2.0-x1407qa baseline' >&2
    echo "expected: $EXPECTED_REFERENCE_SHA256" >&2
    echo "actual:   $reference_sha256" >&2
    exit 1
}

grep -qxF 'CONFIG_USB_NET_RNDIS_HOST=m' "$REFERENCE_CONFIG" || {
    echo 'ERROR: stable reference lacks CONFIG_USB_NET_RNDIS_HOST=m' >&2
    exit 1
}
grep -qxF 'CONFIG_USB_NET_RNDIS_HOST=m' "$CANDIDATE_CONFIG" || {
    echo 'ERROR: candidate must preserve CONFIG_USB_NET_RNDIS_HOST=m for USB tethering' >&2
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

normalize_protected_config() {
    awk '
        {
            symbol = $0
            sub(/^# /, "", symbol)
            sub(/[= ].*$/, "", symbol)
            if (symbol ~ /^CONFIG_.*USB/ ||
                symbol ~ /^CONFIG_TYPEC/ ||
                symbol ~ /^CONFIG_UCSI/ ||
                symbol == "CONFIG_PHY_QCOM_QMP_COMBO") {
                value = $0
                if (value ~ /^# CONFIG_.* is not set$/) {
                    value = "n"
                } else {
                    sub(/^[^=]*=/, "", value)
                }
                print symbol "\t" value
            }
        }
    ' "$1" | LC_ALL=C sort
}

normalize_protected_config "$REFERENCE_CONFIG" > "$work/reference"
normalize_protected_config "$CANDIDATE_CONFIG" > "$work/candidate"

awk -F '\t' '
    NR == FNR {
        reference[$1] = $2
        next
    }
    {
        candidate[$1] = $2
    }
    END {
        for (symbol in reference) {
            if (!(symbol in candidate)) {
                print symbol ": reference=" reference[symbol] ", candidate=<missing>"
            } else if (candidate[symbol] != reference[symbol]) {
                print symbol ": reference=" reference[symbol] ", candidate=" candidate[symbol]
            }
        }
        for (symbol in candidate) {
            if (!(symbol in reference) && candidate[symbol] != "n")
                print symbol ": reference=<new>, candidate=" candidate[symbol]
        }
    }
' "$work/reference" "$work/candidate" | LC_ALL=C sort > "$work/diff"

if [[ -s $work/diff ]]; then
    echo 'ERROR: USB/Type-C configuration drift from the stable kernel' >&2
    cat "$work/diff" >&2
    exit 1
fi

echo 'PASS: candidate preserves stable USB/Type-C configuration'
