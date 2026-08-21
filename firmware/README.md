# Bundled proprietary firmware

Files below `firmware/` mirror their destination under `/usr/lib/firmware`.
They are copied by `setup-vivobook.sh` and bundled into custom installation
media by `build-vivobook-iso.sh`.

The WCN6855 hw2.1 files came from this machine's Windows DriverStore package:

`qcwlanhsp8380.inf_arm64_417e5fdb5950602f`

| Destination file | DriverStore source | SHA-256 |
|---|---|---|
| `ath11k/WCN6855/hw2.1/amss.bin` | `wlanfw20.mbn` | `00756e19aee2b5e6725f5029b7e6abea748caca0f53af5a7662cd32086dde4bd` |
| `ath11k/WCN6855/hw2.1/board.bin` | `bdwlan_wcn685x_2p1_nfa765a_AS_SA_X14QA.elf` | `aea74372b997b7b55c76c786b02f4670922489353923ef7d4a48dc83780f2c86` |
| `ath11k/WCN6855/hw2.1/m3.bin` | `m3.bin` (`m320.bin` is identical) | `9be43a8d9dc9454a629d65368df7ccd532d8768a0ac1fd935f57bcd37cbefecd` |
| `ath11k/WCN6855/hw2.1/regdb.bin` | `regdb.bin` | `f3930af4bb8d2e23737a1ba4c68fa297652fd9e256851245f72d0bc660074936` |

These files are proprietary Qualcomm/ASUS firmware. They are not covered by
the repository's MIT license. No source code or permission to relicense them
is implied by their inclusion.
