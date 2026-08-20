#!/bin/bash

set -uo pipefail

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    echo '{"state":"ERROR","message":"No domain specified"}'
    exit 1
fi

# Validacao simples de formato de dominio
if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
    echo "{\"state\":\"ERROR\",\"message\":\"Invalid domain format: $DOMAIN\"}"
    exit 1
fi

# --------------------------------------------------------------------
# Normaliza qualquer formato de data para YYYY-MM-DD
# Suporta:
#   ISO 8601      -> 2027-04-02T13:58:50Z
#   YYYY-MM-DD    -> 2026-11-25
#   YYYYMMDD      -> 20261125          (Registro.br)
#   DD/MM/YYYY    -> 25/11/2026
#   DD.MM.YYYY    -> 25.11.2026
# --------------------------------------------------------------------
normalize_date() {

    local RAW
    RAW=$(echo "$1" | tr -d '\r' | awk '{$1=$1; print}')

    [ -z "$RAW" ] && return 1

    local NORM=""

    if [[ "$RAW" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        # ISO ou YYYY-MM-DD
        NORM="${RAW:0:10}"

    elif [[ "$RAW" =~ ^[0-9]{8}$ ]]; then
        # YYYYMMDD (Registro.br)
        NORM="${RAW:0:4}-${RAW:4:2}-${RAW:6:2}"

    elif [[ "$RAW" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4}) ]]; then
        # DD/MM/YYYY
        NORM="${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"

    elif [[ "$RAW" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4}) ]]; then
        # DD.MM.YYYY
        NORM="${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"

    else
        # Ultima tentativa: deixar o date interpretar
        NORM=$(date -d "$RAW" '+%Y-%m-%d' 2>/dev/null)
    fi

    # Valida se o resultado e uma data reconhecivel
    date -d "$NORM" '+%Y-%m-%d' 2>/dev/null
}

# --------------------------------------------------------------------
# RDAP - fonte primaria
# --------------------------------------------------------------------
get_rdap_expiry() {

    local DOMAIN="$1"

    curl -sL \
        -H "Accept: application/rdap+json" \
        --connect-timeout 10 \
        --max-time 20 \
        "https://rdap.org/domain/${DOMAIN}" \
    | jq -r '
        .events[]? |
        select(
            .eventAction=="expiration"
            or .eventAction=="expiry"
            or .eventAction=="expire"
        ) |
        .eventDate
    ' 2>/dev/null | head -1
}

# --------------------------------------------------------------------
# WHOIS - fallback
# Alguns TLDs precisam de servidor WHOIS especifico porque o cliente
# do Debian usa referencias antigas que nao resolvem mais em DNS.
# --------------------------------------------------------------------
get_whois_expiry() {

    local DOMAIN="$1"
    local TLD="${DOMAIN##*.}"
    local WHOIS_OUTPUT=""

    case "$TLD" in
        vc)
            # TLD .vc e operado pela Identity Digital
            WHOIS_OUTPUT=$(timeout 20 whois -h whois.identitydigital.services "$DOMAIN" 2>/dev/null)
            ;;
        br)
            # TLD .br e operado pelo Registro.br
            WHOIS_OUTPUT=$(timeout 20 whois -h whois.registro.br "$DOMAIN" 2>/dev/null)
            ;;
        *)
            WHOIS_OUTPUT=$(timeout 20 whois "$DOMAIN" 2>/dev/null)
            ;;
    esac

    echo "$WHOIS_OUTPUT" | grep -iE \
        'Registry Expiry Date:|Registrar Registration Expiration Date:|Expiration Date:|Expiry Date:|expire-date:|^expires:|paid-till:' \
        | head -1 \
        | sed -E 's/^[^:]+:[[:space:]]*//' \
        | tr -d '\r' \
        | awk '{$1=$1; print}'
}

# --------------------------------------------------------------------
# Calculo de dias restantes
# --------------------------------------------------------------------
calculate_days() {

    local DATE="$1"

    EXPIRY=$(date -d "$DATE 12:00:00" +%s 2>/dev/null)

    if [ -z "$EXPIRY" ]; then
        return 1
    fi

    NOW=$(date -d "$(date +%Y-%m-%d) 12:00:00" +%s 2>/dev/null)

    echo $(( (EXPIRY - NOW) / 86400 ))
}

# --------------------------------------------------------------------
# Fluxo principal
# --------------------------------------------------------------------
EXPIRY=""
SOURCE=""

# Primeiro tenta RDAP
EXPIRY=$(get_rdap_expiry "$DOMAIN")

if [ -n "$EXPIRY" ]; then
    SOURCE="RDAP"
else
    # Se RDAP falhar tenta WHOIS
    EXPIRY=$(get_whois_expiry "$DOMAIN")
    SOURCE="WHOIS"
fi

if [ -z "$EXPIRY" ]; then
    echo "{\"state\":\"ERROR\",\"message\":\"Could not retrieve expiration date\",\"domain\":\"$DOMAIN\"}"
    exit 1
fi

# Normaliza a data para YYYY-MM-DD
EXPIRY_DATE=$(normalize_date "$EXPIRY")

if [ -z "$EXPIRY_DATE" ]; then
    echo "{\"state\":\"ERROR\",\"message\":\"Could not parse expiration date\",\"raw\":\"$EXPIRY\",\"domain\":\"$DOMAIN\"}"
    exit 1
fi

DAYS_LEFT=$(calculate_days "$EXPIRY_DATE")

if [ -z "$DAYS_LEFT" ]; then
    echo "{\"state\":\"ERROR\",\"message\":\"Could not calculate days\",\"expire_date\":\"$EXPIRY_DATE\"}"
    exit 1
fi

STATE="OK"

if [ "$DAYS_LEFT" -lt 0 ]; then
    STATE="EXPIRED"
elif [ "$DAYS_LEFT" -lt 7 ]; then
    STATE="CRITICAL"
elif [ "$DAYS_LEFT" -lt 30 ]; then
    STATE="WARNING"
fi

echo "{\"state\":\"$STATE\",\"days_left\":$DAYS_LEFT,\"expire_date\":\"$EXPIRY_DATE\",\"source\":\"$SOURCE\"}"
