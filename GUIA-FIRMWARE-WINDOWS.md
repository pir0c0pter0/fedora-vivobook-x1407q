# Extrair firmware Qualcomm do Windows — `extract-firmware-windows.bat`

Guia para o **ASUS Vivobook 14 X1407QA (Snapdragon X)**.

O firmware da Qualcomm (áudio/ADSP, GPU, CDSP, WiFi) é **proprietário e
assinado pra esse modelo**. Ele só existe na partição do **Windows** que veio
de fábrica — não tem download genérico. Este `.bat` copia esse firmware pra um
pendrive, pra você usar depois no Fedora.

---

## ⬇️ A ISO pronta (download)

ISO bootável do Fedora 44 aarch64 já com os patches do Vivobook X1407QA
(parâmetros de boot Snapdragon + scripts de fix embutidos):

- **Link:** https://temp.sh/lzVpY/Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso
- **Expira:** ~2026-07-02 (temp.sh guarda por ~3 dias — baixe logo)
- **SHA256:**
  ```
  0396b34c930bf0149c1d04ee8ff76957019dd6503b34037fe8541f4a82f5c263
  ```

**Baixar pelo navegador:** abra o link e clique em *"Click here to download"*.

**Baixar pelo terminal** (o temp.sh entrega via POST):

```bash
curl -L -X POST \
  "https://temp.sh/lzVpY/Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso" \
  -o Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso
```

**Conferir a integridade** (tem que bater com o SHA256 acima):

```bash
sha256sum Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso
```

**Gravar num pendrive** (⚠️ apaga tudo do pendrive — confira o `/dev/sdX`):

```bash
sudo dd if=Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso \
  of=/dev/sdX bs=4M status=progress oflag=sync && sync
```

> A ISO **não** inclui o firmware Qualcomm (proprietário). Você extrai do seu
> próprio Windows com o `.bat` abaixo, **antes** de instalar o Fedora.

---

## ⚠️ Faça isto ANTES de formatar / instalar o Linux

Instalar o Fedora **apaga o Windows**, e com ele o firmware. Se você já apagou
o Windows sem extrair, vai precisar pegar o firmware de outro Vivobook X1407QA
igual ou de uma imagem de recovery do Windows. **Extraia primeiro.**

Sem esse firmware, depois do Linux instalado **não funcionam**: WiFi, GPU
(aceleração), áudio e bateria.

---

## Pré-requisitos

- Vivobook ainda com **Windows** funcionando (o de fábrica).
- Um **pendrive** formatado em **FAT32** ou **exFAT** (NTFS também serve).
- O arquivo **`extract-firmware-windows.bat`** (vem junto com este guia / no reppositório do projeto).

---

## Passo a passo (no Windows)

1. Copie **`extract-firmware-windows.bat`** para o **pendrive**.
2. Abra o pendrive no Explorador de Arquivos e dê **duplo-clique** no `.bat`.
3. Vai aparecer o aviso do Controle de Conta de Usuário (UAC) pedindo
   privilégios de administrador — clique **Sim**. (É necessário porque o
   firmware fica numa pasta protegida do sistema.)
4. Uma janela preta abre e vai listando os pacotes copiados (`[+] qcadsp...`,
   `[+] qcdx...`, etc.). Aguarde até aparecer **"PROXIMOS PASSOS"**.
