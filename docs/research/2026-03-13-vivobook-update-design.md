# Design: vivobook-update.sh

**Data:** 2026-03-13
**Tipo:** Script Bash interativo de update seguro para ASUS Vivobook X1407QA (Snapdragon X)

---

## Problema

Auto-updates estão desabilitados porque kernel/mesa/gnome-shell/firmware updates podem quebrar os 16 fixes de hardware (5 módulos DKMS, 1 LD_PRELOAD Vulkan, 1 extensão GNOME, 1 UCM2 áudio, configs dracut/udev). O usuário precisa de um script que analise cada update sensível antes de aplicar.

## Decisões de design

| Decisão | Escolha |
|---------|---------|
| Modo de execução | Interativo — roda manual via `sudo vivobook-update` |
| Gerenciador de pacotes | dnf puro (Fedora 44) |
| Análise de compatibilidade | DKMS dry-run + API header check + vk_pool_fix.so symbol check |
| Changelog | dnf changelog + release notes upstream via curl |
| Pacotes sensíveis | kernel*, mesa*, alsa-ucm-conf, gnome-shell, gtk4*, systemd*, grub2-*, firmware qcom |
| Linguagem | Bash monolítico (~550-600 linhas) |
| Error handling | `set -uo pipefail` + checks explícitos em comandos críticos (sem `set -e`) |
| Abordagem pós-update | Rebuild automático de initramfs/DKMS se necessário |

---

## Arquitetura

### Fluxo principal

```
vivobook-update.sh
│
├─ 1. PREFLIGHT
│  ├─ Verifica root (sudo)
│  ├─ Verifica conexão internet (ping)
│  └─ Verifica dnf lock (não rodar se outro dnf ativo)
│
├─ 2. DISCOVERY
│  ├─ dnf check-update → lista raw
│  ├─ Classifica: sensível vs normal
│  │  ├─ Match por nome: kernel*, mesa*, gnome-shell, gtk4*, alsa-ucm-conf, systemd*, grub2-*
│  │  └─ Match por conteúdo: dnf repoquery -l | grep firmware/qcom
│  └─ Mostra resumo (X normais, Y sensíveis)
│
├─ 3. NORMAIS
│  ├─ Lista pacotes normais
│  ├─ Pergunta S/n
│  └─ dnf update <lista> --exclude=<sensíveis>
│
├─ 4. SENSÍVEIS (loop por pacote)
│  ├─ 4a. Changelog RPM (dnf changelog --upgrades)
│  ├─ 4b. Release notes upstream (curl)
│  ├─ 4c. Análise de compatibilidade (por tipo)
│  ├─ 4d. Mostra relatório
│  └─ 4e. Pergunta S/n/d(etalhe)
│
├─ 5. APPLY
│  ├─ dnf update <sensíveis aceitos>
│  └─ Se falhar → rollback info
│
├─ 6. POST-UPDATE
│  ├─ Se kernel atualizado → dkms autoinstall + rebuild initramfs
│  ├─ Se mesa atualizado → testar vk_pool_fix.so (ldd + nm)
│  ├─ Se gnome-shell atualizado → checar extensão habilitada
│  ├─ Se alsa-ucm-conf atualizado → verificar regex Vivobook
│  ├─ Se firmware qcom atualizado → rebuild initramfs
│  ├─ Se systemd atualizado → verificar logind config + suspend masks + udev rules
│  ├─ Se grub2 atualizado → verificar 08_vivobook + kernel params
│  ├─ Sempre → verificar scmi_cpufreq no módulo tree do kernel
│  └─ Mostra resumo final
│
└─ 7. REPORT
   └─ Salva log em /var/log/vivobook-update/<timestamp>.log
```

---

## Componentes detalhados

### 1. Preflight

```bash
check_root()          # [[ $EUID -ne 0 ]] && erro
check_internet()      # curl -sf --max-time 5 https://fedoraproject.org > /dev/null
check_dnf_lock()      # Checa lock files: /var/run/dnf/lock, /var/cache/dnf/metadata_lock.pid
                      # + pgrep -x "dnf|dnf5|packagekitd"
```

