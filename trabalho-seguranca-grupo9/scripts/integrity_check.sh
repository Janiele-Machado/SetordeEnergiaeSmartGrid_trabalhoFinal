#!/usr/bin/env bash
# =============================================================================
# integrity_check.sh - Verificação de integridade com SHA-256
# Projeto : Trabalho Final de Segurança da Informação - Grupo 9
# Monitora: /etc/passwd, /etc/shadow, regras salvas do iptables (rules.v4)
#           e também as regras do iptables que estão ATIVAS em memória.
# Uso     : sudo ./integrity_check.sh --init    (cria a linha de base - "estado bom")
#           sudo ./integrity_check.sh --check   (compara com a linha de base)
# =============================================================================
set -uo pipefail

BASE_DIR="/var/lib/integrity"
BASELINE="${BASE_DIR}/baseline.sha256"          # hashes dos arquivos
LIVE_BASELINE="${BASE_DIR}/iptables_live.sha256" # hash das regras ativas
LOG_FILE="/var/log/integrity_check.log"
MONITORED_FILES=("/etc/passwd" "/etc/shadow" "/etc/iptables/rules.v4")

RED="\e[1;31m"; GREEN="\e[1;32m"; YELLOW="\e[1;33m"; RESET="\e[0m"

# Grava no log com data e hora
log() { echo "$(date '+%F %T') [$1] $2" >> "$LOG_FILE"; }

# Alerta: log + syslog (auth.alert) + aviso na tela de quem está logado
alert() {
    local text="$1"
    log "ALERTA" "$text"
    logger -p auth.alert -t integrity_check "$text" 2>/dev/null || true
    echo -e "${RED}[!!! ALERTA DE INTEGRIDADE !!!] ${text}${RESET}"
    command -v wall >/dev/null 2>&1 && echo "ALERTA DE INTEGRIDADE: $text" | wall 2>/dev/null
}

# Hash das regras ATIVAS do iptables, ignorando comentários (com data/hora)
# e contadores de pacotes [n:n], que mudam o tempo todo.
live_hash() {
    iptables-save | sed -e '/^#/d' -e 's/\[[0-9]\+:[0-9]\+\]//g' | sha256sum | awk '{print $1}'
}

do_init() {
    mkdir -p "$BASE_DIR" && chmod 700 "$BASE_DIR"
    : > "$BASELINE"
    for f in "${MONITORED_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            sha256sum "$f" >> "$BASELINE"
        else
            echo -e "${YELLOW}Aviso: $f não existe (rode firewall.sh antes?)${RESET}"
        fi
    done
    live_hash > "$LIVE_BASELINE"
    chmod 600 "$BASELINE" "$LIVE_BASELINE"
    log "INFO" "Linha de base criada/atualizada."
    echo -e "${GREEN}Linha de base criada em ${BASELINE}${RESET}"
    cat "$BASELINE"
}

do_check() {
    [[ -f "$BASELINE" ]] || { echo "Linha de base não existe. Rode: $0 --init"; exit 2; }
    local status=0 expected current

    for f in "${MONITORED_FILES[@]}"; do
        if [[ ! -f "$f" ]]; then
            alert "Arquivo AUSENTE: $f"; status=1; continue
        fi
        expected=$(awk -v f="$f" '$2==f {print $1}' "$BASELINE")
        current=$(sha256sum "$f" | awk '{print $1}')
        if [[ -z "$expected" ]]; then
            alert "Arquivo sem hash na linha de base: $f"; status=1
        elif [[ "$expected" != "$current" ]]; then
            alert "Arquivo ALTERADO: $f (esperado ${expected:0:16}... / atual ${current:0:16}...)"
            status=1
        else
            log "OK" "$f íntegro"
            echo -e "${GREEN}[OK]${RESET} $f"
        fi
    done

    # Regras do iptables ativas em memória
    current=$(live_hash)
    expected=$(cat "$LIVE_BASELINE" 2>/dev/null || echo "")
    if [[ "$expected" != "$current" ]]; then
        alert "Regras ATIVAS do iptables foram modificadas!"; status=1
    else
        log "OK" "Regras ativas do iptables íntegras"
        echo -e "${GREEN}[OK]${RESET} regras ativas do iptables"
    fi

    [[ $status -eq 0 ]] && log "INFO" "Verificação concluída: tudo íntegro."
    return $status
}

[[ $EUID -eq 0 ]] || { echo "Execute como root: sudo $0"; exit 1; }
touch "$LOG_FILE" && chmod 640 "$LOG_FILE"

case "${1:---check}" in
    --init)  do_init ;;
    --check) do_check ;;
    *) echo "Uso: $0 [--init | --check]"; exit 1 ;;
esac
