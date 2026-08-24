#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
ERRO: post-install-protect.sh foi desativado.

Ele criava entradas BLS duplicadas e restaurava parâmetros de boot que não
fazem mais parte do contrato validado. Use setup-vivobook.sh para configurar o
sistema instalado e rescue-installed-boot --repair para recuperar o boot.
Atualizações de kernel continuam manuais e exigem validação física.
EOF
exit 1
