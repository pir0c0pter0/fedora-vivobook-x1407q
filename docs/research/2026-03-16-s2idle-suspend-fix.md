# S2idle Suspend Fix — Pesquisa e Progresso

**Data:** 2026-03-16
**Status:** Em progresso — kernel custom com patches pronto para build, não completou por thermal shutdown durante compilação
**Kernel base:** 6.19.8-300.fc44 (SRPM disponível em `~/rpmbuild/`)

---

## Problema

Suspend (S3 deep) causa cold reboot no Snapdragon X (X1P42100). O fix atual (#13) desabilita suspend completamente — lid close só desliga tela.

## Diagnóstico realizado

### Testes de s2idle

| Teste | Resultado |
|-------|-----------|
| `echo s2idle > /sys/power/mem_sleep` + `systemctl suspend` | Entrou em s2idle, **não acordou**, power button reiniciou |
| Mesmo teste com `cpu-sleep-0` desabilitado (WFI only) | **Mesmo resultado** — não acordou nem com idle mais raso |
| `pm_test=freezer` | **OK** — congelou tasks, voltou em 5s |
| `pm_test=devices` | **OK** — suspendeu/resumiu devices, voltou |
| `pm_test=platform` | **OK** — platform ops funcionaram |
| s2idle real (sem pm_test) | **CRASH** — sempre |

### Conclusão do diagnóstico

O problema é **exclusivamente na fase de CPU idle** do s2idle. Device suspend/resume funciona perfeitamente. Quando os CPUs entram no idle loop (`s2idle_enter()`), nenhum IRQ consegue acordá-los — nem com WFI (o idle mais raso).

### Logs confirmando

Boot -1 antes do crash (cada teste):
```
PM: suspend entry (s2idle)
Filesystems sync: 0.015 seconds
(nada mais — sistema morreu aqui)
```

Boot com pm_test=devices (sucesso):
```
PM: suspend entry (s2idle)
PM: suspend debug: Waiting for 5 second(s).
PM: suspend exit
System returned from sleep operation 'suspend'.
```

## Causa raiz identificada

### 3 problemas interligados

**1. PDC wakeup mapping desabilitado no kernel**
```c
// drivers/pinctrl/qcom/pinctrl-x1e80100.c
/* TODO: Enabling PDC currently breaks GPIO interrupts */
.nwakeirq_map = 0,
```
GPIO IRQs (lid, teclado, touchpad) **não são roteados pelo PDC** para wakeup. Sem isso, nenhum GPIO pode acordar o sistema durante s2idle.

**2. PDC em modo errado (secondary controller vs pass-through)**
No X1E/X1P, o PDC pode estar em "secondary controller mode" (latches GPIO IRQs) em vez de "pass through mode" (envia direto ao GIC). O modo não pode ser lido (firmware INSYDE bloqueia), mas pode ser escrito via SCM API.

**3. System power domain sem idle state**
O DTB atual (Zenbok A14/hamoa) não tem `domain-idle-states` no `power-domain-system`. Sem isso, o PSCI firmware não sabe qual estado de idle do sistema usar, e não configura o wake path.

### Estado do DTB atual (kernel 6.19.8)

| Nível | Estado | PSCI param |
|-------|--------|-----------|
| CPU | `cpu-sleep-0` | `0x00000004` |
| Cluster | `cluster-sleep-0` | `0x01000044` |
| Cluster | `cluster-sleep-1` | `0x01000054` |
| **System** | **NENHUM** | — |

### Wakeup sources identificadas

| Device | IRQ | Tipo | PDC? |
|--------|-----|------|------|
| Lid | GPIO 92 | msmgpio Edge | Não roteado (nwakeirq_map=0) |
| Teclado | GPIO 67 | msmgpio Level | Não roteado |
| Touchpad | GPIO 3 | msmgpio Level | Não roteado |
| Power key | PMIC SPMI | pmic_arb Edge | Independente do PDC |

## Patches upstream da Qualcomm

**Autor:** Maulik Shah (maulik.shah@oss.qualcomm.com)
**Data:** 12/Mar/2026
**Série:** `[PATCH 0/5] x1e80100: Enable PDC wake GPIOs and deepest idle state`
**Message-ID:** `20260312-hamoa_pdc-v1-0-760c8593ce50@oss.qualcomm.com`
**Status:** Em review no LKML (Krzysztof Kozlowski deu feedback)

### Os 5 patches

| # | Arquivo | Descrição | Status no 6.19.8 |
|---|---------|-----------|-------------------|
| 1/5 | `hamoa.dtsi` | Remove interconnect do SCM | **Já aplicado** no Fedora |
| 2/5 | `qcom,pdc.yaml` | Documenta 3º reg PDC e QMP | Documentação only |
| 3/5 | `drivers/irqchip/qcom-pdc.c` | **Configura PDC pass-through via SCM** + IRQ masking v3.0 | Precisa aplicar |
| 4/5 | `hamoa.dtsi` | **Adiciona domain_ss3 idle state** + 3º reg PDC + QMP | Precisa aplicar |
| 5/5 | `drivers/pinctrl/qcom/pinctrl-x1e80100.c` | **Re-habilita PDC wakeup mapping** | Precisa aplicar |

### Links LKML

- Cover letter: https://lore.kernel.org/linux-arm-msm/20260312-hamoa_pdc-v1-0-760c8593ce50@oss.qualcomm.com/
- Patch 1: https://lore.kernel.org/linux-arm-msm/20260312-hamoa_pdc-v1-1-760c8593ce50@oss.qualcomm.com/
- Patch 2: https://lore.kernel.org/linux-arm-msm/20260312-hamoa_pdc-v1-2-760c8593ce50@oss.qualcomm.com/
- Patch 3: https://lore.kernel.org/linux-arm-msm/20260312-hamoa_pdc-v1-3-760c8593ce50@oss.qualcomm.com/
- Patch 4: https://lore.kernel.org/linux-arm-msm/20260312-hamoa_pdc-v1-4-760c8593ce50@oss.qualcomm.com/
- Patch 5: https://lore.kernel.org/linux-arm-msm/20260312-hamoa_pdc-v1-5-760c8593ce50@oss.qualcomm.com/

### Bug Ubuntu relacionado

- https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2127013
- ThinkPad T14s Gen 6 (mesmo SoC) — s2idle faz immediate resume

## Solução: Kernel custom com patches

### Patch combinado criado

**Arquivo:** `~/rpmbuild/SOURCES/s2idle-combined-qualcomm-pdc-idle.patch`

Combina patches 3, 4 e 5 (patch 1 já no Fedora, patch 2 é doc only) adaptado para o kernel 6.19.8:

**Mudanças em 3 arquivos:**

1. **`arch/arm64/boot/dts/qcom/hamoa.dtsi`**
   - Adiciona `domain_ss3: domain-sleep-0` com PSCI param `0x0200c354`
   - Seta `domain-idle-states = <&domain_ss3>` no system power domain
   - Adiciona 3º registro PDC `<0 0x0b2045e8 0 0x4>` e `qcom,qmp = <&aoss_qmp>`

2. **`drivers/irqchip/qcom-pdc.c`**
   - Adiciona `__pdc_mask_intr()` para masking de IRQs em PDC v3.0+
   - Configura PDC pass-through mode via `qcom_scm_io_writel()`
   - Fallback graceful se SCM write falhar (usa MPM wakeup)
   - Remove dependência de QMP (QCOM_AOSS_QMP é módulo, PDC é built-in)

3. **`drivers/pinctrl/qcom/pinctrl-x1e80100.c`**
   - Re-habilita PDC wakeup: `.nwakeirq_map = ARRAY_SIZE(x1e80100_pdc_map)`

### Kernel spec modificado

**Arquivo:** `~/rpmbuild/SPECS/kernel.spec`

- `buildid` setado para `.s2idle` → kernel fica `6.19.8-300.s2idle.fc44.aarch64`
- Patch `s2idle-combined-qualcomm-pdc-idle.patch` adicionado e aplicado
- Verificado: patches aplicam sem erros na fase `%prep`

### Build issues encontrados e resolvidos

| Issue | Causa | Solução |
|-------|-------|---------|
| Patch 1 não aplicou | Já estava no Fedora 6.19.8 | Removido do patch combinado |
| Config mismatch QCOM_PDC=m vs =y | `depends on QCOM_AOSS_QMP` (=m) forçava PDC=m | Removida dependência Kconfig |
| Linker error qmp_get/send/put | QCOM_AOSS_QMP é módulo, PDC é built-in | Removido código QMP, só usa qcom_scm (built-in) |
| Thermal shutdown durante build | 8 cores a 100% por 40+ min superaquece | **Não resolvido** — usar `-j4` na próxima build |

## Próximos passos

### Para completar a build

```bash
# Limpar build anterior
rm -rf ~/rpmbuild/BUILD/kernel-6.19.8-build

# Rebuildar com 4 cores (evitar thermal shutdown)
# Editar kernel.spec: trocar -j8 por -j4, ou:
rpmbuild -bb --target=aarch64 \
  --without debug \
  --without debuginfo \
  --without doc \
  --without perf \
  --without tools \
  --without bpftool \
  --without selftests \
  --without cross_headers \
  --define '_smp_mflags -j4' \
  ~/rpmbuild/SPECS/kernel.spec
```

### Após build completar

```bash
# Instalar novo kernel (lado a lado com o atual)
sudo dnf install ~/rpmbuild/RPMS/aarch64/kernel-*6.19.8-300.s2idle*.rpm

# Rebuild DKMS modules contra novo kernel
sudo dkms autoinstall -k 6.19.8-300.s2idle.fc44.aarch64

# Rebootar no novo kernel
sudo reboot

# Testar s2idle
echo s2idle | sudo tee /sys/power/mem_sleep
sudo systemctl unmask suspend.target sleep.target
sudo systemctl suspend
```

### Se s2idle funcionar

1. Configurar como padrão:
   - Adicionar `mem_sleep_default=s2idle` ao GRUB
   - Mudar logind `HandleLidSwitch=suspend`
   - Desmascarar `suspend.target` e `sleep.target`
   - Manter mascarados: `hibernate.target`, `hybrid-sleep.target`, `suspend-then-hibernate.target`
2. Atualizar setup-vivobook.sh, build-vivobook-iso.sh, vivobook-update.sh
3. Atualizar README.md — achievement #13 de "workaround" para "fix real"

### Alternativa: Esperar kernel 7.0

O próximo kernel major é **7.0** (esperado Abril 2026). Se os patches da Qualcomm forem mergeados a tempo, s2idle pode funcionar out-of-the-box sem kernel custom.

## Referências

- [LKML: x1e80100 deepest idle state patch](https://lkml.org/lkml/2026/3/13/1521)
- [Ubuntu Bug: ThinkPad T14s Gen 6 suspend](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2127013)
- [Qualcomm: Upstreaming Linux for Snapdragon X Elite](https://www.qualcomm.com/developer/blog/2024/05/upstreaming-linux-kernel-support-for-the-snapdragon-x-elite)
- [Linaro: Linux on Snapdragon X Elite](https://www.linaro.org/blog/linux-on-snapdragon-x-elite/)