Sem internet: avisa que release notes upstream não estarão disponíveis, mas permite continuar (changelog RPM funciona offline).

### 2. Discovery — Classificação de pacotes

**Constantes (lista de padrões sensíveis):**
```bash
SENSITIVE_PATTERNS=(
    "^kernel"
    "^mesa"
    "^gnome-shell$"
    "^gtk4"
    "^alsa-ucm-conf$"
    "^systemd"
    "^grub2"
)
```

**Detecção de firmware qcom:**
Para cada pacote no `dnf check-update`, se não matchou por nome, checa:
```bash
dnf repoquery -l "$pkg_nevra" 2>/dev/null | grep -q "firmware/qcom" && is_sensitive=true
```

**Otimização:** A checagem de firmware é cara (rpm -ql por pacote). Só roda para pacotes que contenham "firmware" ou "linux-firmware" no nome, evitando overhead nos 90% de pacotes irrelevantes.

### 3. Pacotes normais

Fluxo direto:
- Lista formatada com versão atual → nova
- Prompt `[S/n]`
- Executa `dnf update -y <lista_normais>`
- Se o usuário rejeitar, os normais são pulados e segue para sensíveis

### 4. Análise de pacotes sensíveis

#### 4a. Changelog RPM

```bash
get_rpm_changelog() {
    dnf changelog --upgrades "$pkg" 2>/dev/null | head -60
}
```

Trunca em 60 linhas. Opção `d` no prompt expande completo via `less`.

#### 4b. Release notes upstream

Mapa de URLs por pacote:

| Pacote | URL template | Parsing |
|--------|-------------|---------|
| kernel | `https://cdn.kernel.org/pub/linux/kernel/v${major}.x/ChangeLog-${version}` | head -80 |
| mesa | `https://docs.mesa3d.org/relnotes/${version}.html` | sed: extrai entre `<h2>` de highlights |
| gnome-shell | `https://gitlab.gnome.org/GNOME/gnome-shell/-/raw/main/NEWS` | sed: extrai bloco da versão |
| gtk4 | `https://gitlab.gnome.org/GNOME/gtk/-/raw/main/NEWS` | sed: extrai bloco da versão |
| alsa-ucm-conf | `https://raw.githubusercontent.com/alsa-project/alsa-ucm-conf/master/NEWS` | grep seção |
| firmware | Sem URL — só changelog RPM | — |

**Timeout:** `curl --max-time 10` por request. Falha silenciosa com mensagem `[Indisponível]`.

#### 4c. Análise de compatibilidade por tipo

##### Kernel

**DKMS dry-run:**
```bash
check_kernel_dkms() {
    local new_kernel="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    # Baixa kernel-devel sem instalar, extrai headers em tmpdir
    dnf download "kernel-devel-${new_kernel}" --destdir="$tmpdir" || {
        echo "❌ Não foi possível baixar kernel-devel-${new_kernel}"
        return 1
    }
    (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

    # 4 módulos DKMS de produção (vivobook-cam-fix é experimental, NÃO incluir)
    local modules=(wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix
                   vivobook-hotkey-fix)
    local failed=()

    for mod in "${modules[@]}"; do
        local ver
        ver=$(dkms status "$mod" | head -1 | awk -F'[,/]' '{print $2}' | tr -d ' ')
        if ! dkms build "${mod}/${ver}" -k "$new_kernel" 2>/tmp/dkms_err; then
            failed+=("$mod")
        fi
    done

    rm -rf "$tmpdir"
    # Reporta resultado
}
```

**Nota:** O kernel-devel é baixado e extraído num tmpdir para análise de headers (API check). NÃO é instalado durante a fase de análise — side-effect free. O `dkms build` usa os headers do kernel-devel já instalado para o kernel atual como fallback; o resultado real é validado pós-install pelo `dkms autoinstall`.

