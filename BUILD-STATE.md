# Estado da construção personalizada

Última atualização: **2026-08-19**

## Concluído

- Hardware ASUS Vivobook X1407QA inventariado.
- Backup do DriverStore e catálogo de firmware criados.
- Fedora Workstation 44 AArch64 baixado e verificado.
- Linux 7.2 final baixado, verificado e recompilado para AArch64.
- Kernel `7.2.0-x1407qa` com ISO9660, EROFS/LZ4 e DM snapshot, módulos, DTB e
  hashes verificados.
- Initramfs Linux 7.2 gerado dentro do Fedora live com suporte
  `dmsquash-live`, `livenet` e `pollcdrom` para `root=live:`, sem os módulos
  `iscsi` e `nvmf`.
- Repositório e catálogo de firmware incluídos na mídia.
- ISO híbrida GPT/EFI reconstruída com atualização recursiva.
- ISO auditada por kernel/config, módulos, initramfs, EROFS, GRUB, DTB, UEFI,
  GPT, tamanho e SHA-256.
- GRUB contém somente Linux 7.2: entrada normal e entrada de diagnóstico.
- Pendrive Kingston regravado e relido integralmente; o SHA-256 físico coincide
  com a ISO revisada. Kernel, initramfs, DTB e GRUB também foram extraídos do
  dispositivo e comparados byte a byte.
- Boot físico da mídia confirmado pelo usuário no ASUS Vivobook X1407QA.

## Artefato validado

```text
Nome: Fedora-44-X1407QA-Linux-7.2-livefix-reviewed.iso
Tamanho: 4.473.094.144 bytes
SHA-256: 114bc4bd5034096cee8c89369bd8c8b41abc03f93298ae5fa15b8dc9b2e11341
```

A ISO não é versionada no Git devido ao tamanho. Consulte
[`docs/BUILD-REPORT-2026-08-19.md`](docs/BUILD-REPORT-2026-08-19.md) para o
relatório completo, reprodução e limitações conhecidas.
