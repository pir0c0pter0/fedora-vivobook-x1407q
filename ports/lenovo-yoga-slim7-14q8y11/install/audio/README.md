# Audio do Yoga 14Q8Y11

Validado no boot normal `current` em 17/11/2026: iniciou ADSP, LPASS, quatro
WSA884x e a placa ALSA automaticamente. O PipeWire ofereceu a saida
`Yoga speakers`; reproducao de MP3 normalizado foi ouvida pelo usuario.
Tres ciclos Off/HiFi e volume 40/100% preservaram PA=6 e DV=66 nos quatro
canais, com WirePlumber sem reinicios. Os dois microfones passaram por
ALSA e PipeWire. Boot normal: 34,317 s; WirePlumber PID2125/NRestarts0,
reproducao e captura simultaneas aprovadas sem alterar PA6/DV66.
O usuario ouviu os quatro trechos isolados; nao distinguiu os lados.

`yoga-audio.service` exige `yoga.audio=1`, inicia depois das cameras e antes
do GDM. O script confere placa, firmware, topologia e perfis por hash;
restaura o caminho temporario do firmware inclusive em falhas. O SoCCP
permanece attached e nunca recebe stop. O caminho manual continua disponivel
por etapas. Nao executar o antigo `mixer-por-numid.sh` na integracao: ele
depende de indices de um log historico.

O perfil UCM especifico fixa PA=6 e DV=66 (-18 dB), valores ja usados na
validacao fisica. O volume do desktop e por software. Ele nao importa o
perfil CRD, que configura PA=12 e DV=84, acima dos limites deste kernel.
O PCM ALSA `route` duplica estereo [L,R] em [L,R,L,R]; o PipeWire expoe
dois canais e o PCM fisico recebe quatro. Os dois macros WSA permanecem
ativos para evitar EBUSY nos controles.
Isso ainda nao substitui a calibracao acustica/protecao proprietaria Windows.

## Instalacao e recuperacao

Guardar `current`, `try`, manifesto de `good`, o diretorio UCM
`/usr/share/alsa/ucm2/conf.d/glymur` e `/var/lib/alsa` antes de alterar.
Mover o link antigo `glymur.conf` antes de instalar o arquivo novo, para nao
sobrescrever o destino compartilhado CRD. Guardar e retirar o antigo
`/var/lib/alsa/card0.conf.d/ctl-remap.conf`, que expoe o ganho PA como
`Speakers Volume`. Preservar o estado ALSA previamente validado PA6/DV66;
o script espera a inicializacao udev da placa antes do ajuste final.

Instalar `yoga-audio.sh` como `/usr/local/sbin/yoga-audio` (0755), a unidade
em `/etc/systemd/system/`, e ambos os arquivos de `ucm/` em
`/usr/share/alsa/ucm2/conf.d/glymur/` (0644). Habilitar a unidade apos
`systemctl daemon-reload`. Acrescentar `yoga.audio=1` somente ao slot `try`
inicialmente e armar uma tentativa com `yoga-boot-once try`.

Para reverter, retirar o argumento de audio e reiniciar; nao descarregar
drivers nem parar os coprocessadores. Desabilitar a unidade e restaurar
os arquivos UCM/ALSA do backup quando o audio estiver offline.

Evidencias privadas: `local/physical-2026-11-17/audio-gpu-npu/`.
`test-startup.py` exercita guardas, limites, controles e a restauracao do
caminho de firmware; nao substitui reproducao real.

## Microfones

`yoga-audio-mic-test.dts` acrescenta somente `dmic01_default` (LPASS6/7)
ao DT de cameras/USB validado. SHA256 do DTB promovido:
`92f6b329e0e0225c61d98181866669c062847594cc73061fa4af721f01ba8642`.
A coleta ACDB Windows associada ao
SUBSYS_17AA3803 tem caminhos LPAIF_VA/interface1 com um/dois canais, mas
nao comprova os pinos sozinha. O teste no Plus confirmou sinal acustico
nos dois canais: correlacao com a musica -0,343/-0,452, atraso 2,172 s
(inclui espera programada de 2 s). RMS subiu de 86/70 para 159/182 e
voltou a 85/67 ao terminar a musica. Gain84 corresponde a 0 dB.
PipeWire gravou 281.600 quadros estereo/48 kHz no try; no boot normal,
278.528 quadros durante reproducao, sem reinicio do WirePlumber.
DMIC2/3 continuam desabilitados. Cancelamento de eco e calibracao
proprietaria nao foram implementados; fone externo nao foi testado.
