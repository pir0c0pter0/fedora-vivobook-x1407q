# Proteção pós-instalação — fluxo legado desativado

`post-install-protect.sh` foi desativado em 2026-08-24. Ele copiava um DTB
wifi-fix obsoleto, criava entradas BLS duplicadas e restaurava
`pd_ignore_unused`, contrariando o contrato validado do sistema instalado.

Use:

- `setup-vivobook.sh` para configurar o sistema instalado;
- `rescue-installed-boot --repair` a partir do live USB para recuperar BLS,
  `custom.cfg`, DTB e GRUB;
- `tools/audit-stable-hardware.sh --post-reboot` depois de cada mudança de
  kernel ou boot.

Atualizações automáticas de kernel continuam desabilitadas. Um kernel novo só
deve ser mantido depois de validar fisicamente boot, Wi-Fi, áudio, teclado,
brilho e s2idle. O hook definitivo de `kernel-install` ainda é uma pendência
registrada em `BUILD-STATE.md`.
