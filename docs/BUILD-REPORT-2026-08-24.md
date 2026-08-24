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

## 5. Institucionalização no repo (Fase 4 — concluída)

Editado com verificação separada (workflows editar→verificar):

- `setup-vivobook.sh` — step 1 remove `pd_ignore_unused` das entries antigas,
  preserva `clk_ignore_unused` e força `mem_sleep_default=s2idle`; step 13 vira lid=suspend s2idle
  (`configure_sleep_targets`: unmask sleep/suspend, mask família hibernate;
  alias de compatibilidade `keep_sleep_targets_masked` preservado para o
  runner de recovery); step 12 ganha o `xz -dk` idempotente do tplg e o
  `modules-load.d` do codec.
- `kernel/build-linux-7.2-x1407qa.sh` — habilita `FW_LOADER_COMPRESS` +
  `FW_LOADER_COMPRESS_XZ` após o config preparer; `verify-linux-7.2-x1407qa.sh`
  passa a exigir as duas.
- `tools/make-rootfs-installable.sh` e `tools/rescue-installed-boot.sh` —
  `clk_ignore_unused mem_sleep_default=s2idle`, sem `pd_ignore_unused`, em
  todas as gerações de cmdline do sistema instalado (BLS e custom.cfg saem da
  mesma variável `opts`). A ISO live conserva pd+clk porque seu early boot não
  foi validado sem o guard de power domains.
- `tools/audit-stable-hardware.sh` — contrato novo de lid-safety + fallback
  ALSA no check de áudio.
- `post-install-protect.sh` — fluxo legado desativado: copiava DTB wifi-fix,
  criava entries BLS duplicadas e restaurava `pd_ignore_unused`.
- `vivobook-update.sh` — compatibilidade de boot agora valida BLS/custom.cfg,
  clk+s2idle sem pd e o contrato atual dos targets de suspend/hibernate.
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

- ~~Próximo reboot valida de fábrica~~ ✅ **validado (sessão 2)**: boot 09:18
  veio com card de áudio registrado, zero `SWR CMD error`, cmdline com
  `mem_sleep_default=s2idle` e `[s2idle]` selecionado. Auditoria 15/16; o
  único FAIL (battery) era o artefato de sessão, corrigido abaixo.
- ~~Fallback no check de bateria~~ ✅ **feito (sessão 2)**: `check_battery`
  ganhou o mesmo guard do áudio (`-S /run/user/$(id -u)/bus`); sem bus de
  sessão passa via sysfs/UPower. Teste atualizado, shellcheck limpo.
- ~~Fase 1 (runtime PM PCIe)~~ ✅ **testada, sem ganho (sessão 2)**: nenhum
  device suspende com `control=auto` (drivers sem runtime PM; NVMe já cobre
  via APST). 2.95W → 3.04W = ruído. Nada persistido; detalhe no plano.
- ~~Fase 2 (remover `pd_ignore_unused`/`clk_ignore_unused`)~~ ✅ **testada**:
  `pd_ignore_unused` removido com 16/16 PASS e ganho marginal de ~0.1–0.2W;
  sem `clk_ignore_unused` o PCIe do WCN6855 falha antes do probe, portanto clk
  permanece obrigatório. A entry fallback antiga fica até completar o soak.
- ~~Fase 3 (cap de frequência na bateria)~~ ✅ **aplicada e validada
  (sessão 2, a pedido)**: script `vivobook-battery-freq-cap` + udev rule
  `qcom-battmgr-*` — 2380800 na bateria, 2956800 plugado. Ciclo real
  desplug/replug provado nos dois sentidos, ambos automáticos. Só o objeto
  `qcom-battmgr-bat` emite uevent no plug/desplug (a primeira versão com
  match `ac|usb` nunca disparava). Governor `teo` não aplicado (medir antes).
- `tests/test-stable-hardware-audit.sh` tem 4 falhas pré-existentes no PC de
  build (idênticas no HEAD, ambientais — mocks de journalctl neste host):
  3× "journal failure is not classified as infrastructure" + "GPU accepts a
  render node whose dev attribute is unreadable". Não são regressão; limpeza
  futura.
- Review do Codex pegou bug no fallback do check de bateria: socket
  `/run/user/$UID/bus` existe em qualquer login SSH sem GNOME — trocado por
  probe real (`gnome-extensions list`), mesmo estilo do `pactl info` do
  áudio. Revalidado 16/16 no notebook.
- Percentual de bateria no live segue pendência separada.

## 8. Segunda validação pós-reboot — aceleradores e câmera

O notebook foi reiniciado novamente antes da publicação destas mudanças. No
segundo reboot limpo desta etapa, a versão atual da auditoria estável passou
16/16 e os testes
específicos produziram:

| Área | Resultado físico |
|------|------------------|
| GPU/Vulkan | Vulkan 1.4.341, Mesa 26.0.3, Turnip/Adreno X1-45; sem Lavapipe |
| Câmera RGB | autostart `enabled/active`; still XRGB8888 1920×1080 de 8.294.400 bytes; vídeo XRGB8888 1280×720, 60/60 frames a ~30 fps; PipeWire publicado; warnings não fatais descritos abaixo |
| Remoteproc | ADSP e CDSP em `running` |
| FastRPC | `/dev/fastrpc-cdsp` em `root:render 0660`; nós secure/ADSP preservados em `root:root 0600` |
| QNN | EP registra uma NPU, mas HTP falha em `QNN_BACKEND_ERROR_CANNOT_INITIALIZE` no SoC ID real `635`, inclusive como root |

O setup agora reproduz os pré-requisitos de runtime: ferramentas Vulkan e
libcamera/PipeWire, ICD Freedreno por usuário, tuning IPA do OV02C10, uaccess do
DMA heap `system`, carregamento de `system_heap` no serviço da câmera habilitado
em `graphical.target` após módulos core e display manager, e acesso
restrito ao FastRPC CDSP não seguro. `tests/test-accelerator-runtime.sh` cobre
esses arquivos e `tools/verify-qnn-npu.py` faz inferência com fallback CPU
desabilitado para impedir falso positivo.

O `ov02c10.yaml` foi carregado, mas Fedora libcamera 0.7.1 ainda avisou sobre
static properties e sensor helper ausentes. O kernel 7.2 registrou
`cam_cc_slow_ahb_clk_src`, `Lucid PLL latch failed` e
`cam_cc_pll8 failed to enable`; não houve Oops/soft lockup e still/vídeo
concluíram. O patch CAMSS que limpou esses avisos no 6.19.8 não é instalado
pelo setup atual e precisa ser reconstruído por kernel.

Conclusão operacional: GPU está concluída e câmera está funcional com warnings
conhecidos. O reboot físico confirmou teclado/touchpad antes do overlay,
auditoria 16/16 e ausência de Oops/soft lockup. Nesse mesmo boot,
`systemd-analyze` mediu 1min36.997s (3.415s da câmera) e o `firewalld` falhou em
`3/NOTIMPLEMENTED` porque `nft` retornou `Protocol not supported`; são pendências
separadas naquele momento. Mais tarde no mesmo dia, o config do kernel recebeu nftables e os
helpers conntrack exigidos pela zona FedoraWorkstation; após instalar os
módulos, `firewalld` foi validado `active/running` com o ruleset carregado. O
transporte CDSP está
concluído; aceleração NPU via QNN/HTP depende de runtime Qualcomm compatível com
X1P42100 e não deve ser marcada como funcional apenas porque o remoteproc está
online.
