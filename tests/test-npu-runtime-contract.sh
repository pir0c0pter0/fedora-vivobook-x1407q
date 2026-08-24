#!/usr/bin/env bash
# Contrato dos artefatos de runtime da NPU. Roda no server x86_64, sobre o repo:
# nao exige hardware ARM, CDSP nem o Vivobook ligado.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

authcheck="$repo/tools/lib/hexagon-authcheck.py"
npu_run="$repo/tools/npu-run"
setup="$repo/tools/setup-npu-runtime.sh"
verify="$repo/tools/verify-qnn-npu.py"
module="$repo/modules/qnn-soc-id-fix"
hexagon_readme="$repo/hexagon-dsp/README.md"
hexagon_dir="$repo/hexagon-dsp/cdsp"

for artifact in "$authcheck" "$npu_run" "$setup" "$verify" \
    "$module/Makefile" "$module/qnn_soc_id_fix.c" "$hexagon_readme"; do
    [[ -f $artifact ]] || { echo "NPU runtime artifact missing: $artifact" >&2; exit 1; }
done
[[ -d $hexagon_dir ]] || { echo "Hexagon CDSP binaries missing: $hexagon_dir" >&2; exit 1; }

failures=0

expect() {
    local message=$1
    shift
    if ! "$@"; then
        echo "$message" >&2
        failures=1
    fi
}

# ─── 1. sintaxe ──────────────────────────────────────────────────────────────
expect 'setup-npu-runtime.sh has a shell syntax error' bash -n "$setup"
expect 'npu-run has a shell syntax error' bash -n "$npu_run"
export PYTHONPYCACHEPREFIX="$test_root/pycache"
expect 'hexagon-authcheck.py does not compile' python3 -m py_compile "$authcheck"
expect 'verify-qnn-npu.py does not compile' python3 -m py_compile "$verify"

expect 'npu-run is not executable' test -x "$npu_run"
expect 'hexagon-authcheck.py is not executable' test -x "$authcheck"

# ─── 2. validador de whitelist do firmware ───────────────────────────────────
set +e
self_check_output=$(python3 "$authcheck" --self-check 2>&1)
self_check_status=$?
set -e
expect 'hexagon-authcheck --self-check does not exit 0' test "$self_check_status" -eq 0
expect 'hexagon-authcheck --self-check does not confirm the ELF/whitelist parser' \
    grep -qF 'self-check ok' <<<"$self_check_output"

# O --self-check embutido nao passa por check_binary/check_dir e monta o ELF com
# p_filesz == p_memsz, entao nao ve nem um whitelist afrouxado nem um phdr lido
# do campo errado. Fixture proprio: ELF Hexagon sintetico com filesz != memsz e
# dois .mbn, um que autoriza os dois segmentos e outro que autoriza so um.
python3 - "$test_root" <<'FIXTURE'
import hashlib, os, struct, sys

root = sys.argv[1]
binaries = os.path.join(root, "hexagon-fixture")
os.makedirs(binaries, exist_ok=True)

segments = [b"HEXAGON-SEG-A" * 5, b"HEXAGON-SEG-B" * 9]
ehsize, phentsize = 52, 32
offset = ehsize + phentsize * len(segments)
elf = bytearray(b"\x7fELF\x01\x01\x01" + b"\x00" * 9)
elf += struct.pack("<HHIIIIIHHHHHH", 2, 164, 1, 0, ehsize, 0, 0,
                   ehsize, phentsize, len(segments), 40, 0, 0)
for segment in segments:
    # p_memsz != p_filesz: ler o campo errado muda o digest do segmento.
    elf += struct.pack("<IIIIIIII", 1, offset, 0, 0,
                       len(segment), len(segment) + 4096, 5, 4096)
    offset += len(segment)
for segment in segments:
    elf += segment
with open(os.path.join(binaries, "fake_shell"), "wb") as handle:
    handle.write(bytes(elf))

digests = [hashlib.sha256(segment).digest() for segment in segments]
with open(os.path.join(root, "authorized.mbn"), "wb") as handle:
    handle.write(b"\xff" * 32 + digests[0] + b"\x11" * 8 + digests[1] + b"\xee" * 16)
with open(os.path.join(root, "unauthorized.mbn"), "wb") as handle:
    handle.write(b"\xff" * 32 + digests[0] + b"\x11" * 8)
FIXTURE

set +e
authorized_output=$(python3 "$authcheck" --mbn "$test_root/authorized.mbn" \
    "$test_root/hexagon-fixture" 2>&1)
authorized_status=$?
unauthorized_output=$(python3 "$authcheck" --mbn "$test_root/unauthorized.mbn" \
    "$test_root/hexagon-fixture" 2>&1)
unauthorized_status=$?
set -e
expect "hexagon-authcheck rejects a fully authorized binary ($authorized_output)" \
    test "$authorized_status" -eq 0
