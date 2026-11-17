#!/usr/bin/env bash
# Entrypoint do cliente e do atacante.
#  - GATEWAY    : se definido, vira a rota padrão (cliente usa o servidor como gateway)
#  - GERAR_CHAVE: se "1", cria o par de chaves SSH e publica a chave pública
set -u

printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

if [[ -n "${GATEWAY:-}" ]]; then
    ip route replace default via "$GATEWAY"
fi

if [[ "${GERAR_CHAVE:-0}" == "1" ]]; then
    mkdir -p /root/.ssh /chaves
    chmod 700 /root/.ssh
    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
        ssh-keygen -q -t ed25519 -N "" -C "admin_grid@grupo9" -f /root/.ssh/id_ed25519
        echo "[cliente] par de chaves SSH gerado"
    fi
    cp /root/.ssh/id_ed25519.pub /chaves/id_admin.pub   # só a PÚBLICA é compartilhada
fi

exec "$@"
