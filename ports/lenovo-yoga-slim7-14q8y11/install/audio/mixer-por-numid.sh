# ajuste por numid: o amixer por nome falha quando a leitura do registrador da -EBUSY
L=/root/gwnx2/log/06-controls.txt; DV=${1:-54}; PA=${2:-0}; [ "$DV" -le 81 ] && [ "$PA" -le 6 ] || exit 2
s(){ n=$(grep -F "name='$1'" $L | head -1 | sed "s/numid=\([0-9]*\).*/\1/"); [ -n "$n" ] || { echo "sem controle $1"; exit 1; }; amixer -q -c0 cset numid=$n "$2" || { echo "FALHOU $1"; exit 1; }; }
for x in WooferLeft TweeterLeft WooferRight TweeterRight; do s "$x PA Volume" $PA; done
for m in WSA WSA2; do s "$m WSA_RX0 Digital Volume" $DV; s "$m WSA_RX1 Digital Volume" $DV; s "$m WSA RX0 MUX" AIF1_PB; s "$m WSA RX1 MUX" AIF1_PB; s "$m WSA_RX0 INP0" RX0; s "$m WSA_RX1 INP0" RX1; s "$m WSA_COMP1 Switch" 0; s "$m WSA_COMP2 Switch" 0; done
s "WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1" 1
for x in WooferLeft TweeterLeft WooferRight TweeterRight; do s "$x COMP Switch" 1; s "$x BOOST Switch" 1; s "$x PBR Switch" 1; s "$x VISENSE Switch" 0; s "$x WSA MODE" 0; s "$x DAC Switch" 1; done
echo "mixer ok DV=$DV PA=$PA"
