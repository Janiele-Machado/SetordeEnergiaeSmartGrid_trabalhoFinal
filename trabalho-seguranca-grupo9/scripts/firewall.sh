#!/usr/bin/env bash
# =============================================================================
# firewall.sh - Firewall perimetral com iptables
# Projeto : Trabalho Final de Segurança da Informação - Grupo 9
# Cenário : Setor de Energia e Smart Grid
# Uso     : sudo ./firewall.sh          (aplica e salva as regras)
#           sudo ./firewall.sh --safe   (aplica e, se você não confirmar em 30s,
#                                        volta automaticamente às regras antigas)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. VARIÁVEIS DE CONFIGURAÇÃO (ajuste ao seu laboratório: use `ip -br a`)
# -----------------------------------------------------------------------------
WAN_NET="172.31.200.0/24"       # Rede externa (WAN) do laboratório Docker
LAN_NET="192.168.10.0/24"       # Rede interna (administração / operação)
# No Docker os nomes das interfaces (eth0/eth1) variam: detectamos pela rede de cada uma.
# Em VM/servidor real, defina antes: WAN_IF=enp0s3 LAN_IF=enp0s8 ./firewall.sh
WAN_IF="${WAN_IF:-$(ip -o -4 route show exact "$WAN_NET" | awk '{print $3; exit}')}"
LAN_IF="${LAN_IF:-$(ip -o -4 route show exact "$LAN_NET" | awk '{print $3; exit}')}"
SCADA_NET="10.20.0.0/24"        # Rede de campo (subestações) roteada via LAN
SSH_PORT="2222"                 # Mesma porta definida no sshd_config
ALLOW_SSH_WAN="no"              # "yes" libera SSH também pela WAN (não recomendado)
SCAN_BAN_SECONDS=300            # Tempo de bloqueio de quem fizer port scan

# Protocolos de telemetria/automação (OT) - SOMENTE rede interna:
#   502 = Modbus/TCP | 20000 = DNP3 | 2404 = IEC 60870-5-104 | 4840 = OPC UA
OT_TCP_PORTS="502,20000,2404,4840"
# Serviços de aplicação:
HTTPS_PORT="443"                # Painel web de monitoramento (TLS)
MQTT_TLS_PORT="8883"            # Telemetria de medidores inteligentes (MQTT sobre TLS)

INTERNAL_SRC="${LAN_NET},${SCADA_NET}"   # "Quem é interno"

