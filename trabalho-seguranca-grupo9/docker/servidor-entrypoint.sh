#!/usr/bin/env bash
# =============================================================================
# servidor-entrypoint.sh - inicialização do servidor (substitui o "boot" da VM)
#   1) rota estática   2) DNS   3) chave SSH do admin   4) reaplica firewall
#   5) serviços simulados   6) SSH   7) verificação periódica de integridade
# O entrypoint e executado como PID 1 quando o container inicia. Ele prepara
# rotas e diretorios, inicia processos auxiliares em background e por fim mantem
# o container vivo. Dados que precisam sobreviver a recriacoes devem estar em
# volumes do Compose, nao somente no sistema de arquivos do container.
# =============================================================================
# -u acusa o uso acidental de variaveis nao definidas sem encerrar todos os
# processos auxiliares por qualquer codigo de retorno nao-zero.
set -u

# Enderecos fixos descritos na topologia Compose e parametros ajustaveis por
# variavel de ambiente para o intervalo do verificador automatico.
LAN_IP="192.168.10.1"
SCADA_NET="10.20.0.0/24"       # rede de campo (subestações)
SCADA_GW="192.168.10.2"        # roteador interno que leva até a rede de campo
ADMIN_USER="admin_grid"
INTERVAL="${INTEGRITY_INTERVAL:-300}"

# --- 1. Roteamento estático ---------------------------------------------------
# Os enderecos estaticos ja sao atribuidos pelo Compose. Identifica a interface
# que possui o IP LAN para instalar a rota da rede SCADA pelo roteador interno.
LAN_IF="$(ip -o -4 addr show | awk -v ip="${LAN_IP}/" 'index($4, ip)==1 {print $2; exit}')"
echo "[servidor] interface LAN: ${LAN_IF}"
ip route replace "$SCADA_NET" via "$SCADA_GW" dev "$LAN_IF"

# Com duas interfaces, a rota padrao escolhida pelo Docker pode nao ser a WAN.
# Remove as rotas default existentes e instala explicitamente a rota WAN para
# que DNS/atualizacoes e trafego externo saiam pela interface correta.
WAN_IP="172.31.200.10"; WAN_GW="172.31.200.1"
WAN_IF="$(ip -o -4 addr show | awk -v ip="${WAN_IP}/" 'index($4, ip)==1 {print $2; exit}')"
while ip route del default 2>/dev/null; do :; done
ip route add default via "$WAN_GW" dev "$WAN_IF"
echo "[servidor] interface WAN: ${WAN_IF} (rota padrão via ${WAN_GW})"

# --- 2. DNS direto ------------------------------------------------------------
# O firewall recria as regras NAT, incluindo regras usadas pelo DNS embutido do
# Docker. Por isso grava servidores DNS externos diretamente no resolv.conf.
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

# Cria os pontos de runtime/estado necessarios. ssh-keygen -A gera chaves de host
# SSH apenas se estiverem ausentes; elas identificam o servidor aos clientes.
mkdir -p /run/sshd /etc/iptables /var/lib/integrity
ssh-keygen -A >/dev/null 2>&1

# --- 3. Instala a chave pública do admin (publicada pelo container "cliente") --
# O cliente publica a chave publica em /chaves. A espera ocorre em subshell de
# background para que a inicializacao do servidor nao fique bloqueada; ha ate
# 120 tentativas de 1 segundo. A chave privada nunca e lida pelo servidor.
(
    for _ in $(seq 1 120); do
        if [[ -s /chaves/id_admin.pub ]]; then
            install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
            install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /chaves/id_admin.pub \
                    "/home/${ADMIN_USER}/.ssh/authorized_keys"
            echo "[servidor] chave pública do ${ADMIN_USER} instalada"
            break
        fi
        sleep 1
    done
) &

# --- 4. Reaplica o firewall no boot (equivale ao iptables-persistent) --------
# Não basta restaurar o arquivo salvo: o Docker pode TROCAR a ordem de eth0/eth1
# entre reinícios, e as regras antigas ficariam com os nomes de interface errados.
# Rodar o firewall.sh de novo faz a detecção das interfaces pela rede (WAN/LAN).
# So reaplica se houver regras previamente salvas. O log separado facilita
# investigar falha sem interromper o restante da inicializacao do container.
if [[ -s /etc/iptables/rules.v4 ]]; then
    if bash /opt/projeto/scripts/firewall.sh > /var/log/firewall_boot.log 2>&1; then
        echo "[servidor] firewall reaplicado no boot"
    else
        echo "[servidor] ERRO ao reaplicar o firewall (veja /var/log/firewall_boot.log); restaurando arquivo salvo"
        iptables-restore < /etc/iptables/rules.v4 || true
    fi
fi

# --- 5. Serviços simulados (para o Nmap ter o que encontrar) ------------------
# O processo abre sockets TCP para demonstrar portas do cenario; os protocolos
# industriais sao somente banners simulados, nao implementacoes reais.
python3 /usr/local/bin/servicos_simulados.py &

# --- 6. SSH (log em arquivo, pois não há syslog no container) -----------------
# Inicia sshd em modo daemon, enviando os logs para arquivo porque o container
# nao executa um servico syslog convencional.
/usr/sbin/sshd -E /var/log/sshd.log
echo "[servidor] sshd iniciado"

# --- 7. Verificação periódica de integridade (só roda após --init) ------------
# Um processo em background espera INTERVAL segundos entre verificacoes. Antes
# da criacao da linha de base, nao ha estado confiavel para comparar e nada e
# executado. A saida automatica e anexada a um arquivo de log.
(
    while true; do
        sleep "$INTERVAL"
        if [[ -f /var/lib/integrity/baseline.sha256 ]]; then
            /opt/projeto/scripts/integrity_check.sh --check >> /var/log/integrity_auto.out 2>&1
        fi
    done
) &

# O entrypoint nao deve terminar depois de iniciar os servicos: sleep infinity
# mantem o container em execucao enquanto os processos auxiliares trabalham.
exec sleep infinity
