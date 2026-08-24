# Memória completa — s2idle, tampa e áudio no sistema instalado (2026-08-24)

Sessão remota: PC de build (x86) → SSH `mariostjr@192.168.31.240` (X1407QA,
sistema **instalado**, kernel `7.2.0-x1407qa`). Todos os testes abaixo foram
físicos, no hardware real, com o usuário presente para acordar a máquina.

## 1. Ponto de partida

Ao religar o notebook, a primeira verificação mostrou o que o BUILD-STATE de
20/08 ainda dava como pendente: **o sistema instalado boota do NVMe**
(`nvme0n1p3`, btrfs subvol `root`), via entrada BLS `x1407qa-7.2.0-x1407qa`
**com linha `devicetree`** — o mecanismo blscfg do grubaa64.efi carregando DTB
a partir do disco está comprovado neste firmware INSYDE. O reparo de boot da
sessão de 21/08 estava valendo. Wi-Fi ok (a sessão inteira rodou por SSH sobre
o Wi-Fi interno).

## 2. Fase 1.5 do plano de bateria — s2idle

Plano em `docs/plans/2026-08-21-plano-cpu-bateria.md`: o dreno grande era a
tampa fechada que não suspendia (S3/deep crasha; tampa só desligava a tela,
máquina seguia a ~2.85W a noite toda).

Método:

- `echo s2idle > /sys/power/mem_sleep` (runtime, sem persistir antes de provar).
- O RTC `rtc-pm8xxx` **não tem `wakealarm`** — `rtcwake` falha com
  `Invalid argument`. Todo teste de suspend exige acordar por botão/teclado, com
  o retorno monitorado por loop de `ping` a partir do PC de build.
- Suspend disparado por `echo mem > /sys/power/state` em background via
  `nohup` (a conexão SSH cai junto).

Resultados:

| Ciclo | Disparo | Duração | Resultado |
|---|---|---|---|
| 1 | sysfs direto | ~25s | `PM: suspend entry (s2idle)` → `exit`, rc=0, Wi-Fi/BT/SSH voltaram limpos |
| 2 (medido) | sysfs direto | 27,7 min | `energy_now` 36.352.000 → 35.984.000 µWh |
| 3 | tampa física | ~48s | `Lid closed.` → suspend → `Lid opened.` → acordou sozinho |

**Medição: 0,368Wh em 27,7min = ~0,80W suspenso**, contra 2,85W idle ligado
(baseline da Fase 0). Noite de 8h de tampa fechada: ~13% da bateria de 50Wh,
antes ~46%. Único warning pós-resume: `ath11k` regulatory `-22`, cosmético.

Persistência aplicada no notebook (só depois dos 3 ciclos limpos):

- `mem_sleep_default=s2idle` na entrada BLS e no `custom.cfg`.
- `/etc/systemd/logind.conf.d/no-suspend.conf` → `HandleLidSwitch*=suspend`
  (nome do arquivo mantido para sobrescrever a config antiga).
- `systemctl unmask sleep.target suspend.target`; `hibernate.target`,
  `hybrid-sleep.target` e `suspend-then-hibernate.target` seguem masked (sem
  swap; deep/S3 segue proibido).

## 3. Áudio morto no sistema instalado — 3 causas empilhadas

A auditoria pós-resume acusou `no soundcards`. Root cause em camadas, cada uma
destampando a próxima:

1. **`snd_soc_wcd938x` não autocarregou no boot.** O modalias do device
   (`of:...qcom,wcd9385-codec`) casa com o alias do módulo e não há blacklist —
   race de coldplug. Sem o codec, a machine driver ficava em
   `deferred probe pending: WCD Capture: codec dai not found` e o barramento
   SoundWire inundava o log com `SWR CMD error`. Fix determinístico:
   `/etc/modules-load.d/vivobook-audio.conf` (mesmo padrão do scmi_cpufreq).
2. **Kernel custom sem `CONFIG_FW_LOADER_COMPRESS(_XZ)`.** Com o codec
   carregado, o card falhou em `-ENOENT` para
   `qcom/x1e80100/X1E80100-ASUS-Zenbook-A14-tplg.bin` — o linux-firmware só
   traz `.xz`, e o kernel 7.2 custom não descomprime firmware (os firmwares que
   funcionavam vinham descomprimidos do initramfs). Fix imediato: `xz -dk` do
   tplg. Fix estrutural: as duas opções habilitadas no builder do kernel.
