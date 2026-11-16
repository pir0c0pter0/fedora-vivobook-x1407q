"""Run each menu entry of grub-yoga.cfg against mocked GRUB commands; syntax is checked by grub2-script-check."""
from pathlib import Path
import re
import subprocess

cfg = Path(__file__).with_name("grub-yoga.cfg").read_text()
functions = cfg[cfg.index("function yoga_gate"):cfg.index("\nmenuentry ")]
# GRUB device notation is the only syntax in these functions Bash cannot parse.
functions = functions.replace("($root)", "${root}").replace("($yoga_esp)", "${yoga_esp}")
stubs = """
set() { export "$1"; }
step() { echo "CALL:$1"; [ "$1" != "$FAIL" ]; }
search() { step SEARCH; }
linux() { echo "ARGS:$*"; step LINUX; }
devicetree() { echo "DTB:$*"; step DEVICETREE; }
initrd() { echo "INITRD:$*"; step INITRD; }
sleep() { exit 70; }
boot() { echo CALL:BOOT; exit 0; }
"""
# name: (acpi, dtb on ESP or None, live root, earlycon kept, extra initrd archive or None)
expected = {
    "G3": ("off", "kalambo-g1.dtb", True, False, "yoga-updates.cpio"),
    "W6": ("off", "kalambo-gw1a.dtb", True, False, "yoga-updates.cpio"),
    "N1": ("off", "kalambo-gwn1.dtb", True, False, "yoga-updates.cpio"),
    "G4": ("off", "kalambo-gu2.dtb", True, False, "yoga-updates.cpio"),
    "G1": ("off", "kalambo-g1.dtb", False, True, None),
    "W5": ("off", "kalambo-gw1a.dtb", False, True, "yoga-wifi-extra.cpio"),
    "U2": ("off", "kalambo-u2.dtb", False, True, None),
    "U3": ("off", "kalambo-u3.dtb", False, True, None),
    "L1": ("force", None, True, True, None),
}
entries = dict(re.findall(r"menuentry '(\w\d)\. [^']*' \{\n(.*?)\n\}", cfg, re.S))
assert entries.keys() == expected.keys(), sorted(entries)
for name, body in entries.items():
    acpi, dtb, live, earlycon, extra = expected[name]
    for failure in ("", "INITRD"):
        result = subprocess.run(["bash", "-c", stubs + functions + f"\nFAIL={failure}\n{body}"],
                                capture_output=True, text=True, timeout=5)
        out = result.stdout.splitlines()
        if failure:  # a failed load must never reach boot
            assert result.returncode == 70 and "CALL:BOOT" not in out, result
            continue
        assert result.returncode == 0 and out[-1] == "CALL:BOOT", result
        args = next(line[5:] for line in out if line.startswith("ARGS:")).split()
        initrd = next(line for line in out if line.startswith("INITRD:"))
        dtbs = [line for line in out if line.startswith("DTB:")]
        assert f"acpi={acpi}" in args and "efi=noruntime" in args, (name, args)
        assert ("earlycon=efifb,ram" in args) == ("keep_bootcon" in args) == earlycon, (name, args)
        assert not any(a in ('""', "''") for a in args), args
        assert [d.rsplit("/", 1)[-1] for d in dtbs] == ([dtb] if dtb else []), (name, dtbs)
        assert ("live-root.cpio" in initrd) == live, (name, initrd)
        assert [x for x in ("yoga-updates.cpio", "yoga-wifi-extra.cpio") if x in initrd] == ([extra] if extra else []), (name, initrd)
        if not live:  # shell entries must not try the live root
            assert "root=LABEL=YOGA-NADA" in args and "rd.shell=1" in args, (name, args)
print(f"PASS: {len(entries)} entries")
