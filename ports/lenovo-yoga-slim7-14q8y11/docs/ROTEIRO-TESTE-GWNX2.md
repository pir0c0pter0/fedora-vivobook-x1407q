ARGS:
set yoga_slot_args="panic=30 pcie_aspm=off nvme_core.default_ps_max_latency_us=0 initcall_blacklist=slim7x11_ec_driver_init systemd.unit=multi-user.target modprobe.blacklist=ucsi_glink,pmic_glink_altmode,qcom_pd_mapper,apr,fastrpc,snd_q6apm,q6prm,q6prm_clocks,q6apm_dai,q6apm_lpass_dais,snd_soc_lpass_wsa_macro,snd_soc_lpass_va_macro,soundwire_qcom,snd_soc_wsa884x,snd_soc_x1e80100,rtc_pm8xxx,phy_qcom_m31_eusb2,phy_qcom_eusb2_repeater"

FILES:
B = <workspace>/fedora-vivobook-x1407q/.worktrees/lenovo-yoga-slim7-14q8y11-x2plus/ports/lenovo-yoga-slim7-14q8y11

Do PC para /root/gwnx2/ no notebook (nada foi enviado nem instalado):
1. B/local/dtb-bisect-r5/kalambo-gwnx2.dtb (e281bc20...5605) -> /boot/yoga/try/board.dtb
2. B/install/audio/yoga-audio.sh (425fdc2b...)
3. B/install/ec-rtc/ec-tool.py (9343904b...)
4. B/install/ec-rtc/extmod-ec/yoga-ec-test.ko (c2a39bff..., vermagic 7.4.0-rc1-yoga-kalambo+)
5. B/install/ec-rtc/rtc-fallback/yoga-rtc (2ec9dca8...), só para rodar "save" à mão; NÃO instalar o yoga-rtc.service
6. B/install/camera/camera-stage1-check.sh (d34e6d37...)
7. B/install/power/yoga-thermal-load.py (ad4d2e44...)

No slot try: vmlinuz e initramfs.img copiados do current (7e8e0bb7... e 23e25dec...), board.dtb = item 1, args.cfg com a linha de blacklist_cmdline.

Criados no notebook por "yoga-audio.sh prep": /usr/lib/firmware/qcom/glymur/GLYMUR-LENOVO-Yoga-Slim7x-tplg.bin (sha256 ea851335...4db57) e o link /usr/share/alsa/ucm2/conf.d/glymur/glymur.conf. São inertes sem a placa.

Já estão no notebook: firmware do ADSP em /var/lib/yoga-fw e todos os módulos em /usr/lib/modules/7.4.0-rc1-yoga-kalambo+.

Não instalar nesta rodada: yoga-lid-blank e seu .service (precisam de sessão GNOME), yoga-rtc.service, pacotes do R4 e do Mesa.

RUNBOOK:
Nada disto foi executado; o notebook só foi lido. Um boot do slot try com o kernel em uso (7.4.0-rc1-yoga-kalambo+) e o gwnx2.

**Por que multi-user.target e não GNOME:** o WirePlumber da sessão gráfica abriria a placa de som assim que ela registrasse e aplicaria o UCM fora do controle do roteiro. Em multi-user as teclas do EC se conferem pelo dmesg e a tampa e a chave da câmera por debugfs e busctl. Perde-se só o OSD do GNOME e o script de apagar a tela, que fica para depois.

Variáveis no PC:
B=<workspace>/fedora-vivobook-x1407q/.worktrees/lenovo-yoga-slim7-14q8y11-x2plus/ports/lenovo-yoga-slim7-14q8y11
SSH="ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@<ip-do-notebook>"

Regras gerais do boot de teste:
- Nunca rmmod, exceto yoga_ec_test.
- Nunca escrever em remoteproc.
- Desfazer é reiniciar.
- Manter um segundo SSH com "dmesg -w".
- Aborto geral: tela preta com SSH morto por 3 min -> segurar o botão de energia ~10 s e religar. O boot seguinte cai em current, porque o next_entry já foi apagado. Panic reinicia sozinho em 30 s.

