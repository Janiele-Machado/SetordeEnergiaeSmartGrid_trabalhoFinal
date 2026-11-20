#!/usr/bin/env bash
# =============================================================================
# integrity_check.sh - Verificação de integridade com SHA-256
# Projeto : Trabalho Final de Segurança da Informação - Grupo 9
# Monitora: /etc/passwd, /etc/shadow, regras salvas do iptables (rules.v4)
#           e também as regras do iptables que estão ATIVAS em memória.
# Uso     : sudo ./integrity_check.sh --init    (cria a linha de base - "estado bom")
#           sudo ./integrity_check.sh --check   (compara com a linha de base)
# A linha de base e um registro de hashes confiavel para comparacoes futuras.
# Proteja-a: quem altera tanto o arquivo monitorado quanto a linha de base pode
# esconder uma modificacao. --init substitui a linha de base existente.
# =============================================================================
# -e: interrompe em erros nao tratados; -u: falha ao usar variavel indefinida;
# pipefail: propaga falha de qualquer comando dentro de um pipeline.
set -uo pipefail

# Diretorio persistente onde ficam a linha de base dos arquivos e a hash das
# regras ativas. No Compose, esse caminho e montado num volume Docker.
BASE_DIR="/var/lib/integrity"
BASELINE="${BASE_DIR}/baseline.sha256"          # hashes dos arquivos
LIVE_BASELINE="${BASE_DIR}/iptables_live.sha256" # hash das regras ativas
LOG_FILE="/var/log/integrity_check.log"
MONITORED_FILES=("/etc/passwd" "/etc/shadow" "/etc/iptables/rules.v4")

RED="\e[1;31m"; GREEN="\e[1;32m"; YELLOW="\e[1;33m"; RESET="\e[0m"

# Acrescenta uma linha ao log, prefixada com data/hora e nivel (INFO, OK ou
# ALERTA). O log complementa a mensagem mostrada no terminal.
log() { echo "$(date '+%F %T') [$1] $2" >> "$LOG_FILE"; }

# Um alerta e enviado a tres canais quando disponiveis: arquivo de log, syslog
# auth.alert e terminais ativos via wall. A ausencia de logger ou wall nao
# impede a verificacao: esses canais sao complementares ao log principal.
alert() {
    local text="$1"
    log "ALERTA" "$text"
    logger -p auth.alert -t integrity_check "$text" 2>/dev/null || true
    echo -e "${RED}[!!! ALERTA DE INTEGRIDADE !!!] ${text}${RESET}"
    command -v wall >/dev/null 2>&1 && echo "ALERTA DE INTEGRIDADE: $text" | wall 2>/dev/null
}

# Cria uma representacao comparavel das regras que estao ativas no kernel.
# iptables-save pode incluir comentarios e contadores [pacotes:bytes]; ambos
# mudam sem que a politica tenha sido alterada, entao sao removidos antes do
# SHA-256. A saida da funcao e somente o digest hexadecimal.
live_hash() {
    iptables-save | sed -e '/^#/d' -e 's/\[[0-9]\+:[0-9]\+\]//g' | sha256sum | awk '{print $1}'
}

# --init define o estado atual como referencia. Os arquivos existentes sao
# calculados individualmente; caminhos ausentes sao avisados e ficam sem hash.
# O hash das regras carregadas e salvo em separado porque elas nao sao um arquivo.
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

# --check compara cada arquivo e o firewall ativo com a referencia. O status
# permanece diferente de zero se algo estiver ausente, sem referencia ou alterado.
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

    # Compara tambem as regras carregadas no kernel. Isso detecta uma alteracao
    # feita com iptables mesmo quando /etc/iptables/rules.v4 nao foi modificada.
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

# Acesso ao shadow, a rules.v4 e ao estado do firewall requer privilegio root.
[[ $EUID -eq 0 ]] || { echo "Execute como root: sudo $0"; exit 1; }
# Cria o arquivo de log caso seja a primeira execucao e restringe leitura a root
# e ao grupo do arquivo, evitando expor mensagens do verificador.
touch "$LOG_FILE" && chmod 640 "$LOG_FILE"

# Sem argumento, assume --check. Argumentos desconhecidos sao rejeitados para
# evitar que um erro de digitacao pareca uma inicializacao ou validacao bem-sucedida.
case "${1:---check}" in
    --init)  do_init ;;
    --check) do_check ;;
    *) echo "Uso: $0 [--init | --check]"; exit 1 ;;
esac
