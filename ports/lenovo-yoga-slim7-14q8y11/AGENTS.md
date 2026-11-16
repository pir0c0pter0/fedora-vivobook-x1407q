# Escopo deste porte

- O alvo desta pasta é o Lenovo Yoga Slim 7 14Q8Y11, X2 Plus X2P-42-100/Kalambo, conforme solicitado pelo usuário. A regra ASUS/SSH do AGENTS.md da raiz continua valendo para o projeto ASUS; não usar aquele aparelho para validar este porte Lenovo.
- O PC local pode preparar fontes, documentos e builds. Só evidências do Lenovo contam como validação de hardware.
- Separar suporte observado em Glymur/Elite de suporte medido em Kalambo/Plus. Não escolher DTB apenas pelo nome comercial do notebook.
- Preservar firmware e perfis ICC/ICM originais com hashes e identificação do painel. Artefatos locais ficam em `local/`, ignorado pelo Git.
- O estado atual vive em README.md e docs/ESTADO-ATUAL.md; WORKFLOW.md e DRIVERS.md são históricos de 13/11. Não marcar nada como concluído sem evidência do hardware.