**API check:**
```bash
check_kernel_api() {
    local new_kernel="$1"
    local headers="/usr/src/kernels/${new_kernel}"

    # Funções que nossos módulos usam
    local functions=(
        "i2c_hid_core_probe"
        "irq_create_fwspec_mapping"
        "spmi_register_read"
        "of_overlay_fdt_apply"
        "regulator_get"
        "pci_rescan_bus"
        "backlight_device_register"
        "hid_hw_start"
    )

    for func in "${functions[@]}"; do
        if ! grep -rq "$func" "$headers/include/"; then
            echo "⚠️  $func não encontrado nos headers do kernel $new_kernel"
        fi
    done
}
```

**Parsing da versão do kernel:** O `dnf check-update` retorna formato `kernel-core.aarch64  6.20.1-300.fc44  updates`. A versão para DKMS é `6.20.1-300.fc44.aarch64`. O script extrai com: `<version>-<release>.<arch>` parseado do output do dnf.

##### Mesa

```bash
check_mesa_compat() {
    local pkg="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    # Baixa RPM sem instalar
    dnf download "$pkg" --destdir="$tmpdir"

    # Extrai .so (subshell para não mudar cwd do script)
    (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

    # Checa símbolo
    local vulkan_so
    vulkan_so=$(find "$tmpdir" -name "libvulkan_freedreno.so" -o -name "libvulkan_*.so" | head -1)

    if [[ -n "$vulkan_so" ]]; then
        if objdump -T "$vulkan_so" | grep -q "vkCreateDescriptorPool"; then
            echo "✅ vkCreateDescriptorPool presente"
        else
            echo "❌ vkCreateDescriptorPool NÃO encontrado — vk_pool_fix.so vai quebrar"
        fi
    fi

    rm -rf "$tmpdir"
}
```

##### GNOME Shell

```bash
check_gnome_compat() {
    local new_version="$1"
    local major="${new_version%%.*}"
    local metadata="$HOME/.local/share/gnome-shell/extensions/battery-time@wifiteste/metadata.json"

    if [[ -f "$metadata" ]]; then
        if grep -q "\"${major}\"" "$metadata"; then
            echo "✅ Extensão battery-time suporta GNOME $major"
        else
            echo "⚠️  Extensão battery-time lista shell-version: $(grep shell-version "$metadata")"
            echo "   GNOME $major pode desabilitar a extensão"
        fi
    fi
}
```

##### GTK4

```bash
check_gtk4_compat() {
    local changelog="$1"  # conteúdo do changelog já obtido

    if echo "$changelog" | grep -qi "vulkan\|descriptor\|GSK.*render"; then
        echo "⚠️  Changelog menciona mudanças Vulkan/GSK — testar vk_pool_fix.so após update"
    else
        echo "✅ Sem mudanças Vulkan/GSK detectadas no changelog"
    fi
}
```

##### alsa-ucm-conf

```bash
check_ucm_compat() {
    local pkg="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    dnf download "$pkg" --destdir="$tmpdir"
    (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

    local conf
    conf=$(find "$tmpdir" -path "*/x1e80100/x1e80100.conf" | head -1)

    if [[ -n "$conf" ]]; then
        if grep -qi "vivobook" "$conf"; then
            echo "✅ Vivobook presente no regex UCM2"
        else
            echo "⚠️  Vivobook NÃO encontrado no regex — áudio pode quebrar"
            echo "   Precisará re-aplicar patch UCM2 após update"
        fi
    fi

    rm -rf "$tmpdir"
}
```

##### Firmware qcom

