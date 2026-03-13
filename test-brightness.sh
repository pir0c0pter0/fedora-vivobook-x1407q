#!/bin/bash
# =============================================================================
# test-brightness.sh - Teste SEGURO de brilho via DPCD com rollback automatico
#
# Salva o estado atual, aplica a mudanca, espera 15s.
# Se o usuario nao confirmar, restaura tudo automaticamente.
# =============================================================================

set -u

AUX=/dev/drm_dp_aux2
TIMEOUT=15

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Funcao para ler 1 byte do DPCD
dpcd_read() {
    dd if="$AUX" bs=1 skip=$(($1)) count=1 2>/dev/null | od -A n -t u1 | tr -d ' '
}

# Funcao para escrever 1 byte no DPCD
dpcd_write() {
    printf "\\x$(printf '%02x' $2)" | dd of="$AUX" bs=1 seek=$(($1)) count=1 2>/dev/null
}

# Salvar estado atual
echo -e "${YELLOW}[1/4] Salvando estado atual...${NC}"
ORIG_720=$(dpcd_read 0x720)
ORIG_721=$(dpcd_read 0x721)
ORIG_722=$(dpcd_read 0x722)
ORIG_723=$(dpcd_read 0x723)
echo "  0x720=$ORIG_720  0x721=$ORIG_721  0x722=$ORIG_722  0x723=$ORIG_723"

# Funcao de rollback
rollback() {
    echo ""
    echo -e "${RED}[ROLLBACK] Restaurando estado original...${NC}"
    dpcd_write 0x722 "$ORIG_722"
    dpcd_write 0x723 "$ORIG_723"
    dpcd_write 0x721 "$ORIG_721"
    dpcd_write 0x720 "$ORIG_720"
    echo -e "${GREEN}[OK] Restaurado: 0x720=$ORIG_720 0x721=$ORIG_721 0x722=$ORIG_722 0x723=$ORIG_723${NC}"
}

# Trap para rollback em caso de Ctrl+C
trap rollback EXIT

# Determinar o teste a executar
TEST="${1:-1}"

case "$TEST" in
    1)
        echo -e "${YELLOW}[2/4] TESTE 1: Apenas brightness MSB (0x722=0x08, ~25%)${NC}"
        echo "  Escrevendo SOMENTE 0x722, sem tocar em 0x720/0x721"
        dpcd_write 0x722 8
        ;;
    2)
        echo -e "${YELLOW}[2/4] TESTE 2: Backlight enable + DPCD mode + brightness${NC}"
        echo "  0x720=0x01 (BACKLIGHT_ENABLE, sem BLACK_VIDEO)"
        echo "  0x721=0x02 (DPCD brightness mode)"
        echo "  0x722=0x10 (~50%)"
        dpcd_write 0x720 1    # bit 0 = BACKLIGHT_ENABLE
        dpcd_write 0x721 2    # DPCD brightness mode
        dpcd_write 0x722 16   # ~50% brightness
        ;;
    3)
        echo -e "${YELLOW}[2/4] TESTE 3: Backlight enable + PWM mode + brightness${NC}"
        echo "  0x720=0x01 (BACKLIGHT_ENABLE)"
        echo "  0x721=0x00 (PWM pin mode)"
        echo "  0x722=0x08 (~25%)"
        dpcd_write 0x720 1
        dpcd_write 0x721 0
        dpcd_write 0x722 8
        ;;
    4)
        VAL="${2:-16}"
        echo -e "${YELLOW}[2/4] TESTE 4: Custom brightness MSB=$VAL${NC}"
        echo "  0x720=0x01 0x721=0x02 0x722=$VAL"
        dpcd_write 0x720 1
        dpcd_write 0x721 2
        dpcd_write 0x722 "$VAL"
        ;;
    *)
        echo "Uso: $0 [1|2|3|4] [valor]"
        echo "  1 = So brightness MSB (mais seguro)"
        echo "  2 = Enable + DPCD mode + brightness"
        echo "  3 = Enable + PWM mode + brightness"
        echo "  4 = Custom (ex: $0 4 20)"
        trap - EXIT
        exit 0
        ;;
esac

# Ler estado apos mudanca
echo ""
echo -e "${YELLOW}[3/4] Estado apos mudanca:${NC}"
echo "  0x720=$(dpcd_read 0x720)  0x721=$(dpcd_read 0x721)  0x722=$(dpcd_read 0x722)  0x723=$(dpcd_read 0x723)"

# Countdown com possibilidade de confirmar
echo ""
echo -e "${GREEN}Mudou o brilho? Responda em ${TIMEOUT}s:${NC}"
echo -e "  ${GREEN}s${NC} = SIM, manter  |  qualquer tecla ou timeout = ROLLBACK"
echo ""

CONFIRMED=false
for i in $(seq "$TIMEOUT" -1 1); do
    printf "\r  Rollback em %2ds... (tecle 's' para manter) " "$i"
    if read -t 1 -n 1 resp 2>/dev/null; then
        if [[ "$resp" == "s" || "$resp" == "S" ]]; then
            CONFIRMED=true
            break
        else
            break
        fi
    fi
done
echo ""

if $CONFIRMED; then
    echo -e "${GREEN}[OK] Mantendo configuracao!${NC}"
    trap - EXIT  # Remove rollback trap
else
    # rollback sera executado pelo EXIT trap
    echo -e "${YELLOW}Nao confirmado, fazendo rollback...${NC}"
fi