# -----------------------------------------------------------------------------
# 2. FUNÇÕES AUXILIARES
# -----------------------------------------------------------------------------
msg() { echo -e "\e[1;34m[firewall]\e[0m $*"; }
die() { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Execute como root: sudo $0"
[[ -n "$WAN_IF" && -n "$LAN_IF" ]] || die "Não detectei as interfaces WAN/LAN (confira WAN_NET/LAN_NET com: ip route)"
msg "Interfaces detectadas -> WAN: $WAN_IF | LAN: $LAN_IF"

SAFE_MODE=0
[[ "${1:-}" == "--safe" ]] && SAFE_MODE=1

# Backup das regras atuais (usado pelo modo --safe)
BACKUP_FILE="$(mktemp /tmp/iptables-backup.XXXXXX)"
iptables-save > "$BACKUP_FILE"
msg "Backup das regras atuais em $BACKUP_FILE"

# -----------------------------------------------------------------------------
# 3. LIMPEZA DAS REGRAS ANTIGAS
# -----------------------------------------------------------------------------
msg "Limpando regras antigas..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -Z

# O servidor atua como roteador/gateway entre LAN e WAN
sysctl -qw net.ipv4.ip_forward=1 || true   # no Docker já vem do docker-compose.yml

# -----------------------------------------------------------------------------
# 4. CHAINS PERSONALIZADAS
# -----------------------------------------------------------------------------
# LOG_DROP: registra (com limite, para não encher o disco) e descarta
iptables -N LOG_DROP
iptables -A LOG_DROP -m limit --limit 6/min --limit-burst 10 \
         -j LOG --log-prefix "[FW-DROP] " --log-level 4
iptables -A LOG_DROP -j DROP

# SCAN_BLOCK: marca o IP de origem na lista "PORTSCAN", registra e descarta
iptables -N SCAN_BLOCK
iptables -A SCAN_BLOCK -m recent --name PORTSCAN --set
iptables -A SCAN_BLOCK -m limit --limit 6/min --limit-burst 10 \
         -j LOG --log-prefix "[FW-PORTSCAN] " --log-level 4
iptables -A SCAN_BLOCK -j DROP

# -----------------------------------------------------------------------------
# 5. CHAIN INPUT (tráfego destinado ao próprio servidor)
# -----------------------------------------------------------------------------
msg "Aplicando regras de INPUT..."

# 5.1 Loopback sempre liberado (serviços locais conversam entre si)
iptables -A INPUT -i lo -j ACCEPT

# 5.2 Descarta pacotes com estado INVALID (fora de qualquer conexão válida)
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 5.3 Proteção contra pacotes TCP malformados (assinaturas de scanners do Nmap)
iptables -A INPUT -p tcp --tcp-flags ALL NONE            -j SCAN_BLOCK  # Null scan (-sN)
iptables -A INPUT -p tcp --tcp-flags ALL ALL             -j SCAN_BLOCK  # Xmas full
iptables -A INPUT -p tcp --tcp-flags ALL FIN,PSH,URG     -j SCAN_BLOCK  # Xmas scan (-sX)
iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN     -j SCAN_BLOCK  # SYN+FIN
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST     -j SCAN_BLOCK  # SYN+RST
iptables -A INPUT -p tcp --tcp-flags FIN,RST FIN,RST     -j SCAN_BLOCK  # FIN+RST
iptables -A INPUT -p tcp --tcp-flags ACK,FIN FIN         -j SCAN_BLOCK  # FIN sem ACK (-sF)
iptables -A INPUT -p tcp --tcp-flags ACK,PSH PSH         -j SCAN_BLOCK  # PSH sem ACK
iptables -A INPUT -p tcp --tcp-flags ACK,URG URG         -j SCAN_BLOCK  # URG sem ACK

# 5.4 Fragmentos de pacote (usados para evasão de firewall)
iptables -A INPUT -f -j LOG_DROP

# 5.5 Conexões já estabelecidas ou relacionadas (respostas) são aceitas
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 5.6 Anti-spoofing: pela WAN não pode chegar IP que pertence à rede interna
iptables -A INPUT -i "$WAN_IF" -s "$LAN_NET"   -j LOG_DROP
iptables -A INPUT -i "$WAN_IF" -s "$SCADA_NET" -j LOG_DROP
iptables -A INPUT ! -i lo -s 127.0.0.0/8       -j DROP

# 5.7 Quem já foi pego fazendo port scan fica bloqueado por SCAN_BAN_SECONDS
iptables -A INPUT -m recent --name PORTSCAN --rcheck --seconds "$SCAN_BAN_SECONDS" -j DROP

# 5.8 Proteção contra SYN flood (DoS): limite de SYNs por IP de origem
iptables -A INPUT -p tcp --syn -m hashlimit --hashlimit-name syn_flood \
         --hashlimit-mode srcip --hashlimit-above 25/second --hashlimit-burst 50 \
         -j LOG_DROP

# 5.9 ICMP (ping): permitido com limite de taxa; o resto de ICMP é descartado
iptables -A INPUT -p icmp --icmp-type echo-request \
         -m limit --limit 1/second --limit-burst 5 -j ACCEPT
iptables -A INPUT -p icmp -j DROP

# 5.10 SSH com limite contra força bruta: máx. 3 novas conexões por minuto por IP
allow_ssh() {
    local iface="$1" src="$2"
    iptables -A INPUT -i "$iface" -s "$src" -p tcp --dport "$SSH_PORT" \
             -m conntrack --ctstate NEW -m recent --name SSH_BRUTE --set
    iptables -A INPUT -i "$iface" -s "$src" -p tcp --dport "$SSH_PORT" \
             -m conntrack --ctstate NEW \
             -m recent --name SSH_BRUTE --update --seconds 60 --hitcount 4 -j LOG_DROP
    iptables -A INPUT -i "$iface" -s "$src" -p tcp --dport "$SSH_PORT" \
             -m conntrack --ctstate NEW -j ACCEPT
}
allow_ssh "$LAN_IF" "$INTERNAL_SRC"
[[ "$ALLOW_SSH_WAN" == "yes" ]] && allow_ssh "$WAN_IF" "0.0.0.0/0"

# 5.11 DNS: somente para a rede interna (UDP com limite por IP, e TCP)
iptables -A INPUT -i "$LAN_IF" -s "$INTERNAL_SRC" -p udp --dport 53 \
         -m hashlimit --hashlimit-name dns_udp --hashlimit-mode srcip \
         --hashlimit-upto 50/second --hashlimit-burst 100 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -s "$INTERNAL_SRC" -p tcp --dport 53 \
         -m conntrack --ctstate NEW -j ACCEPT

# 5.12 HTTPS (painel de monitoramento): aberto, com máx. 30 conexões simultâneas por IP
iptables -A INPUT -p tcp --dport "$HTTPS_PORT" --syn \
         -m connlimit --connlimit-above 30 --connlimit-mask 32 -j LOG_DROP
iptables -A INPUT -p tcp --dport "$HTTPS_PORT" -m conntrack --ctstate NEW -j ACCEPT

# 5.13 MQTT sobre TLS (medidores inteligentes): aberto, máx. 20 conexões por IP
iptables -A INPUT -p tcp --dport "$MQTT_TLS_PORT" --syn \
         -m connlimit --connlimit-above 20 --connlimit-mask 32 -j LOG_DROP
iptables -A INPUT -p tcp --dport "$MQTT_TLS_PORT" -m conntrack --ctstate NEW -j ACCEPT

# 5.14 Protocolos industriais (Modbus, DNP3, IEC-104, OPC UA): SÓ rede interna.
#      Nunca devem ser expostos à WAN (não possuem autenticação/criptografia nativas).
iptables -A INPUT -i "$LAN_IF" -s "$INTERNAL_SRC" -p tcp \
         -m multiport --dports "$OT_TCP_PORTS" -m conntrack --ctstate NEW -j ACCEPT

# 5.15 Tudo que sobrou: SYN para porta não liberada = tentativa de varredura.
iptables -A INPUT -p tcp --syn -j SCAN_BLOCK
iptables -A INPUT -j LOG_DROP

# -----------------------------------------------------------------------------
# 6. CHAIN FORWARD (tráfego que atravessa o servidor entre LAN e WAN)
# -----------------------------------------------------------------------------
msg "Aplicando regras de FORWARD..."
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Rede interna -> internet: apenas o essencial (web, DNS, NTP e ping)
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p tcp \
         -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p udp \
         -m multiport --dports 53,123 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p tcp \
         --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p icmp \
         --icmp-type echo-request -j ACCEPT

# WAN -> LAN nunca é iniciado de fora (só respostas, pela regra ESTABLISHED)
iptables -A FORWARD -j LOG_DROP

# -----------------------------------------------------------------------------
# 7. NAT: a LAN sai para a internet com o IP da WAN
# -----------------------------------------------------------------------------
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$LAN_NET"   -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$SCADA_NET" -j MASQUERADE

# -----------------------------------------------------------------------------
# 8. POLÍTICA PADRÃO: DROP em INPUT e FORWARD
#    (definida por último para não derrubar sua sessão SSH durante a montagem)
# -----------------------------------------------------------------------------
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT      # o servidor pode iniciar conexões (updates, DNS)

# IPv6 não é usado neste cenário: bloqueia entrada/encaminhamento por completo
ip6tables -F || true
ip6tables -A INPUT -i lo -j ACCEPT || true
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
ip6tables -P INPUT   DROP || true
ip6tables -P FORWARD DROP || true
ip6tables -P OUTPUT  ACCEPT || true

# -----------------------------------------------------------------------------
# 9. PERSISTÊNCIA (carregadas no boot pelo pacote iptables-persistent)
# -----------------------------------------------------------------------------
save_rules() {
    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6 || true
    chmod 600 /etc/iptables/rules.v4 /etc/iptables/rules.v6
    msg "Regras salvas em /etc/iptables/rules.v4"
}

if [[ $SAFE_MODE -eq 1 ]]; then
    echo -e "\e[1;33mModo seguro:\e[0m se sua sessão SSH continua funcionando, digite 'sim' em 30s."
    if read -r -t 30 -p "Manter as regras? (sim/nao): " resp && [[ "$resp" == "sim" ]]; then
        save_rules
    else
        iptables-restore < "$BACKUP_FILE"
        die "Sem confirmação: regras anteriores RESTAURADAS."
    fi
else
    save_rules
fi

msg "Firewall aplicado com sucesso. Resumo:"
iptables -L INPUT -n --line-numbers | head -n 40 || true