## P. Preparação (slot current, sem reboot)

P1. Copiar do PC:
$SSH 'mkdir -p /root/gwnx2'
scp -i ~/.ssh/id_ed25519 $B/local/dtb-bisect-r5/kalambo-gwnx2.dtb $B/install/audio/yoga-audio.sh $B/install/ec-rtc/ec-tool.py $B/install/ec-rtc/extmod-ec/yoga-ec-test.ko $B/install/ec-rtc/rtc-fallback/yoga-rtc $B/install/camera/camera-stage1-check.sh $B/install/power/yoga-thermal-load.py root@<ip-do-notebook>:/root/gwnx2/

P2. No notebook:
cd /root/gwnx2 && sha256sum kalambo-gwnx2.dtb      # e281bc2012bf27cef36f97ef62b4f14ae3947000ceb9dd2e0ce303644be15605
grep -o 'yoga/[a-z]*/vmlinuz' /proc/cmdline        # yoga/current/vmlinuz
chmod +x yoga-audio.sh yoga-rtc && ./yoga-audio.sh prep     # "OK" no sha256 da topologia

P3. Opcional, linha de base térmica (frente térmica, A0):
python3 /root/gwnx2/yoga-thermal-load.py 180 95000
Anotar Tmax, fan_rpm e se abortou aos 95 °C. No current não há throttle do kernel; o script aborta sozinho.

