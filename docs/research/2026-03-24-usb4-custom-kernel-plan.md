# USB4 / TB3 — Plano para Kernel Custom

**Data:** 2026-03-24
**Status:** Decisão tomada — DKMS sozinho não fecha o caso; seguir com kernel custom
**Kernel base:** `6.19.8-300.fc44` (`kernel-6.19.8-300.fc44.src.rpm` na raiz do repositório)

---

## Decisão

O estado atual da investigação é:

- `install-usb4-role-fix.sh` corrige a fase 0 (`data_role`)
- `diagnose-usb4.sh` já coleta o before/after necessário
- `modules/vivobook-usb4-fix-1.0/` ajuda a instrumentar Type-C, mux e retimer
- mas o dock Elgato TB3 continua bloqueado por ausência do host/router USB4 no kernel

Conclusão prática: insistir só em overlay ou altmode sintético no runtime não fecha
o túnel Thunderbolt. O próximo passo útil é bootar um kernel com a pilha USB4
certa para `x1e80100`.

## Escopo mínimo do patch stack

### 1. Host/router USB4 Qualcomm

Objetivo: adicionar o driver que faltava para o SoC `x1e80100`.

Arquivos esperados:
- `drivers/thunderbolt/` com novo arquivo Qualcomm (`qcom_usb4.c` ou equivalente da série real)
- `drivers/thunderbolt/Kconfig`
- `drivers/thunderbolt/Makefile`

Sem esse bloco, `/sys/bus/usb4/` não deve aparecer e o dock continuará preso em
Billboard.

### 2. Device Tree para o host USB4

Objetivo: expor a topologia do host/router no DT do `x1e80100`.

Arquivos esperados:
- `arch/arm64/boot/dts/qcom/hamoa.dtsi` ou arquivo `x1e80100` equivalente usado pela série
- nós para host/router USB4 ligados a `a600000.usb` e `a800000.usb`
- graph/connector compatível com a pilha Type-C já presente

Observação: esse pedaço precisa seguir exatamente o binding da série RFC. Não vale
inventar nó local sem casar com o driver real.

### 3. PHY USB43DP para x1e80100

Objetivo: permitir que o combo PHY seja reconhecido como USB4+DP, não só USB3+DP.

Arquivos prováveis:
- `drivers/phy/qualcomm/phy-qcom-qmp-combo.c`
- DTS com `compatible = "qcom,x1e80100-qmp-usb43dp-phy"` nos PHYs `fd5000` e `fda000`

Se a série do host/router já trouxer isso, usar o patch dela. Se não trouxer, esse
ajuste entra como patch complementar.

### 4. UCSI / altmode quirks

Objetivo: reduzir o gap entre o que o firmware anuncia e o que a pilha Type-C
consegue ativar.

Status:
- importante, mas secundário ao host/router
- só entra na primeira rodada se vier junto na série Qualcomm
- se o barramento USB4 aparecer e o dock ainda ficar em Billboard, revisar aqui

### 5. `ps883x` e rota sintética

Objetivo: evitar perder tempo com o Oops já conhecido.

Regra:
- manter `emulate_tb3_port_ops=0`
- não reativar a rota sintética antes de confirmar que o host/router Qualcomm subiu
- se ainda houver crash após o host/router existir, o problema passa a ser depuração
  do retimer com contexto real, não emulação

## Estratégia de build

Seguir exatamente o padrão já usado na pesquisa de `s2idle`: build RPM local sobre
o SRPM Fedora.

### Preparação

```bash
mkdir -p ~/rpmbuild
rpm -ivh kernel-6.19.8-300.fc44.src.rpm
```

Se o ambiente já estiver preparado por causa do trabalho de `s2idle`, apenas reutilizar
`~/rpmbuild/SPECS/kernel.spec` e `~/rpmbuild/SOURCES/`.

### Organização sugerida dos patches