3. **Regex UCM2 sem `Vivobook 14`.** Card registrado mas PipeWire só via
   `auto_null` (`no backend DAIs enabled ... missing UCM profile`). O fix da
   conquista 12 nunca tinha sido aplicado no sistema instalado. Aplicado o
   mesmo sed do `setup-vivobook.sh`.

Resultado: sinks Speaker/HDMI + sources Mic/Headset no PipeWire, playback real
verificado (sink em `RUNNING` durante speaker-test), erros SoundWire zerados.

## 4. Auditoria no alvo

`tools/audit-stable-hardware.sh --post-reboot` (versão nova) no notebook:
**15/16 PASS** — `lid-safety` valida o contrato novo ("lid suspends via
s2idle; hibernate-family targets remain masked") e `audio` passa pelo fallback
ALSA. Único FAIL: `battery` — artefato de rodar via sudo/SSH sem bus de sessão
(o gsettings como root lê o schema default); como usuário o valor é `true`.

## 5. Institucionalização no repo (Fase 4)

Editado com verificação separada (workflows editar→verificar):

- `setup-vivobook.sh` — step 13 vira lid=suspend s2idle
  (`configure_sleep_targets`: unmask sleep/suspend, mask família hibernate;
  alias de compatibilidade `keep_sleep_targets_masked` preservado para o
  runner de recovery); step 12 ganha o `xz -dk` idempotente do tplg e o
  `modules-load.d` do codec.
- `kernel/build-linux-7.2-x1407qa.sh` — habilita `FW_LOADER_COMPRESS` +
  `FW_LOADER_COMPRESS_XZ` após o config preparer; `verify-linux-7.2-x1407qa.sh`
  passa a exigir as duas.
- `tools/make-rootfs-installable.sh` e `tools/rescue-installed-boot.sh` —
  `mem_sleep_default=s2idle` em todas as gerações de cmdline do sistema
  instalado (BLS e custom.cfg saem da mesma variável `opts`).
- `tools/audit-stable-hardware.sh` — contrato novo de lid-safety + fallback
  ALSA no check de áudio.
- Testes — `test-stable-hardware-audit.sh` atualizado para o contrato novo;
  `test-build-regressions.sh` exige o parâmetro novo no kickstart e ganhou
  fixture completa do verifier (banner `Linux version 7.2.0-x1407qa `, configs
  exigidas, mock de rndis_host, guard USB); `test-live-hardware-contract.sh`
  ganhou tokens de `snd_soc_wcd938x`/`HandleLidSwitch=suspend` e teve **3
  contratos obsoletos corrigidos**: supplies do WCN realinhados ao
  `wcn_regulator_fix.c` commitado (os `.pre-pull.local` são backups antigos; o
  módulo é legacy e nem carrega — o boot usa `pwrseq_qcom_wcn` nativo), e os
  tokens de firmware Wi-Fi do DriverStore trocados pelo bundle
  `firmware/ath11k/WCN6855/hw2.1` + `amss.bin` pinado (commit `39dae26`).
  **Ambos os testes passam (exit 0) no PC de build.**
- Docs — README (conquista 13 reescrita, nota de áudio na 12), BUILD-STATE
  (seção 2026-08-24), plano de bateria (Fase 1.5 ✅).

## 6. Decisões de versionamento

- `windows-drivers/` (798M comprimidos) **não entra no git** — mesmo motivo
  das ISOs; o backup vive fora do controle de versão, com hash registrado no
  BUILD-STATE. Ignorado via `.gitignore`.
- Artefatos de build de módulos (`*.ko`, `*.o`, `.*.cmd`, `Module.symvers`,
  `modules.order`, `*.mod*`) e os backups `*.pre-pull.local` ignorados.
- `.claude-flow/` (estado de ferramenta) ignorado.

## 7. Pendências

- Próximo reboot do notebook valida de fábrica: autoload do áudio via
  `modules-load.d` e o cmdline com `mem_sleep_default=s2idle`.
- Fases 1–3 do plano de bateria: runtime PM PCIe, remoção de
  `pd_ignore_unused`/`clk_ignore_unused`, cap de frequência na bateria.
- Fallback opcional no check de bateria da auditoria (mesmo caso do áudio:
  sudo/SSH sem bus de sessão).
- Percentual de bateria no live segue pendência separada.