P4. Opcional, etapa 0 do EC (decide como ler o IRQ depois; se desfaz com o bind):
Bn=$(basename /sys/devices/platform/soc@0/ac0000.geniqup/a84000.i2c/i2c-*); D=${Bn#i2c-}-0070
echo $D > /sys/bus/i2c/drivers/lenovo-yoga-slim7x-gen11-ec/unbind
python3 /root/gwnx2/ec-tool.py status; python3 /root/gwnx2/ec-tool.py drain; python3 /root/gwnx2/ec-tool.py watch 60
Usuário aperta mic mute, modo avião, Fn+Esc, Fn+Espaço; anotar os códigos.
echo $D > /sys/bus/i2c/drivers/lenovo-yoga-slim7x-gen11-ec/bind
"gpio66 continua pulsando" NÃO aborta a frente: o pino está com pull-down do firmware e a etapa 3 abaixo testa com pull-up.

P5. Montar o slot try. Ele guarda hoje o teste T2 de vídeo (gwnd1, 7941b126...); combinar a vez. A cópia abaixo o preserva.
cp -a /boot/yoga/try /root/try-antes-gwnx2
install -m 0644 /boot/yoga/current/vmlinuz /boot/yoga/try/vmlinuz
install -m 0600 /boot/yoga/current/initramfs.img /boot/yoga/try/initramfs.img
install -m 0644 /root/gwnx2/kalambo-gwnx2.dtb /boot/yoga/try/board.dtb
cat > /boot/yoga/try/args.cfg <<'EOF'
# gwnx2: gwnx1 + audio-card, usb-typec, camera, ec-node, rtc (plano B), lid, thermal. Carga manual.
set yoga_slot_args="panic=30 pcie_aspm=off nvme_core.default_ps_max_latency_us=0 initcall_blacklist=slim7x11_ec_driver_init systemd.unit=multi-user.target modprobe.blacklist=ucsi_glink,pmic_glink_altmode,qcom_pd_mapper,apr,fastrpc,snd_q6apm,q6prm,q6prm_clocks,q6apm_dai,q6apm_lpass_dais,snd_soc_lpass_wsa_macro,snd_soc_lpass_va_macro,soundwire_qcom,snd_soc_wsa884x,snd_soc_x1e80100,rtc_pm8xxx,phy_qcom_m31_eusb2,phy_qcom_eusb2_repeater"
EOF
grub2-script-check /boot/yoga/try/args.cfg && sha256sum /boot/yoga/try/board.dtb && cmp /boot/yoga/current/vmlinuz /boot/yoga/try/vmlinuz && cmp /boot/yoga/current/initramfs.img /boot/yoga/try/initramfs.img
Abortar se qualquer conferência falhar.

P6. Carregador DESLIGADO, nada nas USB, bateria >= 50 % (lida agora: 99 %).
sync; yoga-boot-once try && grub2-editenv /boot/efi/EFI/BOOT/grubenv list && systemctl reboot

O usuário vê o GRUB com "YOGA: slot=try", o texto do kernel e o console de texto (sem GNOME). A tela não pode apagar.

## 0. Linha de base (só leitura)

mkdir -p /root/gwnx2/log && cd /root/gwnx2/log
grep -o 'yoga/[a-z]*/vmlinuz' /proc/cmdline; uname -r                 # try; 7.4.0-rc1-yoga-kalambo+
sha256sum /sys/firmware/fdt                                            # e281bc20... (o GRUB pode alterar /chosen; se diferir, só anotar)
findmnt -no SOURCE /; ip -br a | grep wlP4; cat /sys/class/remoteproc/*/state; cat /sys/class/power_supply/qcom-battmgr-bat/{status,capacity}
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq; ls /sys/class/bluetooth
dmesg > 00-dmesg.txt; cat /sys/kernel/debug/regulator/regulator_summary > 00-reg.txt; cat /sys/kernel/debug/gpio > 00-gpio.txt; cat /sys/kernel/debug/devices_deferred > 00-deferred.txt; lsmod > 00-lsmod.txt; cat /proc/interrupts > 00-irq.txt
lsmod | grep -E 'eusb2|soundwire|snd_|rtc_pm8xxx|ucsi|q6' ; ls /sys/class/hwmon | wc -l; cat /proc/asound/cards 2>/dev/null
ls /sys/bus/spmi/devices | grep 2-0b; dmesg | grep -iE '2-0b|spmi.*(fail|error)'
dmesg --level=err,warn | grep -vi 'dummy regulator' | head -40

Esperado: igual ao current, com as seguintes diferenças previstas:
- sem USB (xhci ausente);
- sem hwmon do EC nem LED do teclado;
- nenhum módulo da lista do grep carregado;
- devices_deferred com 7760000.pinctrl mais a000000.usb, 88e0000.phy e os dois USB antigos à espera de PHY;
- soccp attached, bateria lendo, Wi-Fi, NVMe, cpufreq e Bluetooth como hoje.

Abortar o roteiro inteiro (reboot para o current) se o soccp não estiver attached, a bateria tiver sumido, a raiz não estiver no NVMe ou algum módulo bloqueado estiver carregado.

## 1. Tampa, chave da câmera e térmica (nós já ativos no boot; só leitura e ação física)

grep -B1 -A8 -E 'gpio-keys' /proc/bus/input/devices           # dois dispositivos: gpio-keys (SW=1) e gpio-keys-camera
grep -E 'gpio(92|99) ' /sys/kernel/debug/gpio                 # 92 "in high ... no pull"; 99 "in high ... pull up" (chave desbloqueada)
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed   # b false
grep -E 'lid|Camera privacy' /proc/interrupts                 # anotar; repetir após 5 s sem tocar: não pode crescer sozinho
sh /root/gwnx2/camera-stage1-check.sh

Físico:
- (a) Fechar a tampa ~5 s: gpio92 "in low", LidClosed b true, o SSH continua, nada suspende. Abrir: volta.
- (b) Deslizar a chave de privacidade para BLOQUEADO: gpio99 "in low" e o contador de "Camera privacy" sobe. Voltar: "in high".

Térmica:
for z in /sys/class/thermal/thermal_zone*; do case $(cat $z/type) in cpu-[01]-*) echo "$(cat $z/type) $(cat $z/trip_point_*_type | tr '\n' ' ') $(cat $z/trip_point_*_temp | tr '\n' ' ') $(ls $z | grep -c '^cdev[0-9]*$')";; esac; done
dmesg | grep -iE 'thermal|tsens' | grep -iE 'fail|error'

Sucesso:
- 24 zonas com critical 115000 e passive 105000, 1 cdev cada.
- Tampa e chave seguem o movimento nos dois sentidos.

Aborto (reboot):
- IRQ de lid ou câmera subindo aos milhares, ou spam no journal.

Não é aborto:
- gpio99 sempre alto com a chave bloqueada: a chave pode só soltar a linha e o pull-up esconder isso; anotar.
- Evento que não chega com o nível mudando: a IRQ sumária do TLMM fora do PDC nunca foi usada nesta máquina; anotar.
- Polaridade invertida: anotar.

## 2. RTC plano B (alias rtc1; não desloca o relógio)

date -u; modprobe rtc_pm8xxx; dmesg | tail -3; date -u
cat /sys/class/rtc/rtc1/since_epoch; ls /sys/class/rtc
/root/gwnx2/yoga-rtc save; cat /var/lib/yoga-rtc/offset        # perto de 1781315354; só grava com NTP sincronizado

Sucesso:
- "registered as rtc1", SEM "setting system clock".
- date igual antes e depois.

Aborto:
- Aparecer rtc0 ou o relógio pular: anotar e seguir, depois "chronyc makestep".

NÃO habilitar yoga-rtc.service: no current, sem o alias, ele registraria rtc0 e jogaria o relógio para 1970.

## 3. EC com IRQ (entrada com pull-up; se desfaz com rmmod yoga_ec_test)

ls /sys/bus/i2c/devices/*-0070/; ls /sys/bus/i2c/devices/*-0070/driver 2>&1     # existe, sem driver
insmod /root/gwnx2/yoga-ec-test.ko; dmesg | tail -5                            # "irq NNN, K evento(s) drenado(s) no probe"
for i in 1 2 3 4 5; do grep yoga-ec-test /proc/interrupts; sleep 2; done
grep 'gpio66 ' /sys/kernel/debug/gpio                                          # "in high ... pull up"
ls /sys/class/hwmon; ls /sys/class/leds | grep kbd

Físico: mic mute, modo avião, Fn+Esc, Fn+Espaço, um por vez.
dmesg deve mostrar "evento 0x18", "0x19", "0x0f" (e cat /sys/bus/i2c/devices/*-0070/fn_lock inverte) e "0x16".

Sucesso:
- Contador parado em repouso; eventos térmicos ou de bateria esporádicos são normais.
- hwmon e LED de volta.
- Ao menos Fn+Esc gera evento.

Aborto:
- Mais de ~5 IRQ/s em repouso por 10 s, "(fila NAO esvaziou)", erros de i2c repetidos, teclado ou touchpad parando -> rmmod yoga_ec_test e seguir sem EC.

Se nenhuma tecla gerar evento: anotar (hipótese do bit 0x40 de 0xA3). Não usar "ps0 --write" neste boot.

## 4. Carga térmica com o DT novo (usar ssh -t para a queda do SSH matar a carga)

ssh -t ... 'python3 /root/gwnx2/yoga-thermal-load.py 180 95000'
Usuário: sentir o ar da ventoinha; fan_rpm deve subir (o EC foi carregado na etapa 3).

- Se ficar abaixo de 95 °C: proteção instalada mas não exercitada; encerrar aqui.
- Aborto: automático aos 95 °C; Ctrl-C se subir mais de 5 °C entre duas linhas perto de 90 °C.
- A variante com limiar 110000 NÃO roda aqui: fica para o fim (etapa 8), porque um desligamento aos 115 °C perderia as etapas seguintes.

## 5. USB: três controladores (frente usb-typec, parte 1). Carregador desligado, nada plugado.

Material: o pendrive do projeto e um dispositivo só-USB2 (mouse ou teclado com adaptador C).

ls /sys/bus/spmi/devices | grep 2-0b && dd if=/sys/kernel/debug/regmap/2-0b/registers bs=9 skip=$((0x100)) count=6 2>/dev/null    # 0104: 51, 0105: 5f
Sem 2-0b ou com erro de probe: o SID 0xb não responde; seguir só com usb_0 e usb_1 e reportar.

GUARDA (não carregar se algum der use 0 ou se o Wi-Fi estiver fora):
grep -E '^ +vreg_(l4f1|l1f1|l2f1) ' /sys/kernel/debug/regulator/regulator_summary     # use >= 1 nos três
Motivo: esses trilhos também são do PHY eDP e os HOLD_* não seguram nada neste kernel.

cat /sys/kernel/debug/regulator/regulator_summary > 05-reg-antes.txt
modprobe phy_qcom_eusb2_repeater; dmesg | tail -5
modprobe phy_qcom_m31_eusb2; sleep 3; dmesg | grep -E 'xhci|dwc3|eusb|88e0000|a000000' | tail -30
readlink -f /sys/bus/usb/devices/usb*; grep -H . /sys/kernel/debug/usb/xhci/*/ports/port01/portsc
Anotar o mapa usbN / xhci-hcd.N -> a600000 / a800000 / a000000. Não assumir número de barramento.

Sucesso:
- Três "xHCI Host Controller", 6 root hubs.
- Tela, Wi-Fi, SSH e NVMe intactos.

Aborto:
- Tela apaga, SSH cai, erros de NVMe, "initialization timed-out" em 2-0b -> não descarregar nada, salvar dmesg e reiniciar.
- a000000 preso em devices_deferred, sozinho, NÃO é aborto: falha limpa da usb_2 (provável CLK7_A); seguir com dois controladores.

Mapa físico (E-T = esquerda junto à dobradiça, E-F = esquerda junto ao usuário, D = direita):
- Plugar o pendrive em cada porta, 10 s, nas duas orientações se não detectar. A cada vez: "dmesg | tail -5" e os portsc; anotar se o LED acendeu.
- Na porta que não detectar, repetir com o dispositivo só-USB2.
- LED apagado e sem CCS = falta VBUS (a etapa 7 mostra).
- LED aceso sem CCS nem com o só-USB2 = caminho D+/D-.
- Só o USB2 puro detecta = pendrive tentando SuperSpeed.

Tirar tudo das portas ao terminar.

## 6. Áudio (frente audio-card). Maior risco de panic: as macros escrevem em MMIO do LPASS.

pgrep -a 'wireplumber|pipewire'      # tem de estar vazio (multi-user); se não, parar a frente
/root/gwnx2/yoga-audio.sh status     # soccp attached, adsp offline, "no soundcards"

Uma etapa por vez, lendo o dmesg entre elas:
1. /root/gwnx2/yoga-audio.sh adsp     -> "adsp running". Não repetir mais de uma vez.
2. /root/gwnx2/yoga-audio.sh svc      -> gpio12/13 do LPASS "in low". Até UMA linha "CMD timeout for [1001021]" é esperada. Segundo timeout, "ADSP crashed" ou bateria sumindo = parar.
3. /root/gwnx2/yoga-audio.sh macros   -> "macros ok". SError ou panic reinicia sozinho em 30 s e volta ao current.
4. /root/gwnx2/yoga-audio.sh amps     -> 4 linhas "sdw:... Attached", gpio12/13 "out high". Usuário com o ouvido perto: um estalo leve é aceitável; chiado contínuo ou calor não. Com 2 de 4 ou 0: parar e reportar (resultado válido).
5. /root/gwnx2/yoga-audio.sh card     -> placa "GLYMUR-LENOVO-Yoga-Slim7x" em /proc/asound/cards; aplay -l com MultiMedia1.
6. /root/gwnx2/yoga-audio.sh mixer    -> Digital Volume 54, PA 0.
7. /root/gwnx2/yoga-audio.sh tone     -> voz baixa dizendo o canal em cada um dos 4 alto-falantes.

Se não houver som nem erro, escalar SÓ assim: "mixer 66 6" e tone; depois "mixer 75 6" e tone. NUNCA PA acima de 6: o kernel limita a 6 e "mixer 75 12" falha no meio, embora o script aceite 12.

NÃO rodar "mic" nesta tentativa: ele liga e desliga o vreg_l1b0, hoje com use 0.

Guardar:
/root/gwnx2/yoga-audio.sh status > 06-audio-status.txt; amixer -c0 contents > 06-amixer.txt 2>&1

Sucesso:
- Placa registrada e voz audível, com SoCCP attached e bateria lendo.

Parcial aceitável:
- Placa sem som (suspeitas: boost externo dos WSA, topologia do CRD).

Aborto imediato (Ctrl-C):
- Som distorcido ou alto, chiado contínuo, cheiro ou calor.
- "graph open/prepare failed" ou CMD timeout repetido.

## 7. UCSI estágio A (frente usb-typec, parte 2). Uma tentativa; maior risco para o SoCCP.

Pré-condições:
- Carregador desligado, nada plugado.
- cat /sys/class/remoteproc/*/state mostra attached.
- ls /sys/bus/auxiliary/devices | grep ucsi mostra pmic_glink.ucsi.N.

modprobe ucsi_glink
sleep 10; ls /sys/class/typec; grep . /sys/class/typec/port*/{data_role,power_role,power_operation_mode} 2>/dev/null; cat /sys/class/power_supply/qcom-battmgr-bat/{status,capacity}; ls /sys/class/power_supply

Sucesso:
- port0..port2 registradas, bateria respondendo, nenhuma linha de remoteproc do soccp.

Depois:
- Ligar o carregador em cada porta, uma por vez. Anotar qual portN ganha portN-partner e se vai a Charging.
- Plugar o pendrive em cada porta. Anotar portN (power_role source) e o controlador xHCI que enumera.

Restrições:
- NÃO plugar dock, monitor ou adaptador DP: typec_displayport é =m e poderia mandar SET_NEW_CAM.
- NÃO carregar pmic_glink_altmode.

Aborto:
- "failed to reset PPM", "timeout waiting for UCSI", crash, fatal ou watchdog do soccp, bateria sumindo -> não mexer em remoteproc; salvar dmesg e "systemctl reboot".

## 8. Opcional, por último: throttle real

Só se a etapa 4 (ou P3) abortou aos 95 °C, com o usuário presente e a etapa 1 mostrando cdev=1 nas 24 zonas:
ssh -t ... 'python3 /root/gwnx2/yoga-thermal-load.py 300 110000'

- Ao cruzar 105000 a coluna cdev_cpufreq sai de 0 e freq_kHz cai.
- Ctrl-C se cdev continuar 0 acima de 106 °C.
- O crítico de 115 °C desliga a máquina; a margem é de 5 °C.

## 9. Coleta e saída

dmesg > 99-dmesg.txt; journalctl -k -b > 99-journal-k.txt; cat /sys/kernel/debug/regulator/regulator_summary > 99-reg.txt; cat /sys/kernel/debug/gpio > 99-gpio.txt; cat /proc/interrupts > 99-irq.txt; lsmod > 99-lsmod.txt; sync
systemctl reboot     # volta sozinho ao current (gwnx1), sem nada desta rodada ativo
Copiar /root/gwnx2/log para o PC em B/local/physical-2026-11-16/gwnx2/.

Critério global do boot: SoCCP attached, bateria lendo, tela acesa, Wi-Fi, SSH e NVMe do começo ao fim. Cada frente tem veredito próprio; falha de uma não invalida as anteriores.

# Boots seguintes (ordem recomendada)

1. **Kernel R4 com o DTB atual (gwnx1, df7359ea...) no slot try**, pelo roteiro da frente kernel-r4 (B/local/iso-build/kernel-out-r4/dist, initramfs com --confdir sem os dois pwrseq, panic=30 e systemd.mask=firewalld.service). Correções obrigatórias:
   - Os "modprobe -S -n" valem só por rc=0.
   - O teste do firewalld usa unidades transitórias, porque o unmask não desfaz a máscara da cmdline:
     systemd-run --on-active=180 --unit=fw-safety systemctl stop fw-test
     systemd-run --unit=fw-test /usr/bin/firewalld --nofork --nopid
     Abrir outro SSH; se abrir, "firewall-cmd --list-all" e "systemctl stop fw-safety.timer fw-test".
   - Se o R4 falhar sem log, testar o R3 e depois o R2 isolados.
   - É boot separado do gwnx2 para não somar duas incógnitas: o R4 nunca deu boot.

2. **Mesa X2-45 (sem reboot próprio):** num boot limpo do current, GPU por carga manual, depois o pacote de /opt/mesa-x2-45. Correções obrigatórias:
   - Logo após "modprobe msm separate_gpu_kms=1": "ls /sys/class/devfreq/", "cat /sys/class/devfreq/3d00000.gpu/available_frequencies" e "echo 760000000 > /sys/class/devfreq/3d00000.gpu/max_freq" (ou outro OPP baixo listado). O fuse 193 habilita todos os OPPs até 1,85 GHz; não os limita.
   - Cada teste com "timeout -k 5 60 mesa-x2-45-env egl-offscreen-test.py ...".
   - Passo do Niri com cópia do config.kdl e expectativa de 5-10 %.
   - Não rodar no mesmo boot do gwnx2 nem com msm em modo KMS.

3. **Promoção do gwnx2 ao current**, se o boot de teste passou:
   - Decidir frente a frente o que deixa de ser bloqueado: EC sem initcall_blacklist e yoga-ec.service desabilitado; tampa, câmera e térmica já são automáticas.
   - Manter phy_qcom_m31_eusb2 e phy_qcom_eusb2_repeater bloqueados com carga por serviço depois do Wi-Fi, OU aceitar a usb_2 subindo no initramfs antes de o Wi-Fi segurar l1f1/l2f1/l4f1. Isso é risco para a tela e pede um boot de teste próprio.
   - Aí sim testar yoga-lid-blank no GNOME: conferir antes com "gdbus monitor" que o logind emite LidClosed; usar "systemctl --user -M <usuario>@ enable --now yoga-lid-blank.service".

4. **RTC plano A em boot próprio:** DTB B/install/ec-rtc/dtb/kalambo-gwnx1-ecrtc.dtb (401a3cc3...) ou gwnx2 sem o #define, args com efi_pstore.pstore_disable=1 e rtc_pm8xxx bloqueado. Parar o chronyd antes do "modprobe rtc_pm8xxx", conferir RTCInfo antes de carregar, "rmmod rtc_pm8xxx" antes de desligar no primeiro teste. Se o boot travar no início, power cycle. Se o plano B bastou, instalar o yoga-rtc.service só junto com um DTB que tenha o alias, trocando o "timedatectl show" do save por algo que não dependa de D-Bus no shutdown.

5. **Vídeo real permanente** (gwnxd1, trilha separada) e depois o combinado gwnx2 + vídeo. Com KMS real: GNOME sobre msm, wrapper do Mesa na sessão, brilho.

6. **Variantes opcionais, uma por boot e com aceite explícito:** áudio com -DYOGA_AUDIO_DMIC_PINS mais a etapa "mic"; câmera com -DYOGA_CAMERA_PRIVACY_LED.

7. **Dependem de kernel novo ou de decisão:**
   - Câmera etapa 2: GPIOs 106/239/109 só com evidência do PEP do Windows; PM8010; nós CCI e CAMSS.
   - s2idle: só com R4 + pm-debug.config e, de preferência, o patch keep-link, nunca no kernel em uso.
   - UCSI estágio B: mexe em pmic-glink.
   - Speed-bin 193 no kernel.

CAVEATS:
- **Nada foi testado no hardware.** O gwnx2 só foi compilado e comparado; o notebook foi apenas lido, no slot current com 7.4.0-rc1-yoga-kalambo+. A combinação das sete frentes num boot nunca rodou; as probabilidades de cada frente são as dos revisores e não se multiplicam bem.

- **O boot do try não é idêntico ao current sem carga manual.** Diferenças:
  - tampa e chave da câmera dão probe no boot (gpio-keys é =y);
  - o gpio99 troca de pull-down para pull-up;
  - o tsens ganha o limiar de 105 °C;
  - o pmic 2-0b é lido;
  - todo o USB fica desligado até a etapa 5;
  - o EC fica sem hwmon nem LED até a etapa 3;
  - sem GNOME.

- **Os HOLD_* não seguram nada neste kernel** (achado da frente USB: use_count 0, core.c:1479-1487). A proteção de l1f1/l2f1/l4f1, que também alimentam o PHY eDP, é só a guarda "Wi-Fi de pé" da etapa 5. Com o Wi-Fi fora, não carregar os PHYs. Isso vale para as outras frentes que contavam com HOLD.

- **O script de áudio aceita PA até 12, mas o kernel limita a 6.** O roteiro manda parar em 6. O script é da frente e não foi editado por mim.

- **Dois módulos novos na blacklist dependem da cmdline.** O initramfs é hostonly=no e contém módulos de eUSB2. A blacklist da cmdline vale para a carga por alias no initramfs, o mesmo mecanismo que já segura msm e áudio hoje. A etapa 0 confere com lsmod antes de qualquer carga.

- **initcall_blacklist=slim7x11_ec_driver_init:** o símbolo existe no System.map do kernel em uso (conferido). Com isso o yoga-ec.service vira no-op, porque o cliente N-0070 vem do DT. Sem o parâmetro, o driver embutido daria probe com IRQ no initramfs.

- **RTC:** entrou o plano B, por decisão minha, para não arriscar o boot comum com o qseecom. O plano A fica para um boot próprio. O yoga-rtc.service não deve ser habilitado enquanto o current for gwnx1.

- **Hipóteses herdadas das frentes, que o boot resolve:**
  - SID 0xb do repetidor L e CLK7_A para a usb_2;
  - 4 amplificadores e topologia do CRD;
  - boost externo dos WSA;
  - polaridade do reset dos amplificadores (não está no DSDT);
  - a IRQ sumária do TLMM para o gpio99;
  - o pulso de 25 Hz do gpio66;
  - a posição física das portas.

- **Slot try ocupado:** ele guarda o teste T2 de vídeo (gwnd1). O roteiro salva uma cópia em /root/try-antes-gwnx2, mas a vez precisa ser combinada com a frente de vídeo.

- **sha256 de /sys/firmware/fdt:** pode não bater com o arquivo, porque o GRUB e o kernel mexem em /chosen. É conferência informativa.

- **Verificação estrutural:** o fdtdiff2.py aceita como igual a célula que é phandle nos dois lados apontando para o mesmo caminho. Um inteiro que coincidisse com phandles equivalentes passaria, o que é improvável. A igualdade com a união dos cinco DTBs das frentes é a segunda conferência.

- **O gwnx2 não foi compilado contra a árvore do R4.** A frente R4 mostrou que os DTBs anteriores saem idênticos, mas o gwnx2 não entrou nessa conta. O boot do R4 usa o gwnx1.

- **Arquivos criados por mim**, todos sob o worktree .../ports/lenovo-yoga-slim7-14q8y11/:
  - dts/kalambo-lenovo-yoga-slim7x-gwnx2.dts
  - local/dtb-bisect-r5/kalambo-gwnx2.dtb
  - local/dtb-bisect-r5/kalambo-gwnx2.vs-gwnx1.diff
  - local/dtb-bisect-r5/fdtdiff2.py
  Intermediários ficaram no scratchpad da sessão. Nenhum fragmento, kernel, kernel-out* ou arquivo de outra frente foi alterado; nenhum commit; nenhuma escrita no notebook.

- **Ferramentas:** não usei as ferramentas de orquestração (ruflo, Workflow, CodeGraph), porque esta etapa é um subagente de escopo fixo sobre DTS, sem índice .codegraph. Os servidores MCP codex, desktop-commander e github falharam ao conectar e não eram necessários.