```bash
check_firmware_compat() {
    local pkg="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    dnf download "$pkg" --destdir="$tmpdir"
    (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

    # Firmwares que usamos
    local our_fw=(
        "qcadsp8380.mbn" "adsp_dtbs.elf"
        "qccdsp8380.mbn" "cdsp_dtbs.elf"
        "gen71500_sqe.fw" "gen71500_gmu.bin"
        "qcdxkmsucpurwa.mbn"
    )

    local changed=()
    for fw in "${our_fw[@]}"; do
        local new_file
        new_file=$(find "$tmpdir" -name "$fw*" | head -1)
        local installed="/usr/lib/firmware/qcom/$(find /usr/lib/firmware/qcom -name "$fw*" -printf '%P\n' | head -1)"

        if [[ -z "$new_file" ]]; then
            continue
        fi
        if [[ ! -f "$installed" ]]; then
            changed+=("$fw (NOVO)")
            continue
        fi
        if ! cmp -s "$new_file" "$installed"; then
            changed+=("$fw")
        fi
    done

    if [[ ${#changed[@]} -gt 0 ]]; then
        echo "⚠️  Firmwares alterados: ${changed[*]}"
        echo "   Rebuild initramfs necessário após update"
    else
        echo "✅ Nenhum firmware que usamos mudou"
    fi

    rm -rf "$tmpdir"
}
```

### 5. Apply

```bash
apply_sensitive_updates() {
    local accepted=("$@")

    if [[ ${#accepted[@]} -eq 0 ]]; then
        echo "Nenhum pacote sensível selecionado."
        return 0
    fi

    echo "Instalando: ${accepted[*]}"
    dnf update -y "${accepted[@]}"
}
```

### 6. Post-update

Roda automaticamente após os updates serem aplicados:

```bash
post_update() {
    local updated_kernel="$1"    # vazio se kernel não foi atualizado
    local updated_mesa="$2"      # "true"/"false"
    local updated_firmware="$3"  # "true"/"false"
    local need_initramfs=false

    # DKMS autoinstall para novo kernel
    if [[ -n "$updated_kernel" ]]; then
        echo "Rebuilding DKMS modules para kernel $updated_kernel..."
        dkms autoinstall -k "$updated_kernel"
        need_initramfs=true
    fi

    # Rebuild initramfs se kernel ou firmware mudou
    if [[ "$updated_firmware" == "true" ]]; then
        need_initramfs=true
    fi

    if [[ "$need_initramfs" == "true" ]]; then
        echo "Rebuilding initramfs..."
        if [[ -n "$updated_kernel" ]]; then
            dracut --force "/boot/initramfs-${updated_kernel}.img" "$updated_kernel"
        else
            dracut --force
        fi
    fi

    # Verifica vk_pool_fix.so
    if [[ "$updated_mesa" == "true" ]]; then
        echo "Verificando vk_pool_fix.so..."
        if ldd /usr/local/lib64/vk_pool_fix.so 2>&1 | grep -q "not found"; then
            echo "⚠️  vk_pool_fix.so tem dependências faltando — recompilar!"
            echo "   gcc -shared -fPIC -o /usr/local/lib64/vk_pool_fix.so vk_pool_fix.c -ldl"
        fi
    fi

    # GRUB update se kernel mudou
    if [[ -n "$updated_kernel" ]]; then
        # Verifica custom GRUB entry antes de regenerar
        if [[ ! -f /etc/grub.d/08_vivobook ]]; then
            echo "⚠️  /etc/grub.d/08_vivobook ausente! Restaurar antes de regenerar GRUB"
        fi
        if ! grep -q "clk_ignore_unused" /etc/default/grub 2>/dev/null; then
            echo "⚠️  clk_ignore_unused ausente em /etc/default/grub!"
        fi
        echo "Atualizando GRUB..."
        grub2-mkconfig -o /boot/grub2/grub.cfg

        # Verifica scmi_cpufreq no novo kernel
        if ! find /lib/modules/"$updated_kernel" -name "scmi_cpufreq.ko*" | grep -q .; then
            echo "⚠️  scmi_cpufreq não encontrado no kernel $updated_kernel — cpufreq pode não funcionar"
        fi
    fi

    # Verifica integridade dos configs que outros pacotes podem sobrescrever
    verify_system_configs
}

verify_system_configs() {
    local issues=0

    # logind config (pode ser resetado por update de systemd)
    if [[ ! -f /etc/systemd/logind.conf.d/no-suspend.conf ]]; then
        echo "⚠️  logind no-suspend.conf ausente! Suspend pode crashar o sistema"
        ((issues++))
    fi

    # Suspend masks
    if [[ ! -L /etc/systemd/system/suspend.target ]]; then
        echo "⚠️  suspend.target não está masked!"
        ((issues++))
    fi

    # udev charge control
    if [[ ! -f /etc/udev/rules.d/99-battery-charge-limit.rules ]]; then
        echo "⚠️  udev rule de charge control ausente!"
        ((issues++))
    fi

    # modules-load.d
    for conf in wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix scmi-cpufreq; do
        if [[ ! -f "/etc/modules-load.d/${conf}.conf" ]]; then
            echo "⚠️  /etc/modules-load.d/${conf}.conf ausente!"
            ((issues++))
        fi
    done

    if [[ $issues -eq 0 ]]; then
        echo "✅ Configs do sistema intactos"
    else
        echo "⚠️  $issues config(s) precisam de atenção — rodar setup-all.sh para restaurar"
    fi
}
```

