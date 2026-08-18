#!/bin/bash
#
# check_domain.sh - Monitor domain expiration dates using RDAP or WHOIS protocols
# Versao corrigida para Zabbix 5.0
#
# Usage: check_domain.sh <domain>
# Example: check_domain.sh example.com
#
# Output: JSON {"state":"OK","days_left":365,"expire_date":"2027-08-18"}
#

set -euo pipefail

# Configuration
TIMEOUT_RDAP=${TIMEOUT_RDAP:-5}
TIMEOUT_WHOIS=${TIMEOUT_WHOIS:-10}
EXPIRY_WARNING_DAYS=${EXPIRY_WARNING_DAYS:-30}
EXPIRY_CRITICAL_DAYS=${EXPIRY_CRITICAL_DAYS:-7}

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Get RDAP bootstrap URL for TLD
get_rdap_bootstrap() {
    local tld="${1}"
    local bootstrap_url="https://rdap.org/bootstrap/domain/${tld}"
    
    curl -s --max-time "${TIMEOUT_RDAP}" "${bootstrap_url}" 2>/dev/null || echo ""
}

# Get RDAP service URL from bootstrap
get_rdap_service() {
    local bootstrap_data="${1}"
    local tld="${2}"
    
    # Try to extract RDAP service URL from bootstrap JSON
    local rdap_url
    rdap_url=$(echo "${bootstrap_data}" | jq -r '.services[] | select(.[] | test("'"${tld}"'$")) | .[0]' 2>/dev/null | head -1)
    
    if [[ -n "${rdap_url}" ]]; then
        echo "${rdap_url}"
    else
        # Fallback to default RDAP URL
        echo "https://rdap.org/domain/${tld}"
    fi
}

# Query RDAP for domain expiration
query_rdap() {
    local domain="${1}"
    local rdap_url="${2}"
    
    local rdap_data
    rdap_data=$(curl -s --max-time "${TIMEOUT_RDAP}" \
        -H "Accept: application/rdap+json" \
        "${rdap_url}/${domain}" 2>/dev/null) || return 1
    
    # Extract expiration date
    local expiry_date
    expiry_date=$(echo "${rdap_data}" | jq -r '.events[] | select(.eventAction=="expiration") | .eventDate' 2>/dev/null | head -1)
    
    if [[ -n "${expiry_date}" && "${expiry_date}" != "null" ]]; then
        echo "${expiry_date}"
        return 0
    fi
    
    # Try alternative JSON structure
    expiry_date=$(echo "${rdap_data}" | jq -r '.entities[] | select(.roles[] | test("registrar")) | .events[] | select(.eventAction=="expiration") | .eventDate' 2>/dev/null | head -1)
    
    if [[ -n "${expiry_date}" && "${expiry_date}" != "null" ]]; then
        echo "${expiry_date}"
        return 0
    fi
    
    return 1
}

