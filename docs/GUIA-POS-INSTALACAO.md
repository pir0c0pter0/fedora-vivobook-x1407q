# Guia Pós-Instalação — ASUS Vivobook 14 X1407Q

## O Problema: Atualização de Kernel Quebra o Boot

Ao instalar o Fedora no NVMe e rodar `dnf update`, o kernel é atualizado (ex: 6.19.2 → 6.19.6).
O novo kernel:

1. Cria um diretório novo de DTBs (`/boot/dtb-6.19.6-xxx/`) **sem o DTB customizado (wifi-fix)**
2. Atualiza o symlink `/boot/dtb` para o novo diretório
3. Cria uma entrada BLS **sem a linha `devicetree`**
4. O sistema não encontra o DTB correto e **não boota**

## Solução: `post-install-protect.sh`

Script que protege o sistema contra futuras atualizações de kernel.

### O que faz

1. **Salva o DTB wifi-fix** em `/boot/dtb-custom/` (local seguro, não é tocado por updates)
2. **Instala hook kernel-install** (`/etc/kernel/install.d/99-snapdragon-dtb.install`) que roda automaticamente em cada `dnf update` do kernel:
   - Copia o DTB wifi-fix para o diretório do novo kernel
   - Adiciona `devicetree /dtb/qcom/x1p42100-asus-zenbook-a14.dtb` nas entradas BLS
   - Cria entrada BLS extra "WiFi Fix" para o novo kernel
3. **Garante** `clk_ignore_unused pd_ignore_unused` em `/etc/default/grub`
4. **Corrige** todas as entradas BLS existentes

### Como usar

```bash
# No sistema instalado (NVMe), com o DTB wifi-fix no mesmo diretório:
sudo ./post-install-protect.sh
```

Se precisar executar via chroot (bootando pelo USB live):

```bash
# Montar o sistema instalado
sudo mount -o subvol=root /dev/nvme0n1p3 /mnt
sudo mount /dev/nvme0n1p2 /mnt/boot
sudo mount /dev/nvme0n1p1 /mnt/boot/efi

# Copiar script e DTB
sudo cp post-install-protect.sh x1p42100-asus-zenbook-a14-wifi-fix.dtb /mnt/root/

# Bind mounts para chroot
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
sudo mount --bind /dev /mnt/dev
sudo mount --bind /run /mnt/run

# Executar
sudo chroot /mnt /bin/bash -c "cd /root && ./post-install-protect.sh"

# Desmontar
sudo umount /mnt/{run,dev,sys,proc,boot/efi,boot}
sudo umount /mnt
```

### Verificação

Após executar, o script mostra um resumo:

```
Entradas BLS com devicetree:
  [N] ...-0-rescue.conf
  [S] ...-6.19.2-300.fc44.aarch64.conf
  [S] ...-6.19.2-300.fc44.aarch64-wifi-fix.conf
  [S] ...-6.19.6-300.fc44.aarch64.conf
  [S] ...-6.19.6-300.fc44.aarch64-wifi-fix.conf
```

`[S]` = tem devicetree, `[N]` = não tem (normal para rescue).

## Pendrive USB Persistente

O pendrive tem 3 partições:

| Partição | Tamanho | Label | Conteúdo |
|----------|---------|-------|----------|
| sda1 | 2.5G | `Fedora-WS-Live-44` | ISO Fedora Live (read-only) |
| sda2 | 30M | `BOOT` | EFI + GRUB customizado + DTB wifi-fix |
| sda3 | 26G | `LIVE-DATA` | Overlay persistente (ext4) |

### Como funciona a persistência

O GRUB passa `rd.live.overlay=LABEL=LIVE-DATA rd.live.overlay.overlayfs` ao kernel.
O dracut monta sda3 como camada superior do overlayfs sobre o squashfs da ISO.

**Resultado:** tudo que é instalado ou modificado no live USB fica salvo automaticamente.

### O que já vem pré-instalado no pendrive

- **Claude Code** (`claude`) — CLI pronto para usar
- **GitHub CLI** (`gh`) — autenticado como pir0c0pter0
- **Git** — configurado com credenciais
- **Este repositório** — em `~/fedora-vivobook-x1407q/`

### Menu do GRUB no pendrive

| Entrada | Descrição |
|---------|-----------|
| **Vivobook X1407Q - WiFi Fix DTB [PERSISTENTE]** | Boot padrão com DTB wifi-fix + persistência |
| Zenbook A14 DTB (original) | DTB original sem fix de WiFi + persistência |
| CRD DTB | DTB alternativo + persistência |
| Auto DTB | Sem DTB explícito + persistência |
| **SEM persistência (clean boot)** | Boot limpo, nada é salvo |
| Troubleshooting → Verbose Boot | Boot sem `quiet rhgb` para debug |
| Troubleshooting → USB blacklist | Desabilita `qcom_q6v5_pas` (problemas de bateria) |

### Se precisar resetar a persistência

```bash
# Montar a partição de dados do pendrive
sudo mount /dev/sda3 /mnt

# Limpar o overlay (volta ao estado de fábrica da ISO)
sudo rm -rf /mnt/overlayfs/upper/*
sudo rm -rf /mnt/overlayfs/work/*

sudo umount /mnt
```

## Estrutura de Arquivos no Sistema Instalado

Após rodar `post-install-protect.sh`:

```
/boot/
├── dtb -> dtb-6.19.6-300.fc44.aarch64    # symlink (atualizado pelo kernel)
├── dtb-6.19.2-300.fc44.aarch64/
│   └── qcom/
│       ├── x1p42100-asus-zenbook-a14.dtb           # upstream
│       └── x1p42100-asus-zenbook-a14-wifi-fix.dtb  # customizado
├── dtb-6.19.6-300.fc44.aarch64/
│   └── qcom/
│       ├── x1p42100-asus-zenbook-a14.dtb           # upstream
│       └── x1p42100-asus-zenbook-a14-wifi-fix.dtb  # copiado pelo hook
├── dtb-custom/
│   └── qcom/
│       └── x1p42100-asus-zenbook-a14-wifi-fix.dtb  # fonte segura
├── loader/entries/
│   ├── ...-6.19.6-300.fc44.aarch64.conf            # devicetree adicionado
│   └── ...-6.19.6-300.fc44.aarch64-wifi-fix.conf   # criado pelo hook
└── efi/
    └── EFI/fedora/grub.cfg                         # regenerado

/etc/
├── default/grub                                     # clk_ignore_unused pd_ignore_unused
└── kernel/install.d/
    └── 99-snapdragon-dtb.install                    # hook automático
```

## Fluxo de uma Atualização de Kernel

```
dnf update kernel
  │
  ├── kernel-install add 6.20.x-xxx
  │     │
  │     ├── [hooks padrão] instala vmlinuz, initramfs, DTBs upstream
  │     │
  │     └── [99-snapdragon-dtb.install]  ← nosso hook
  │           │
  │           ├── Copia wifi-fix DTB de /boot/dtb-custom/ → /boot/dtb-6.20.x/qcom/
  │           ├── Adiciona "devicetree" na entrada BLS do 6.20.x
  │           └── Cria entrada BLS "WiFi Fix" para o 6.20.x
  │
  └── Sistema pronto para reboot com DTB correto ✓
```