### 7. Report — Log

```bash
LOG_DIR="/var/log/vivobook-update"
LOG_FILE="${LOG_DIR}/$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

# Função de log — escreve para stdout E para o arquivo
log() { echo "$@" | tee -a "$LOG_FILE"; }

# Para comandos longos (dnf, dkms), redireciona output para o log via pipe
# Prompts interativos usam /dev/tty para garantir que o read funciona
```

Output vai para log via função `log()` em vez de `exec > >(tee)` — evita problemas com buffering em prompts interativos e processos orphaned. Mantém últimos 10 logs (rotação simples via `ls -t | tail +11 | xargs rm`).

---

## Error handling e cleanup

```bash
set -uo pipefail  # sem -e (incompatível com prompts interativos e grep retornando 1)
CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]}"' EXIT

# Comandos críticos (dnf, dkms, dracut) usam check explícito:
# cmd || { log "❌ Falhou: cmd"; return 1; }
```

Temp directories criados por funções de análise (mesa, ucm, firmware, kernel-devel) são registrados em `CLEANUP_DIRS` e limpos automaticamente no EXIT, mesmo em Ctrl+C.

---

## Análise de pacotes systemd e grub2

##### systemd

Checagem pós-update: verifica integridade dos configs que dependem do systemd:
- `/etc/systemd/logind.conf.d/no-suspend.conf` existe
- `suspend.target` e `suspend-then-hibernate.target` estão masked (symlink → /dev/null)
- Changelog analisado por menções a "logind", "suspend", "udev"

##### grub2

Checagem pós-update: verifica antes de regenerar GRUB:
- `/etc/grub.d/08_vivobook` existe
- `clk_ignore_unused pd_ignore_unused` presentes em `/etc/default/grub`
- Changelog analisado por menções a "BLS", "devicetree", "aarch64"

---

## Estrutura do arquivo

```
vivobook-update.sh (~550-600 linhas)
├── Constantes e configuração (SENSITIVE_PATTERNS, URLs, cores)
├── Funções utilitárias (cores, prompt, log)
├── Funções preflight (check_root, check_internet, check_dnf_lock)
├── Funções discovery (classify_packages, detect_firmware_qcom)
├── Funções changelog (get_rpm_changelog, get_upstream_notes)
├── Funções compatibilidade (check_kernel_*, check_mesa_*, check_gnome_*, ...)
├── Funções update (apply_normal, apply_sensitive)
├── Funções post-update (rebuild_dkms, rebuild_initramfs, verify_fixes)
├── Função report (log rotation)
└── main() — orquestra o fluxo completo
```

## Instalação

O script será colocado em `/usr/local/bin/vivobook-update` (sem .sh, executável).
O `setup-all.sh` será atualizado para copiar o script na instalação.

---

## Fora de escopo

- Rollback automático de updates (dnf history undo existe, mas é manual)
- Notificações desktop (é interativo, o usuário já está no terminal)
- Update da própria extensão GNOME (feito pelo install-battery-time-ext.sh)
- Cron/timer automático
- Suporte a rpm-ostree
