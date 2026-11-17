#!/usr/bin/env bash
# =============================================================================
# verificar_modulos.sh - testa se o kernel do host oferece o que o firewall.sh usa.
# No Docker o kernel é o do HOST; alguns (ex.: Docker Desktop/WSL2) não trazem
# todos os módulos do netfilter. Rode isto ANTES do firewall.sh.
# Uso: docker compose exec servidor bash /opt/projeto/scripts/verificar_modulos.sh
# =============================================================================
set -u
[[ $EUID -eq 0 ]] || { echo "Execute como root."; exit 1; }

iptables -V
iptables -N TESTE_MOD 2>/dev/null || { echo "[FALHA] não consegui criar chain (falta NET_ADMIN ou suporte a iptables no host)"; exit 1; }

ok=1
testar() {
    local desc="$1"; shift
    if iptables -A TESTE_MOD "$@" 2>/dev/null; then
        echo "[OK]    $desc"
    else
        echo "[FALHA] $desc"; ok=0
    fi
}

testar "conntrack (estado das conexões)" -m conntrack --ctstate NEW -j ACCEPT
testar "recent (lista de IPs: port scan / SSH)" -m recent --name TESTE --set
testar "hashlimit (limite por IP)" -p tcp --syn -m hashlimit --hashlimit-name teste --hashlimit-mode srcip --hashlimit-above 10/second -j DROP
testar "connlimit (conexões por IP)" -p tcp -m connlimit --connlimit-above 5 -j DROP
testar "multiport" -p tcp -m multiport --dports 1,2 -j ACCEPT
testar "limit" -m limit --limit 1/second -j ACCEPT
testar "tcp-flags (Null/Xmas/FIN)" -p tcp --tcp-flags ALL NONE -j DROP
testar "alvo LOG" -j LOG --log-prefix "teste "

if iptables -t nat -A POSTROUTING -o lo -j MASQUERADE 2>/dev/null; then
    echo "[OK]    NAT / MASQUERADE"; iptables -t nat -D POSTROUTING -o lo -j MASQUERADE
else
    echo "[FALHA] NAT / MASQUERADE"; ok=0
fi

iptables -F TESTE_MOD; iptables -X TESTE_MOD

if [[ $ok -eq 1 ]]; then
    echo -e "\n\e[1;32mTudo certo: pode rodar o firewall.sh.\e[0m"
else
    echo -e "\n\e[1;31mFaltam módulos no kernel do host.\e[0m Tente:"
    echo "  - trocar o backend:  update-alternatives --set iptables /usr/sbin/iptables-legacy"
    echo "  - rodar o Docker em Linux nativo (ou numa VM Linux) em vez do Docker Desktop/WSL2"
    exit 1
fi
