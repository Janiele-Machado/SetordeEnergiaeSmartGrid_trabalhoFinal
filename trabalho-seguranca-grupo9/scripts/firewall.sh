#!/usr/bin/env bash
# =============================================================================
# firewall.sh - Firewall perimetral com iptables
# Projeto : Trabalho Final de Segurança da Informação - Grupo 9
# Cenário : Setor de Energia e Smart Grid
# Uso     : sudo ./firewall.sh          (aplica e salva as regras)
#           sudo ./firewall.sh --safe   (aplica e, se você não confirmar em 30s,
#                                        volta automaticamente às regras antigas)
# O script substitui as regras IPv4 existentes nas tabelas filter, nat e mangle,
# define DROP como politica padrao de INPUT/FORWARD e salva a configuracao.
# Execute dentro do servidor correto: regras aplicadas no container nao sao as
# mesmas regras do host. Confira interfaces/redes antes da execucao.
# =============================================================================
# -e encerra em erros nao tratados; -u detecta variaveis ausentes; pipefail
# propaga falhas de comandos dentro de pipelines.
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. VARIÁVEIS DE CONFIGURAÇÃO (ajuste ao seu laboratório: use `ip -br a`)
# -----------------------------------------------------------------------------
# Redes usadas na topologia do Compose. As rotas para cada sub-rede permitem
# descobrir qual interface corresponde a WAN e qual corresponde a LAN.
WAN_NET="172.31.200.0/24"       # Rede externa (WAN) do laboratório Docker
LAN_NET="192.168.10.0/24"       # Rede interna (administração / operação)
# No Docker os nomes das interfaces (eth0/eth1) variam; detectar pela rota da
# sub-rede e mais confiavel que assumir um nome fixo.
# Em VM/servidor real, defina antes: WAN_IF=enp0s3 LAN_IF=enp0s8 ./firewall.sh
WAN_IF="${WAN_IF:-$(ip -o -4 route show exact "$WAN_NET" | awk '{print $3; exit}')}"
LAN_IF="${LAN_IF:-$(ip -o -4 route show exact "$LAN_NET" | awk '{print $3; exit}')}"
# A rota da rede SCADA e permitida apenas como destino interno; as portas de
# protocolos industriais nunca recebem permissao de entrada pela WAN.
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
# msg identifica mensagens do firewall; die encerra a aplicacao se faltar
# privilegio ou informacao de rede essencial.
msg() { echo -e "\e[1;34m[firewall]\e[0m $*"; }
die() { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Execute como root: sudo $0"
[[ -n "$WAN_IF" && -n "$LAN_IF" ]] || die "Não detectei as interfaces WAN/LAN (confira WAN_NET/LAN_NET com: ip route)"
msg "Interfaces detectadas -> WAN: $WAN_IF | LAN: $LAN_IF"

# --safe e opt-in. Sem esse argumento, o script aplica e salva as regras sem
# aguardar confirmacao; use o modo seguro se houver risco de perder acesso.
SAFE_MODE=0
[[ "${1:-}" == "--safe" ]] && SAFE_MODE=1

# Salva as regras atuais antes de limpar qualquer tabela. No modo --safe, esse
# arquivo temporario e a fonte de restauracao se a confirmacao nao chegar.
BACKUP_FILE="$(mktemp /tmp/iptables-backup.XXXXXX)"
iptables-save > "$BACKUP_FILE"
msg "Backup das regras atuais em $BACKUP_FILE"

# -----------------------------------------------------------------------------
# 3. LIMPEZA DAS REGRAS ANTIGAS
# -----------------------------------------------------------------------------
# Remove regras e chains personalizadas existentes para que esta execucao comece
# de um estado conhecido. Esta etapa e ampla: regras customizadas anteriores
# nessas tabelas serao substituidas pelas regras deste laboratorio.
msg "Limpando regras antigas..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -Z

# O servidor encaminha pacotes entre as redes. No container, o Compose ja define
# ip_forward; a tentativa abaixo complementa ambientes onde sysctl e permitido.
sysctl -qw net.ipv4.ip_forward=1 || true   # no Docker já vem do docker-compose.yml

# -----------------------------------------------------------------------------
# 4. CHAINS PERSONALIZADAS
# -----------------------------------------------------------------------------
# LOG_DROP e um destino comum para pacotes bloqueados: registra uma amostra com
# taxa limitada para reduzir volume de log e, depois, descarta o pacote.
iptables -N LOG_DROP
iptables -A LOG_DROP -m limit --limit 6/min --limit-burst 10 \
         -j LOG --log-prefix "[FW-DROP] " --log-level 4
iptables -A LOG_DROP -j DROP

# SCAN_BLOCK guarda o IP de origem no modulo recent, registra de forma limitada
# e descarta. Outra regra INPUT consulta essa lista para manter o bloqueio por
# SCAN_BAN_SECONDS.
iptables -N SCAN_BLOCK
iptables -A SCAN_BLOCK -m recent --name PORTSCAN --set
iptables -A SCAN_BLOCK -m limit --limit 6/min --limit-burst 10 \
         -j LOG --log-prefix "[FW-PORTSCAN] " --log-level 4
iptables -A SCAN_BLOCK -j DROP

# -----------------------------------------------------------------------------
# 5. CHAIN INPUT (tráfego destinado ao próprio servidor)
# -----------------------------------------------------------------------------
# INPUT controla conexoes cujo destino e o proprio servidor (por exemplo SSH
# ou os servicos simulados). As regras sao avaliadas em ordem: a primeira regra
# que aceita/descarta o pacote encerra a avaliacao daquele pacote.
msg "Aplicando regras de INPUT..."

# 5.1 Loopback: libera comunicacao local dentro do container (127.0.0.1).
iptables -A INPUT -i lo -j ACCEPT

# 5.2 INVALID: descarta pacotes que o conntrack nao consegue associar a uma
# conexao valida. Isso reduz trafego malformado antes das regras de servico.
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 5.3 TCP flags: bloqueia combinacoes incomuns de flags, frequentemente usadas
# por varreduras de portas. O nome Null/Xmas/FIN descreve o tipo de probe; nao
# significa que todo pacote com essas flags seja, por si so, um ataque.
iptables -A INPUT -p tcp --tcp-flags ALL NONE            -j SCAN_BLOCK  # Null scan (-sN)
iptables -A INPUT -p tcp --tcp-flags ALL ALL             -j SCAN_BLOCK  # Xmas full
iptables -A INPUT -p tcp --tcp-flags ALL FIN,PSH,URG     -j SCAN_BLOCK  # Xmas scan (-sX)
iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN     -j SCAN_BLOCK  # SYN+FIN
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST     -j SCAN_BLOCK  # SYN+RST
iptables -A INPUT -p tcp --tcp-flags FIN,RST FIN,RST     -j SCAN_BLOCK  # FIN+RST
iptables -A INPUT -p tcp --tcp-flags ACK,FIN FIN         -j SCAN_BLOCK  # FIN sem ACK (-sF)
iptables -A INPUT -p tcp --tcp-flags ACK,PSH PSH         -j SCAN_BLOCK  # PSH sem ACK
iptables -A INPUT -p tcp --tcp-flags ACK,URG URG         -j SCAN_BLOCK  # URG sem ACK

# 5.4 Fragmentos IPv4: encaminha fragmentos para LOG_DROP, pois regras de porta
# nao conseguem inspecionar cada fragmento de forma equivalente.
iptables -A INPUT -f -j LOG_DROP

# 5.5 ESTABLISHED/RELATED: permite respostas de conexoes autorizadas e trafego
# relacionado a elas; nao abre uma nova conexao de entrada por si so.
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 5.6 Anti-spoofing: um pacote recebido na WAN com origem declarada como LAN ou
# SCADA e inconsistente com a topologia, entao e descartado. Tambem rejeita
# enderecos loopback recebidos em qualquer interface diferente de lo.
iptables -A INPUT -i "$WAN_IF" -s "$LAN_NET"   -j LOG_DROP
iptables -A INPUT -i "$WAN_IF" -s "$SCADA_NET" -j LOG_DROP
iptables -A INPUT ! -i lo -s 127.0.0.0/8       -j DROP

# 5.7 recent: se o IP estiver na lista PORTSCAN dentro da janela de banimento,
# descarta o pacote antes de avaliar permissoes de servicos.
iptables -A INPUT -m recent --name PORTSCAN --rcheck --seconds "$SCAN_BAN_SECONDS" -j DROP

# 5.8 SYN rate-limit: hashlimit contabiliza novas tentativas SYN por IP. Acima
# da taxa e burst configurados, LOG_DROP registra limitadamente e descarta.
iptables -A INPUT -p tcp --syn -m hashlimit --hashlimit-name syn_flood \
         --hashlimit-mode srcip --hashlimit-above 25/second --hashlimit-burst 50 \
         -j LOG_DROP

# 5.9 ICMP: permite echo-request com limite para diagnostico de conectividade;
# outros tipos de ICMP sao descartados por esta politica do laboratorio.
iptables -A INPUT -p icmp --icmp-type echo-request \
         -m limit --limit 1/second --limit-burst 5 -j ACCEPT
iptables -A INPUT -p icmp -j DROP

# 5.10 SSH: permite novas conexoes somente pela interface LAN e de origem
# interna. recent conta tentativas por IP; ao atingir o limite, bloqueia/loga.
# Conexoes ja estabelecidas sao tratadas anteriormente pela regra conntrack.
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
# Nunca abre SSH na WAN por padrao; a variavel so permite isso se alterada
# explicitamente para "yes".
allow_ssh "$LAN_IF" "$INTERNAL_SRC"
[[ "$ALLOW_SSH_WAN" == "yes" ]] && allow_ssh "$WAN_IF" "0.0.0.0/0"

# 5.11 DNS: aceita consultas originadas na LAN, limitando DNS/UDP por IP.
# DNS/TCP e permitido para consultas/respostas que precisem de TCP.
iptables -A INPUT -i "$LAN_IF" -s "$INTERNAL_SRC" -p udp --dport 53 \
         -m hashlimit --hashlimit-name dns_udp --hashlimit-mode srcip \
         --hashlimit-upto 50/second --hashlimit-burst 100 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -s "$INTERNAL_SRC" -p tcp --dport 53 \
         -m conntrack --ctstate NEW -j ACCEPT

# 5.12 HTTPS: porta publicada para novas conexoes nas interfaces, com limite
# maximo de conexoes simultaneas por endereco IPv4 de origem.
iptables -A INPUT -p tcp --dport "$HTTPS_PORT" --syn \
         -m connlimit --connlimit-above 30 --connlimit-mask 32 -j LOG_DROP
iptables -A INPUT -p tcp --dport "$HTTPS_PORT" -m conntrack --ctstate NEW -j ACCEPT

# 5.13 MQTT/TLS: mesma logica de HTTPS, usando limite proprio para cada IP.
iptables -A INPUT -p tcp --dport "$MQTT_TLS_PORT" --syn \
         -m connlimit --connlimit-above 20 --connlimit-mask 32 -j LOG_DROP
iptables -A INPUT -p tcp --dport "$MQTT_TLS_PORT" -m conntrack --ctstate NEW -j ACCEPT

# 5.14 Protocolos industriais (Modbus, DNP3, IEC-104, OPC UA): SÓ rede interna.
#      Nunca devem ser expostos à WAN (não possuem autenticação/criptografia nativas).
# A interface e a origem precisam pertencer a rede interna; as portas sao
# selecionadas com multiport para manter a regra concisa.
iptables -A INPUT -i "$LAN_IF" -s "$INTERNAL_SRC" -p tcp \
         -m multiport --dports "$OT_TCP_PORTS" -m conntrack --ctstate NEW -j ACCEPT

# 5.15 Politica residual: SYN para porta nao liberada entra na lista de scan;
# qualquer outro trafego que nao tenha casado com regra autorizadora e descartado.
iptables -A INPUT -p tcp --syn -j SCAN_BLOCK
iptables -A INPUT -j LOG_DROP

# -----------------------------------------------------------------------------
# 6. CHAIN FORWARD (tráfego que atravessa o servidor entre LAN e WAN)
# -----------------------------------------------------------------------------
# FORWARD filtra pacotes que atravessam o gateway. Primeiro preserva respostas
# de conexoes existentes; depois limita o que a rede interna pode iniciar.
msg "Aplicando regras de FORWARD..."
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# LAN/SCADA -> WAN: permite web (HTTP/HTTPS), DNS, NTP e ping de saida. Isso nao
# publica esses servicos para conexoes iniciadas da WAN para dentro.
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p tcp \
         -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p udp \
         -m multiport --dports 53,123 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p tcp \
         --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s "$INTERNAL_SRC" -p icmp \
         --icmp-type echo-request -j ACCEPT

# Todo o restante, incluindo conexoes novas WAN -> LAN, e bloqueado.
iptables -A FORWARD -j LOG_DROP

# -----------------------------------------------------------------------------
# 7. NAT: a LAN sai para a internet com o IP da WAN
# -----------------------------------------------------------------------------
# MASQUERADE traduz o endereco de origem dos pacotes que saem pela WAN para o
# endereco WAN atual do servidor; isso permite retorno de trafego da internet.
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$LAN_NET"   -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$SCADA_NET" -j MASQUERADE

# -----------------------------------------------------------------------------
# 8. POLÍTICA PADRÃO: DROP em INPUT e FORWARD
#    (definida por último para não derrubar sua sessão SSH durante a montagem)
# -----------------------------------------------------------------------------
# As permissoes especificas ja foram adicionadas. Definir DROP somente agora
# reduz o risco de interromper a montagem no meio; OUTPUT continua liberado para
# atualizacoes, DNS e conexoes iniciadas pelo proprio servidor.
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT      # o servidor pode iniciar conexões (updates, DNS)

# Como a topologia deste laboratorio usa IPv4, a configuracao IPv6 e limpa e as
# politicas de entrada/encaminhamento sao bloqueadas para evitar uma rota paralela.
ip6tables -F || true
ip6tables -A INPUT -i lo -j ACCEPT || true
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
ip6tables -P INPUT   DROP || true
ip6tables -P FORWARD DROP || true
ip6tables -P OUTPUT  ACCEPT || true

# -----------------------------------------------------------------------------
# 9. PERSISTÊNCIA (carregadas no boot pelo pacote iptables-persistent)
# -----------------------------------------------------------------------------
# Persiste as regras IPv4/IPv6 em /etc/iptables. Comentarios dinamicos sao
# removidos para produzir um arquivo estavel para verificacao de integridade.
save_rules() {
    mkdir -p /etc/iptables
    iptables-save  | sed '/^#/d' > /etc/iptables/rules.v4   # sem comentários com data: hash estável
    ip6tables-save | sed '/^#/d' > /etc/iptables/rules.v6 || true
    chmod 600 /etc/iptables/rules.v4 /etc/iptables/rules.v6
    msg "Regras salvas em /etc/iptables/rules.v4"
}

# No modo --safe, so grava as novas regras se o operador confirmar em 30 segundos.
# Caso contrario, restaura o backup feito antes da limpeza e encerra com erro.
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
