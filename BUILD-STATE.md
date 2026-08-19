# Estado da construção personalizada

Última atualização: **2026-08-19**

## Concluído

- Hardware ASUS Vivobook X1407QA inventariado.
- Backup do DriverStore e catálogo de firmware criados.
- Fedora Workstation 44 AArch64 baixado e verificado.
- Linux 7.2 final baixado, verificado e compilado nativamente em ARM64.
- Kernel `7.2.0-x1407qa`, módulos, DTB e hashes verificados.
- Initramfs Linux 7.2 gerado dentro do Fedora live.
- Kernel Fedora original preservado como recuperação.
- Repositório e catálogo de firmware incluídos na mídia.
- ISO híbrida GPT/EFI reconstruída com atualização recursiva.
- ISO auditada por arquivos, GRUB, tamanho e SHA-256.
- Pendrive Kingston gravado e comparado bloco a bloco.

## Artefato final

```text
Nome: Fedora-44-X1407QA-Linux-7.2.iso
Tamanho: 4.919.656.448 bytes
SHA-256: bf7f278ef2445ae591f65c458e553bc2febdbc1a33ce0043f5fc9b04adab99d9
```

A ISO não é versionada no Git devido ao tamanho. Consulte
[`docs/BUILD-REPORT-2026-08-19.md`](docs/BUILD-REPORT-2026-08-19.md) para o
relatório completo, reprodução e limitações conhecidas.
