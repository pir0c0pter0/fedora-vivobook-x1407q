# X1407QA live hardware integration plan

**Goal:** make the Fedora 44 live/installer image carry the X1407QA hardware
support it advertises, using the Windows DriverStore only for firmware.

## Implementation

1. Recreate the four documented GPL kernel modules under `modules/`:
   `wcn_regulator_fix`, `vivobook_kbd_fix`, `vivobook_bl_fix`, and
   `vivobook_hotkey_fix`.
2. Build those modules with Linux 7.2 and install them in the kernel artifact
   tree before its checksum manifest is generated.
3. During ISO construction, locate the exported DriverStore, install the exact
   ADSP/CDSP/GPU/Wi-Fi firmware names into the live root, stage the DKMS sources
   under `/usr/src`, and add the early-boot/module-load configuration.
4. Let the existing Anaconda launcher recognize the EROFS live path through
   `/run/initramfs/livedev`.
5. Boot the default live entry with `rd.live.ram` while reserving 4 GiB, and
   retain an explicit USB-backed fallback entry.
6. Verify source contracts, module compilation, initramfs contents, and the
   repacked ISO contents. Physical key, display, and Wi-Fi checks remain a
   required final validation on the X1407QA.