expect 'hexagon-authcheck does not report every segment of an authorized binary' \
    grep -qxF '1/1' <<<"$authorized_output"
expect 'hexagon-authcheck accepts a binary the firmware whitelist does not authorize' \
    test "$unauthorized_status" -eq 1
expect 'hexagon-authcheck does not count the unauthorized binary as rejected' \
    grep -qxF '0/1' <<<"$unauthorized_output"

# ─── 3. binarios Hexagon x tabela de SHA-256 do README ───────────────────────
# A tabela e a fonte publicada; os arquivos sao o que o firmware assinado
# autoriza. Divergencia nos dois sentidos e regressao.
published="$test_root/README.sha256"
sed -nE 's/^\| *`([^`]+)` *\| *`([0-9a-f]{64})` *\|.*/\2  \1/p' \
    "$hexagon_readme" > "$published"

sed -E 's/^[0-9a-f]{64}  //' "$published" | sort > "$test_root/documented"
find "$hexagon_dir" -maxdepth 1 -type f -printf '%f\n' | sort > "$test_root/present"

published_count=$(wc -l < "$published")
expect 'hexagon-dsp/README.md publishes no SHA-256 table' test "$published_count" -gt 0

for mandatory in fastrpc_shell_3 fastrpc_shell_unsigned_3 'libc++.so.1' 'libc++abi.so.1'; do
    expect "hexagon-dsp/README.md does not publish a hash for $mandatory" \
        grep -qxF "$mandatory" "$test_root/documented"
    expect "mandatory Hexagon binary is missing: $mandatory" \
        test -f "$hexagon_dir/$mandatory"
done

expect 'Hexagon binaries do not match the SHA-256 table in hexagon-dsp/README.md' \
    bash -c 'cd "$1" && sha256sum -c --quiet "$2"' _ "$hexagon_dir" "$published"

undocumented=$(comm -13 "$test_root/documented" "$test_root/present")
expect "Hexagon binaries absent from the README table: ${undocumented//$'\n'/ }" \
    test -z "$undocumented"

# ─── 4. shim de SoC ID ───────────────────────────────────────────────────────
# Copia para nao deixar o .so compilado no working tree.
if ! command -v make >/dev/null; then
    echo 'make is unavailable: cannot build/self-check modules/qnn-soc-id-fix' >&2
    exit 1
fi
if ! command -v "${CC:-cc}" >/dev/null; then
    echo "C compiler (${CC:-cc}) is unavailable: cannot build modules/qnn-soc-id-fix" >&2
    exit 1
fi
cp -a "$module" "$test_root/qnn-soc-id-fix"
expect 'make check on modules/qnn-soc-id-fix failed (build or open(NULL)/EFAULT regression)' \
    make -s -C "$test_root/qnn-soc-id-fix" check

# ─── 5. npu-run ──────────────────────────────────────────────────────────────
shim="$test_root/qnn-soc-id-fix/qnn_soc_id_fix.so"

set +e
preloaded=$(QNN_SOC_ID_FIX_LIB="$shim" "$npu_run" sh -c 'printf %s "$LD_PRELOAD"' 2>&1)
missing_lib_output=$(QNN_SOC_ID_FIX_LIB="$test_root/nao-existe.so" "$npu_run" /bin/true 2>&1)
missing_lib_status=$?
no_args_output=$("$npu_run" 2>&1)
no_args_status=$?
set -e
expect 'npu-run does not scope the SoC ID shim into the child process' \
    grep -qF "$shim" <<<"$preloaded"
expect 'npu-run does not fail when the shim library is absent' test "$missing_lib_status" -eq 1
expect 'npu-run does not explain the missing shim library' \
    grep -qF 'nao encontrado' <<<"$missing_lib_output"
expect 'npu-run does not point at the build/install command for the shim' \
    grep -qF 'make -C modules/qnn-soc-id-fix' <<<"$missing_lib_output"
expect 'npu-run reports the missing shim as an interpreter error, not a message' \
    bash -c '! grep -Eqi "Traceback|line [0-9]+:|command not found" <<<"$1"' \
    _ "$missing_lib_output"
expect 'npu-run without a command does not exit 2' test "$no_args_status" -eq 2
expect 'npu-run without a command does not print usage' grep -qF 'uso: npu-run' <<<"$no_args_output"

# ─── 6. o verificador nao pode aceitar um PASS via CPU ───────────────────────
expect 'verify-qnn-npu.py no longer disables the CPU execution-provider fallback' \
    grep -qF 'session.disable_cpu_ep_fallback' "$verify"

if (( failures )); then
    exit 1
fi

echo 'PASS: NPU runtime artifacts honour the firmware whitelist, shim and no-CPU-fallback contract'