```text
~/rpmbuild/SOURCES/
├── usb4-0001-*.patch
├── usb4-0002-*.patch
├── usb4-0003-*.patch
└── usb4-local-x1e80100-phy.patch   # só se o RFC não cobrir o PHY
```

### Ajustes no `kernel.spec`

- definir `buildid` como `.usb4`
- adicionar os patches na ordem da série
- aplicar com `%patch`
- manter build enxuto:
  - `--without debug`
  - `--without debuginfo`
  - `--without perf`
  - `--without tools`
  - `--without bpftool`
  - `--without selftests`
- limitar paralelismo a **metade dos nucleos** para evitar thermal shutdown

Helpers preparados no repositório:

```bash
bash prepare-usb4-kernel.sh
bash build-usb4-kernel.sh
```

Comportamento:
- `prepare-usb4-kernel.sh` gera `~/rpmbuild/SPECS/kernel-usb4.spec` sem sobrescrever o `kernel.spec` atual
- `build-usb4-kernel.sh` recusa buildar sem `usb4-*.patch` reais e limita o build a metade dos núcleos

### Build

```bash
rm -rf ~/rpmbuild/BUILD/kernel-6.19.8-build

bash build-usb4-kernel.sh
```

### Instalação

```bash
sudo dnf install ~/rpmbuild/RPMS/aarch64/kernel-*6.19.8-300.usb4*.rpm
sudo dkms autoinstall -k 6.19.8-300.usb4.fc44.aarch64
sudo reboot
```

## Validação

### Antes do reboot

```bash
sudo bash diagnose-usb4.sh | tee /tmp/usb4-before.txt
```

### Depois de subir no kernel custom

Checklist mínimo:

1. `uname -r` mostra `6.19.8-300.usb4.fc44.aarch64`
2. `/sys/bus/usb4/` existe
3. `journalctl -b | rg 'qcom_usb4|thunderbolt|usb4|ucsi|typec|ps883'`
4. dock conectado **após** o boot completo
5. `sudo boltctl list` mostra o dock ou algum domínio detectado
6. `lsusb -t` deixa de mostrar apenas Billboard fallback
7. `ip link show` expõe a interface ethernet do dock

### Critério de sucesso por nível

| Nível | Sinal | Interpretação |
|-------|-------|---------------|
| 1 | `/sys/bus/usb4/` existe | host/router Qualcomm probou |
| 2 | `boltctl` ou altmodes do partner aparecem | pilha Type-C/TB3 saiu do fallback |
| 3 | USB hub + ethernet do dock enumeram | túnel TB3 funcional |

## Go / No-Go

### Go

Prosseguir com kernel custom se pelo menos uma destas condições for verdadeira:

- a série RFC do host/router Qualcomm foi obtida
- existe branch pública testável com `drivers/thunderbolt` atualizado para Qualcomm
- o patch de PHY/DT consegue ser alinhado com essa série

### No-Go

Parar e não gastar mais tempo em DKMS se:

- a série do host/router não estiver disponível
- o kernel custom ainda não criar `/sys/bus/usb4/`
- o único avanço possível depender de reativar a rota sintética que já derrubou `ps883x`

## Papel dos artefatos já existentes

- `install-usb4-role-fix.sh`: manter instalado; é pré-condição para o dock aparecer ao menos como Billboard
- `diagnose-usb4.sh`: rodar antes e depois de cada kernel
- `modules/vivobook-usb4-fix-1.0/`: usar só como instrumentação enquanto o host/router real não está estável
- `USB4-TB3-investigation.md`: documento de diagnóstico raiz

## Referências

- Investigação principal: `USB4-TB3-investigation.md`
- Fluxo RPM já validado no projeto: `docs/research/2026-03-16-s2idle-suspend-fix.md`
- Árvore upstream Thunderbolt/USB4: https://kernel.googlesource.com/pub/scm/linux/kernel/git/westeri/thunderbolt/+/refs/heads/master/drivers/thunderbolt/
