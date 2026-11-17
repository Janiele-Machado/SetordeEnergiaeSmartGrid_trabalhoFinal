#!/usr/bin/env bash
# =============================================================================
# servidor-entrypoint.sh - inicialização do servidor (substitui o "boot" da VM)
#   1) rota estática   2) DNS   3) chave SSH do admin   4) restaura firewall
#   5) serviços simulados   6) SSH   7) verificação periódica de integridade
# =============================================================================
set -u

LAN_IP="192.168.10.1"
SCADA_NET="10.20.0.0/24"       # rede de campo (subestações)
SCADA_GW="192.168.10.2"        # roteador interno que leva até a rede de campo
ADMIN_USER="admin_grid"
INTERVAL="${INTEGRITY_INTERVAL:-300}"

# --- 1. Roteamento estático ---------------------------------------------------
# (a rota padrão pela WAN e os IPs estáticos já vêm do docker-compose.yml)
LAN_IF="$(ip -o -4 addr show | awk -v ip="${LAN_IP}/" 'index($4, ip)==1 {print $2; exit}')"
echo "[servidor] interface LAN: ${LAN_IF}"
ip route replace "$SCADA_NET" via "$SCADA_GW" dev "$LAN_IF"

# --- 2. DNS direto (o DNS interno do Docker usa regras NAT que o firewall.sh limparia)
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

mkdir -p /run/sshd /etc/iptables /var/lib/integrity
ssh-keygen -A >/dev/null 2>&1

# --- 3. Instala a chave pública do admin (publicada pelo container "cliente") --
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

# --- 4. Restaura o firewall salvo (equivale ao iptables-persistent no boot) ---
if [[ -s /etc/iptables/rules.v4 ]]; then
    iptables-restore < /etc/iptables/rules.v4 && echo "[servidor] regras do iptables restauradas"
fi

# --- 5. Serviços simulados (para o Nmap ter o que encontrar) ------------------
python3 /usr/local/bin/servicos_simulados.py &

# --- 6. SSH (log em arquivo, pois não há syslog no container) -----------------
/usr/sbin/sshd -E /var/log/sshd.log
echo "[servidor] sshd iniciado"

# --- 7. Verificação periódica de integridade (só roda após --init) ------------
(
    while true; do
        sleep "$INTERVAL"
        if [[ -f /var/lib/integrity/baseline.sha256 ]]; then
            /opt/projeto/scripts/integrity_check.sh --check >> /var/log/integrity_auto.out 2>&1
        fi
    done
) &

exec sleep infinity
