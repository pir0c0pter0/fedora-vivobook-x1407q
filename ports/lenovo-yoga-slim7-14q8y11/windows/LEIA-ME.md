# Coleta Windows — Lenovo Yoga Slim 7 14Q8Y11

Este coletor prepara os dados do aparelho para o porte Fedora/Niri/Noctalia. Roda no Windows original do **Lenovo 83QR / Yoga Slim 7 14Q8Y11 ARM64**, com Windows PowerShell **5.1 nativo ARM64**, sem instalar dependências e sem acesso à rede.

## Como executar

1. Extraia o ZIP inteiro em uma pasta no Lenovo. Não execute os arquivos de dentro do ZIP.
2. Conecte uma unidade externa com cerca de **30 GB livres**. NTFS ou exFAT evita o limite de arquivo de 4 GB do FAT32; a coleta pode precisar de mais espaço conforme os drivers instalados.
3. Clique com o botão direito em **Coletar-Yoga.cmd → Executar como administrador**.
4. Quando ele pedir o destino, digite uma pasta, por exemplo **`E:\Yoga-Coletas`**. Ajuste a letra da unidade. Digite o caminho sem aspas nessa pergunta.
5. Aguarde a exportação e o cálculo de hashes. Não desconecte a unidade durante a execução. Pode demorar vários minutos.

Ele cria uma **subpasta nova por execução**, sem sobrescrever coletas anteriores. Não instala/remove drivers, não escreve BIOS/EC, não modifica partições nem exige desativar Secure Boot. A opção `ExecutionPolicy Bypass` do launcher vale somente para o processo iniciado, sem mudar a política permanente do Windows.

Alternativa pelo **Windows PowerShell como Administrador**, estando na pasta extraída:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Collect-Yoga14Q8Y11.ps1 -Destination 'E:\Yoga-Coletas'
```

Se aparecer erro de arquitetura, abra o executável nativo:

```text
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

O teste de modelo aceita o código `83QR` ou a descrição `Yoga Slim 7 14Q8Y11` e exige CPU ARM64. O processador e o painel reais são registrados; o coletor não escolhe DTB nem aplica firmware com base no catálogo.

## O que ele coleta

| Saída | Conteúdo |
|---|---|
| `inventory/identification.json` | Modelo, família/MTM informado pelo Windows, CPU/núcleos, BIOS, versão do Windows e PowerShell |
| `inventory/storage-layout.json` | Discos e particionamento: tamanhos, offsets, tipos e setores; sem ler o conteúdo das partições |
| `inventory/Win32_*.json` | Inventário PnP, drivers/versões/INF, vínculos e recursos de memória/IRQ/portas, GPU, áudio e bateria |
| `inventory/pnp-properties/` | Propriedades de cada dispositivo presente, incluindo IDs, localização, relações e recursos expostos pelo Windows |
| `drivers/exported/` | Exportação oficial dos pacotes de driver pelo PnPUtil |
| `drivers/DriverStore/FileRepository/` | Cópia completa dos pacotes originais, preservando subpastas, INF, blobs e possíveis overlays ACPI |
| `drivers/System32-drivers/` | Arquivos dos drivers e firmware disponíveis nessa árvore |
| `firmware/System32/` | Arquivos soltos `.mbn`, `.elf`, `.jsn`, `.bin`, `.fw`, `.tplg` no primeiro nível de System32 |
| `acpi/` e índices JSON | Tabelas ACPI pela API do Windows e valores binários disponíveis no registro, com validação de comprimento/checksum |
| `edid/` e `edid-registry.json` | EDIDs brutos disponíveis no registro e associação à instância do monitor |
| `colors/` | Pasta de cores do Windows, perfis ICC/ICM das pastas opcionais Lenovo/X-Rite/usuário e associações ICM no registro |
| `copy-sources.json` | Correspondência entre pastas de origem e destino, sem achatar nomes de arquivos |
| `logs/`, `steps.json`, `RESUMO.txt` | Resultados e erros de cada etapa |
| `manifest-sha256.csv`, `hash-errors.json` | Caminho relativo, tamanho e SHA-256 dos arquivos obtidos; erros de leitura/hashing separados |