# Query WHOIS for domain expiration
query_whois() {
    local domain="${1}"
    
    local whois_data
    whois_data=$(timeout "${TIMEOUT_WHOIS}" whois "${domain}" 2>/dev/null) || return 1
    
    # Try to extract expiration date from various WHOIS formats
    local expiry_date
    
    # Format: Registry Expiry Date: YYYY-MM-DD
    expiry_date=$(echo "${whois_data}" | grep -i "Registry Expiry Date:" | awk '{print $4}' | head -1)
    
    if [[ -n "${expiry_date}" ]]; then
        echo "${expiry_date}"
        return 0
    fi
    
    # Format: expire-date: YYYY-MM-DD
    expiry_date=$(echo "${whois_data}" | grep -i "expire-date:" | awk '{print $2}' | head -1)
    
    if [[ -n "${expiry_date}" ]]; then
        echo "${expiry_date}"
        return 0
    fi
    
    # Format: Expiry Date: DD/MM/YYYY
    expiry_date=$(echo "${whois_data}" | grep -i "Expiry Date:" | awk '{print $3}' | head -1)
    
    if [[ -n "${expiry_date}" ]]; then
        # Convert DD/MM/YYYY to YYYY-MM-DD
        local day month year
        day=$(echo "${expiry_date}" | cut -d'/' -f1)
        month=$(echo "${expiry_date}" | cut -d'/' -f2)
        year=$(echo "${expiry_date}" | cut -d'/' -f3)
        echo "${year}-${month}-${day}"
        return 0
    fi
    
    # Format: expires: YYYY-MM-DD
    expiry_date=$(echo "${whois_data}" | grep -i "^expires:" | awk '{print $2}' | head -1)
    
    if [[ -n "${expiry_date}" ]]; then
        echo "${expiry_date}"
        return 0
    fi
    
    # Format: Expiration Date: YYYY-MM-DD
    expiry_date=$(echo "${whois_data}" | grep -i "Expiration Date:" | awk '{print $3}' | head -1)
    
    if [[ -n "${expiry_date}" ]]; then
        echo "${expiry_date}"
        return 0
    fi
    
    # Format: paid-till: YYYY-MM-DD (RU domains)
    expiry_date=$(echo "${whois_data}" | grep -i "paid-till:" | awk '{print $2}' | head -1)
    
    if [[ -n "${expiry_date}" ]]; then
        echo "${expiry_date}"
        return 0
    fi
    
    return 1
}

# Calculate days until expiration
calculate_days_left() {
    local expiry_date="${1}"
    
    local expiry_epoch current_epoch days_left
    expiry_epoch=$(date -d "${expiry_date}" +%s 2>/dev/null) || return 1
    current_epoch=$(date +%s)
    
    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    echo "${days_left}"
}

# Main function
main() {
    # CORRECAO: Usar variavel de ambiente ou parametro posicional
    local DOMAIN_NAME="${1:-}"
    
    # Se nao recebeu parametro, tentar ZABBIX_MACRO ou falhar
    if [[ -z "${DOMAIN_NAME}" ]]; then
        echo '{"state":"ERROR","message":"No domain specified"}'
        exit 1
    fi
    
    # Validate domain format
    if ! [[ "${DOMAIN_NAME}" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo '{"state":"ERROR","message":"Invalid domain format"}'
        exit 1
    fi
    
    # Extract TLD
    local tld
    tld=$(echo "${DOMAIN_NAME}" | rev | cut -d'.' -f1 | rev)
    
    # Try RDAP first
    local expiry_date=""
    
    # Get RDAP bootstrap
    local bootstrap_data
    bootstrap_data=$(get_rdap_bootstrap "${tld}")
    
    if [[ -n "${bootstrap_data}" ]]; then
        local rdap_service
        rdap_service=$(get_rdap_service "${bootstrap_data}" "${tld}")
        
        if [[ -n "${rdap_service}" ]]; then
            expiry_date=$(query_rdap "${DOMAIN_NAME}" "${rdap_service}") || expiry_date=""
        fi
    fi
    
    # Fallback to WHOIS
    if [[ -z "${expiry_date}" ]]; then
        expiry_date=$(query_whois "${DOMAIN_NAME}") || expiry_date=""
    fi
    
    # Check if we got an expiration date
    if [[ -z "${expiry_date}" ]]; then
        echo '{"state":"ERROR","message":"Could not retrieve expiration date"}'
        exit 1
    fi
    
    # Calculate days left
    local days_left
    days_left=$(calculate_days_left "${expiry_date}") || {
        echo '{"state":"ERROR","message":"Could not calculate days left"}'
        exit 1
    }
    
    # Determine state
    local state="OK"
    if [[ ${days_left} -lt 0 ]]; then
        state="EXPIRED"
    elif [[ ${days_left} -lt ${EXPIRY_CRITICAL_DAYS} ]]; then
        state="CRITICAL"
    elif [[ ${days_left} -lt ${EXPIRY_WARNING_DAYS} ]]; then
        state="WARNING"
    fi
    
    # Output JSON
    printf '{"state":"%s","days_left":%d,"expire_date":"%s"}\n' \
        "${state}" "${days_left}" "${expiry_date}"
}

# Execute main function with all arguments
main "$@"