5. Pode fechar a janela. O dump fica na pasta **`vivobook-qcom-firmware\`**, ao
   lado do `.bat`, **no próprio pendrive**.

> Rodando o `.bat` direto do pendrive, o dump já cai no pendrive. Se você rodou
> de outra pasta (ex.: Downloads), mova a pasta `vivobook-qcom-firmware` para o
> pendrive depois.

**Não perca esse pendrive** — você vai usar o dump depois de instalar o Fedora.

---

## O que o `.bat` faz (por dentro)

- Se auto-eleva para **Administrador** (relança via PowerShell `RunAs`).
- Lê `C:\Windows\System32\DriverStore\FileRepository`.
- Copia **inteiros** os pacotes de driver da Qualcomm (pastas que começam com
  `qc*`: `qcadsp*`, `qcdx*`, `qccdsp*`, `qcwlan*`, `qcsubsys*`, …), **incluindo
  os arquivos `.inf`**.
- Preserva a estrutura `Windows\System32\DriverStore\FileRepository\...` dentro
  de `vivobook-qcom-firmware\`.
- No fim, mostra quantos pacotes e quantos arquivos `.mbn`/`.bin` foram copiados.

> **Por que copiar os pacotes inteiros, e não só os `.mbn`?** A ferramenta do
> lado Linux (`qcom-firmware-extract`) usa os arquivos **`.inf`** pra renomear
> cada firmware para o caminho/nome corretos que o kernel espera. Só os `.mbn`
> soltos não bastariam.

---

## Usar o dump no Fedora (depois de instalar)

Já no **Fedora instalado** no Vivobook, plugue o pendrive e rode (ajuste o
caminho/nome do pendrive):

```bash
# o caminho costuma ser /run/media/SEU_USUARIO/NOME_DO_PENDRIVE/vivobook-qcom-firmware
sudo ./extract-qcom-firmware.sh /run/media/$USER/PENDRIVE/vivobook-qcom-firmware

# se a ISO já trouxe os scripts embutidos:
sudo /opt/vivobook-fixes/extract-qcom-firmware.sh /run/media/$USER/PENDRIVE/vivobook-qcom-firmware
```

O `extract-qcom-firmware.sh` instala/usa o `qcom-firmware-extract` e coloca cada
arquivo no lugar certo:

- `/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/` (ADSP, GPU ZAP, CDSP)
- `/usr/lib/firmware/ath11k/WCN6855/hw2.1/` (board data do WiFi)

Depois, aplique todos os fixes e reinicie:

```bash
sudo /opt/vivobook-fixes/setup-vivobook.sh
sudo reboot
```

---

## Fluxo completo (resumo)

1. **(Windows, antes de formatar)** rodar `extract-firmware-windows.bat` → dump no pendrive.
2. Gravar a ISO do Vivobook num pendrive e dar boot (F12) → instalar o Fedora no NVMe.
3. **(Fedora instalado)** `extract-qcom-firmware.sh <pendrive>/vivobook-qcom-firmware`.
4. `setup-vivobook.sh` → todos os fixes de hardware.
5. `sudo reboot`.

---

## Problemas comuns

| Sintoma | Causa / solução |
|---|---|
| "Nenhum pacote de driver Qualcomm (`qc*`) encontrado" | Não é o Windows de fábrica da ASUS, ou os drivers foram removidos. Use o Windows original do aparelho. |
| UAC não aparece / "acesso negado" | Rode como administrador: clique-direito no `.bat` → **Executar como administrador**. |
| Janela fecha na hora | Abra o **Prompt de Comando** como admin e rode o `.bat` pelo caminho dele pra ver as mensagens. |
| `.bat` abre num editor de texto | Clique-direito → Abrir com → **Processador de Comandos do Windows**, ou rode pelo `cmd`. |
| Pendrive não aparece no Fedora | Confira o caminho real: `ls /run/media/$USER/` (ou monte com o gerenciador de arquivos). |
| `0 arquivos de firmware` no fim | DriverStore sem firmware Qualcomm — confirme que é o Vivobook X1407QA correto. |

---

## O que cada firmware habilita

| Pacote (Windows `qc*`) | Componente no Linux |
|---|---|
| `qcadsp*` | DSP de áudio + gerenciador de bateria (ADSP) |
| `qcdx*` | GPU Adreno X1-45 (shader ZAP `qcdxkmsucpurwa.mbn`) |
| `qccdsp*` | DSP de computação / NPU (CDSP) |
| `qcwlan*` | WiFi WCN6855 (board data) |

> O firmware **não vai embutido** na ISO compartilhada (é proprietário e
> específico do aparelho). Por isso cada pessoa extrai do próprio Windows com
> este `.bat`.
