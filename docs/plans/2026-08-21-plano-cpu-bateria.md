# Plano — consumo de bateria / gerenciador de CPU (2026-08-21)

Estado coletado via SSH no X1407QA (kernel 7.2.0-x1407qa, boot ok, WiFi ok):

| Item | Estado | Veredito |
|---|---|---|
| Governor | schedutil nas 2 policies (cpu0-3, cpu4-7) | Correto, não é o vilão |
| cpuidle | Só WFI + cpu-sleep-0, governor menu | Limitado pelo DTB Zenbook — sem estados de cluster |
| cmdline | `clk_ignore_unused pd_ignore_unused` | **Suspeito nº 1** — mantém TODOS os clocks e power domains não usados ligados 100% do tempo |
| Runtime PM PCIe | `power/control = on` nos 4 devices (root ports + WiFi + NVMe) | **Suspeito nº 2** — links nunca suspendem |
| ASPM | L1 habilitado em todos os links | Ok |
| WiFi power save | on | Ok |
| NVMe APST | auto, 100ms | Ok |
| EAS | ausente (8 cores simétricos) | Não se aplica |
| Bateria | power_now 24.8W **carregando** | Baseline real só em descarga |

## Fase 0 — Baseline ✅ MEDIDA (2026-08-21)

Na bateria, tela ligada, brilho 1256/4095, idle, 60 amostras × 5s:
**média 2.85W (min 2.62 / max 3.25)** → ~17h de autonomia idle com 50Wh.

**Conclusão: o consumo idle é saudável — o gerenciador de CPU não é o vilão.**
O dreno percebido tem outra origem, em ordem de probabilidade:

1. **Tampa fechada não suspende** (S3 desabilitado por crash conhecido — a tampa
   só desliga a tela). A máquina segue a ~2–2.5W: **~25–50% de bateria por
   noite de tampa fechada.** Esse é o dreno grande.
2. Consumo sob carga real (browser/vídeo) — medir numa sessão de uso.

## Fase 1.5 — Tampa fechada ✅ CONCLUÍDA (2026-08-24)

**Resultado: s2idle FUNCIONA** (validado no sistema instalado, kernel
7.2.0-x1407qa): 2 ciclos suspend/resume limpos (`PM: suspend entry (s2idle)`
→ exit), WiFi/BT/teclado/áudio ok após resume. Consumo suspenso medido:
0.368Wh em 27.7min = **~0.80W** (vs 2.85W idle ligado). Persistido na
máquina: `mem_sleep_default=s2idle` no cmdline (BLS + `custom.cfg`), logind
`HandleLidSwitch=suspend`, `sleep.target`/`suspend.target` desmascarados
(hibernate continua masked — sem swap). deep continua proibido. O RTC pm8xxx
não tem `wakealarm` — acordar é sempre por botão/tampa; o item 2 (hibernate)
não foi necessário. **Fases 1–3 seguem abertas.**

Estado verificado via SSH (2026-08-21): `mem_sleep = s2idle [deep]` — o
default é **deep**, que é o modo que crasha. **s2idle existe e provavelmente
nunca foi testado.** `/sys/power/disk = [shutdown]` (hibernate suportado pelo
kernel), mas `/proc/swaps` vazio — hibernate exigiria criar swapfile.
`suspend.target`/`hibernate.target` estão masked (fix da conquista 13).

1. **s2idle** (barato, testar primeiro): é suspend raso — freeze + runtime PM,
   não passa pelo caminho de firmware que crasha no deep.
   ```bash
   echo s2idle | sudo tee /sys/power/mem_sleep
   sudo systemctl unmask suspend.target sleep.target
   systemctl suspend   # com trabalho salvo; risco de travar → poweroff forçado
   ```
   Acordou bem (teclado/WiFi/tela ok, audit 16/16)? → persistir
   `mem_sleep_default=s2idle` no cmdline + lid=suspend, e medir o consumo
   suspenso (esperado <1W vs 2.85W ligado).
2. **Hibernate** (fallback se s2idle falhar): poweroff completo com imagem de
   resume, 0W de tampa fechada. Requer swapfile btrfs (`chattr +C`, sem CoW),
   `resume=`/`resume_offset=` no cmdline e unmask do hibernate.target.

Qualquer resultado (inclusive s2idle crashando) → documentar no README.

## Fase 1 — Runtime PM PCIe ✅ TESTADA — SEM GANHO (2026-08-24)

**Resultado: no-op neste kernel.** `control=auto` aplicado nos 4 devices
(root ports, NVMe e por fim WiFi isolado) e **nenhum jamais saiu de
`runtime_status=active`** — sem erro MHI/RDDM, sem regressão, mas também sem
suspend. Consumo medido na bateria, idle: baseline 2.95W → com auto 3.04W
(ruído). Causa: os drivers não fazem runtime suspend — ath11k não implementa
runtime PM, o NVMe já economiza via **APST (habilitado, 100ms)** sem depender
de D3, e os root ports ficam presos pelos filhos ativos
(`autosuspend_delay_ms` retorna -EIO = autosuspend nunca armado pelos
drivers). Controls revertidos para `on`; **nada persistido** — udev rule
seria clutter sem efeito. Não re-testar sem mudança de kernel/driver.

## Fase 2 — Remover `pd_ignore_unused` / `clk_ignore_unused` (maior ganho potencial, maior risco)

Esses flags são dreno constante desde o boot. Teste controlado:

1. Entry GRUB de TESTE (manter a atual `08_vivobook` intacta como fallback).
2. Remover só `pd_ignore_unused` primeiro. **Full poweroff** entre testes (regra do projeto: rails always-on sobrevivem warm reboot).
3. Validar: `tools/audit-stable-hardware.sh --post-reboot` 16/16 + WiFi + áudio + brilho + teclado.
4. Passou → repetir removendo também `clk_ignore_unused`.
5. Qualquer quebra → voltar pro fallback e registrar QUAL subsistema quebrou (isso vira dado pra proteger o domínio específico no futuro).

## Fase 3 — cpufreq na bateria ✅ APLICADA (2026-08-24)

- Cap aplicado: `/usr/local/bin/vivobook-battery-freq-cap` +
  `/etc/udev/rules.d/99-battery-freq-cap.rules` (match `qcom-battmgr-*` +
  coldplug no boot). Na bateria `scaling_max_freq=2380800` (maior OPP
  ≤2.4GHz), no AC/USB 2956800. **Validado com ciclo real desplug/replug**:
  desplug → 2380800 automático, plug (USB-C, `qcom-battmgr-usb` online) →
  2956800 automático. Detalhe descoberto no teste: só o objeto
  `qcom-battmgr-bat` emite uevent de change no plug/desplug — os objetos
  ac/usb ficam mudos, por isso o match estreito `ac|usb` da primeira versão
  nunca disparava.
- Idle governor `menu` → `teo` (`cpuidle.governor=teo`): **não aplicado** —
  marginal, medir antes de manter.

## Fase 4 — Institucionalizar

- Congelar o que ganhou: udev rules + entry GRUB definitiva em `/etc/grub.d/08_vivobook`.
- Atualizar `setup-vivobook.sh`, README (Problema → Causa raiz → Solução → tabela) e adicionar teste em `tests/`.
- Registrar os números (antes/depois em W) no BUILD-STATE.md.

## Fora de alcance por enquanto

- Estados profundos de cpuidle (cluster sleep): dependem do DTB — override de DTB é proibido no INSYDE (7 métodos já falharam).
- Suspend S3 (deep): continua desabilitado por crash conhecido; a tampa agora
  suspende via s2idle (Fase 1.5).