O DriverStore completo também preserva perfis de cores e firmwares cujos nomes não começam com `qc`. Não depende de reconhecer previamente o fabricante do painel, câmera, Wi-Fi ou touchpad.

As tabelas ACPI `MSDM` e `SLIC`, ligadas à ativação OEM, são excluídas do dump. Não são coletados intencionalmente documentos pessoais, perfis/senhas Wi-Fi, chaves BitLocker, chaves de ativação ou um dump indiscriminado do registro. **IDs de dispositivos, EDID, ACPI e arquivos dos fabricantes podem conter números de série e outros identificadores**: mantenha o pacote privado, sem publicar a pasta inteira em um repositório.

## O que enviar e como interpretar

**Resultado já recebido:** a primeira coleta foi copiada integralmente para o PC, com 6.430 hashes Windows aprovados, 188 pacotes de drivers exportados e sete perfis LEN88AE preservados. A única etapa parcial foi `edid-registry`, que mesmo assim salvou dois EDIDs. Ver o [relatório da aquisição](../COLETA-WINDOWS-2026-11-13.md); não repetir toda a exportação apenas por esse aviso.

Na primeira execução no Lenovo, a versão inicial exibiu acesso negado a subchaves `Properties` durante `edid-registry`, marcou a etapa como incompleta e continuou para os perfis de cores. Esse aviso não determina o resultado das outras etapas. A coleta terminou e seus arquivos foram preservados; `edid-registry.json` registra a ressalva e dois EDIDs foram obtidos.

A revisão v2 busca os caminhos `DISPLAY\<monitor>\<instância>\Device Parameters` diretamente, sem percorrer os ramos `Properties`. Erros reais de acesso ao próprio EDID continuam registrados. A regressão foi reproduzida e a correção passou em fixture; a v2 ainda precisa de validação no aparelho. Não repetir a coleta completa para testar essa revisão sem uma lacuna concreta.

Envie primeiro **`RESUMO.txt`**, **`inventory/identification.json`** e **`hash-errors.json`**. Eles permitem conferir o processador exato e as lacunas antes de transferir os arquivos grandes. Preserve a pasta inteira para a análise de ACPI, firmware e perfis.

- Código **0**: etapas executadas sem erros detectados; pastas opcionais ausentes são `not-present`.
- Código **2**: coleta parcial preservada; o resumo/índices mostram os problemas. Não apague a pasta nem tente instalar drivers para corrigir o coletor.
- Outro código: erro de pré-requisito ou execução; o launcher mantém a janela aberta.

Não existe compactação automática da coleta: ela pode ser grande e conter arquivos além dos limites do ZIP do PowerShell. O ZIP distribuído contém apenas o coletor/launcher e este guia.

## Limites importantes

- A API Windows retorna apenas a **primeira tabela** para assinaturas repetidas, como SSDT. O dump binário do registro complementa a API, mas não garante todos os SSDTs; os índices deixam essa limitação registrada. Se faltar algo, será necessária outra forma de aquisição.
- Algumas tabelas, recursos ou arquivos podem ser bloqueados pelo Windows, por políticas corporativas ou estar ausentes. Cada etapa continua após uma falha e registra o que ficou incompleto.
- A coleta lê o sistema em uso, sem snapshot; não substitui mídia de recuperação ou backup completo do Windows.
- Os hashes cobrem os arquivos obtidos, inclusive resumo e journal final. O manifesto não inclui ele próprio nem `hash-errors.json`. Eles não comprovam que um firmware Windows é utilizável no Linux.
- Os testes de funções/parser, regressão de EDID e compilação C# passaram em PowerShell 7.7 no host Linux com fixtures. A versão inicial foi executada no Lenovo com Windows PowerShell 5.1.28000.1 e seus relatórios/hashes foram recebidos e conferidos. A validação física da v2 permanece pendente.

Referências: [PnPUtil](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax), [Robocopy](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy), [EnumSystemFirmwareTables](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-enumsystemfirmwaretables), [GetSystemFirmwareTable](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemfirmwaretable).
