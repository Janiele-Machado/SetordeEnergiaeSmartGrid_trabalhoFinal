#!/usr/bin/env bash
# =============================================================================
# verificar_modulos.sh - testa se o kernel do host oferece o que o firewall.sh usa.
# No Docker o kernel é o do HOST; alguns (ex.: Docker Desktop/WSL2) não trazem
# todos os módulos do netfilter. Rode isto ANTES do firewall.sh.
# Uso: docker compose exec servidor bash /opt/projeto/scripts/verificar_modulos.sh
# O script faz testes temporários: cria uma chain de teste, tenta anexar regras
# que representam os recursos usados pelo firewall e remove a chain ao terminar.
# Ele nao aplica a politica final nem deve substituir a execucao de firewall.sh.
# Codigo de saida 0 significa que todos os recursos testados foram aceitos;
# codigo diferente de zero indica que pelo menos um recurso falhou.
# =============================================================================
# -u avisa quando uma variavel nao definida e usada; nao encerra o script
# automaticamente, pois o resultado de cada teste precisa ser apresentado.
set -u
# Regras de iptables exigem privilegio administrativo, normalmente root dentro
# do container, alem da capacidade NET_ADMIN concedida pelo Compose.
[[ $EUID -eq 0 ]] || { echo "Execute como root."; exit 1; }

# Mostra a implementacao e versao de iptables selecionadas no ambiente. Isso
# ajuda a entender diferencas entre iptables-legacy, iptables-nft e o kernel.
iptables -V
# A chain TESTE_MOD isola as regras de verificacao das chains reais do sistema.
# Se nao for possivel cria-la, os testes nao podem prosseguir com seguranca.
iptables -N TESTE_MOD 2>/dev/null || { echo "[FALHA] não consegui criar chain (falta NET_ADMIN ou suporte a iptables no host)"; exit 1; }

# Acumula o resultado geral. Cada falha e reportada, mas os testes seguintes
# ainda executam para que o diagnostico mostre todos os recursos indisponiveis.
ok=1
# Acrescenta uma unica regra a chain de teste e converte o resultado do iptables
# numa mensagem legivel. A variavel global "ok" registra qualquer falha.
testar() {
    local desc="$1"; shift
    if iptables -A TESTE_MOD "$@" 2>/dev/null; then
        echo "[OK]    $desc"
    else
        echo "[FALHA] $desc"; ok=0
    fi
}

# Verifica os matches/alvos usados pelas regras de protecao do firewall:
# conntrack acompanha o estado das conexoes; recent guarda IPs recentes;
# hashlimit limita pacotes por origem; connlimit limita conexoes simultaneas;
# multiport testa varias portas numa regra; limit limita a taxa de eventos;
# tcp-flags identifica combinacoes de flags TCP usadas em scans.
testar "conntrack (estado das conexões)" -m conntrack --ctstate NEW -j ACCEPT
testar "recent (lista de IPs: port scan / SSH)" -m recent --name TESTE --set
testar "hashlimit (limite por IP)" -p tcp --syn -m hashlimit --hashlimit-name teste --hashlimit-mode srcip --hashlimit-above 10/second -j DROP
testar "connlimit (conexões por IP)" -p tcp -m connlimit --connlimit-above 5 -j DROP
testar "multiport" -p tcp -m multiport --dports 1,2 -j ACCEPT
testar "limit" -m limit --limit 1/second -j ACCEPT
testar "tcp-flags (Null/Xmas/FIN)" -p tcp --tcp-flags ALL NONE -j DROP
testar "alvo LOG" -j LOG --log-prefix "teste "

# MASQUERADE e um alvo da tabela NAT. Este teste e removido imediatamente para
# nao deixar uma regra de NAT temporaria ativa depois da verificacao.
if iptables -t nat -A POSTROUTING -o lo -j MASQUERADE 2>/dev/null; then
    echo "[OK]    NAT / MASQUERADE"; iptables -t nat -D POSTROUTING -o lo -j MASQUERADE
else
    echo "[FALHA] NAT / MASQUERADE"; ok=0
fi

# Limpa a chain temporaria e a propria chain. Assim, os testes comuns nao deixam
# regras persistentes no firewall do container.
iptables -F TESTE_MOD; iptables -X TESTE_MOD

# Resume o resultado. O script sugere alternativas de ambiente, mas nao troca
# o backend nem modifica o host automaticamente.
if [[ $ok -eq 1 ]]; then
    echo -e "\n\e[1;32mTudo certo: pode rodar o firewall.sh.\e[0m"
else
    echo -e "\n\e[1;31mFaltam módulos no kernel do host.\e[0m Tente:"
    echo "  - trocar o backend:  update-alternatives --set iptables /usr/sbin/iptables-legacy"
    echo "  - rodar o Docker em Linux nativo (ou numa VM Linux) em vez do Docker Desktop/WSL2"
    exit 1
fi
