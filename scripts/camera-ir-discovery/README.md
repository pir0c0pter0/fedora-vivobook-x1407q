# Camera IR Discovery Scripts

Throwaway pipeline to extract IR camera (HM1092) power mapping from the
Asus BIOS `.cap` file. Run in numbered order:

1. `01-fetch-bios.sh` — download (or user-provides) the Asus BIOS
2. `02-unpack-uefi.sh` — unpack with UEFIExtract, fallback binwalk
3. `03-find-camera-artifacts.sh` — binary grep for CAMI/HM1092/AeoB/DSDT
4. `04-parse-dsdt.sh` — decompile DSDT, extract CAMI device block
5. `05-decompile-aeob.sh` — parse AeoB firmware, compare vs MTP baseline

Output workspace: `/tmp/x1407qa-bios/`
Final findings: `docs/research/2026-04-11-ir-camera-discovery.md`

Not intended for reuse — delete after Phase 1 complete.
