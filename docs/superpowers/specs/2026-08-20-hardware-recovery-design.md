# Recuperação do hardware estável no Vivobook X1407QA

## Objetivo

Restaurar no Fedora 44 com kernel `7.2.0-x1407qa` todos os recursos que o
repositório classifica como estáveis para uso diário. Câmera IR, USB4/TB3 e
suspend ficam explicitamente fora do escopo.

## Estado observado

- O Wi-Fi WCN6855 enumera em `0004:01:00.0`, mas o `ath11k_pci` perde o vínculo
  após `failed to power up mhi: -110`; nenhuma interface Wi-Fi é criada.
- `wcn_regulator_fix` repete `-EPROBE_DEFER` indefinidamente, embora o resumo de
  reguladores mostre `VREG_WCN_3P3`, `VREG_WCN_0P95` e `VREG_WCN_1P9` ativos.
- Os nós ADSP e CDSP ficam com probes deferidos e `/sys/class/remoteproc` não
  contém processadores remotos ativos.
- `qcom_battmgr` cria os dispositivos de alimentação, mas leituras retornam
  `EAGAIN`; UPower mostra 0%, 0 Wh e estado desconhecido.
- O GNOME está com `show-battery-percentage=false` e a extensão
  `battery-time@wifiteste` não está instalada.
- O initramfs contém os blobs principais de ADSP, CDSP e GPU, mas a ausência dos
  módulos remoteproc necessários deve ser verificada e corrigida.
- `dkms` não está instalado. Quatro módulos essenciais existem em `/usr/src` e
  como módulos extras do kernel atual, mas não possuem gestão DKMS funcional.
- O log também registra pedidos de firmware GPU e Bluetooth que precisam ser
  reconciliados com os arquivos compactados existentes.

## Abordagem escolhida

Manter o kernel 7.2 atual e reparar a instalação de forma incremental. Cada
correção terá uma reprodução anterior, uma hipótese única e uma verificação
posterior. O instalador integral não será executado sem adaptação, pois mistura
16 subsistemas e pode esconder qual mudança resolveu ou regrediu cada recurso.

Primeiro será criado um diagnóstico automatizado, somente leitura, que produza
um resultado independente por subsistema. Em seguida, a cadeia ADSP/CDSP será
restaurada, porque bateria, áudio e clocks dependem dela. O Wi-Fi será corrigido
depois, alinhando o consumidor de reguladores ao DT/runtime do kernel 7.2 e
impedindo retries infinitos. Os demais recursos estáveis serão reconciliados
com o estado documentado pelo repositório.

## Componentes e fluxo

1. **Auditoria:** um script testa kernel, firmware/initramfs, módulos, interfaces,
   sysfs, serviços e configuração do usuário sem alterar o sistema.
2. **Remoteproc e firmware:** garantir que drivers ADSP/CDSP necessários estejam
   no initramfs e que os caminhos de firmware pedidos pelo DT existam.
3. **Wi-Fi:** testar o módulo contra os fornecedores disponíveis, aplicar a menor
   alteração confirmada, compilar para `7.2.0-x1407qa` e validar MHI/ath11k.
4. **Instalação persistente:** instalar DKMS e registrar apenas módulos estáveis;
   regenerar dependências e initramfs, preservando o kernel e Mesa atuais.
5. **Recursos de desktop:** habilitar percentual, instalar a extensão de tempo,
   aplicar touchpad, Vulkan/terminal e configuração segura da tampa.
6. **Recursos restantes:** validar teclado, brilho/Fn, GPU, Bluetooth, áudio,
   cpufreq, limite de carga, câmera RGB sob demanda e controle de cor.
7. **Reboot e aceite:** reiniciar uma vez após preparar a instalação e executar
   novamente toda a auditoria, além dos testes do repositório.

## Segurança e recuperação

- Não habilitar câmera IR, módulo USB4 experimental ou suspend/hibernate.
- Não modificar GPIO5 para `DIG_OUT_SOURCE_CTL=0x00` nem forçar GPIO5 LOW.
- Não atualizar kernel, Mesa ou firmware por atualização geral de pacotes.
- Antes de substituir arquivos de sistema não gerenciados por RPM, guardar uma
  cópia identificada pela data em diretório local e registrar o que foi mudado.
- Uma falha de compilação ou initramfs interrompe o fluxo antes do reboot.
- A entrada/kernel atualmente inicializável permanece disponível como caminho
  de recuperação.

## Critérios de aceite

- **Wi-Fi:** dispositivo ligado a `ath11k_pci`, interface Wi-Fi visível no
  NetworkManager e ausência de timeout MHI no boot validado.
- **Bateria:** `capacity`, `status`, energia e potência legíveis no sysfs;
  UPower apresenta percentual real; GNOME mostra o percentual e reconhece a
  extensão de tempo restante.
- **ADSP/CDSP:** remoteprocs esperados em estado `running`, sem probes deferidos
  que bloqueiem os respectivos serviços.
- **GPU:** renderizador de hardware disponível e nenhum firmware obrigatório
  ausente no boot validado.
- **Bluetooth, teclado, touchpad, brilho/Fn, áudio e cpufreq:** dispositivo ou
  controle correspondente presente e teste funcional não destrutivo aprovado.
- **Carga, câmera RGB e cor:** limite de 80% legível, câmera enumerável somente
  sob demanda e interface de controle de cor disponível.
- **Tampa:** continua apenas bloqueando/desligando a tela; targets de suspensão e
  hibernação permanecem desabilitados.
- Todos os testes aplicáveis do repositório terminam sem falhas e a auditoria
  final não contém regressões novas relevantes.

## Entregáveis

- Diagnóstico reproduzível por subsistema.
- Correções mínimas no repositório necessárias para kernel 7.2.
- Instalação persistente no sistema atual.
- Registro das alterações, comandos de validação e limitações mantidas.
