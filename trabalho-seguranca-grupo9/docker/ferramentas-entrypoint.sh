#!/usr/bin/env bash
# Entrypoint do cliente e do atacante.
#  - GATEWAY    : se definido, vira a rota padrão (cliente usa o servidor como gateway)
#  - GERAR_CHAVE: se "1", cria o par de chaves SSH e publica a chave pública
# O mesmo entrypoint e usado nos containers cliente e atacante. Variaveis nao
# definidas assumem comportamento neutro; somente o cliente configura gateway
# e gera chave quando essas variaveis sao passadas pelo Compose.
# A chave criada aqui e para SSH do laboratorio, distinta das chaves GPG usadas
# no teste de criptografia.
# =============================================================================
# -u denuncia configuracoes incompletas sem tratar uma variavel vazia como valor.
set -u

# Configura DNS direto para permitir resolucao mesmo quando o gateway do
# laboratorio nao esta encaminhando DNS do servico interno do Docker.
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

# Quando GATEWAY esta definido, substitui a rota padrao para fazer o servidor
# do laboratorio atuar como saida da rede LAN. Sem gateway, preserva a rota
# criada pelo Docker (por exemplo, no container atacante).
if [[ -n "${GATEWAY:-}" ]]; then
    ip route replace default via "$GATEWAY"
fi

if [[ "${GERAR_CHAVE:-0}" == "1" ]]; then
    # Garante que o diretorio privado e acessivel somente pelo root e cria o
    # diretorio compartilhado destinado exclusivamente a chave publica.
    mkdir -p /root/.ssh /chaves
    chmod 700 /root/.ssh
    # Nao sobrescreve uma chave existente, para que reiniciar o container nao
    # invalide authorized_keys previamente instalada no servidor.
    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
        # A chave privada e criada sem passphrase para uso automatizado no
        # laboratorio. Em ambiente real, proteja a chave e use agente/segredo.
        ssh-keygen -q -t ed25519 -N "" -C "admin_grid@grupo9" -f /root/.ssh/id_ed25519
        echo "[cliente] par de chaves SSH gerado"
    fi
    # Compartilha somente a chave publica, que autoriza a chave correspondente
    # no servidor; a chave privada permanece no volume /root/.ssh do cliente.
    cp /root/.ssh/id_ed25519.pub /chaves/id_admin.pub   # só a PÚBLICA é compartilhada
fi

# Substitui o entrypoint pelo comando principal do container. Isso mantem o
# processo no primeiro plano e permite que sinais de parada cheguem ao processo.
exec "$@"
