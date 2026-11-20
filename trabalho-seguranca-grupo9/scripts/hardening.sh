#!/usr/bin/env bash
# =============================================================================
# hardening.sh - Hardening do Ubuntu (Sistema Operacional + SSH)
# Projeto : Trabalho Final de Segurança da Informação - Grupo 9
# Uso     : bash hardening.sh <usuario_admin>
# Funciona em container Docker (detecta /.dockerenv) e em VM/servidor real.
# ATENÇÃO : a chave pública SSH do <usuario_admin> precisa estar instalada
#           ANTES (o script aborta se não estiver, para não te trancar fora).
# O script altera pacotes, permissoes e configuracao do SSH. Leia as etapas e
# confirme a chave publica antes de executa-lo; a conta administradora passara
# a aceitar somente chave SSH e a usar a porta descrita em config/sshd_config.
# =============================================================================
# -e interrompe na primeira falha nao tratada; -u rejeita variaveis indefinidas;
# pipefail impede que uma falha no meio de um pipeline passe despercebida.
set -euo pipefail
# Evita perguntas interativas do apt durante atualizacao/instalacao de pacotes.
export DEBIAN_FRONTEND=noninteractive

# Usuario que podera administrar o servidor por SSH depois do hardening.
# ${1:-} evita erro de expansao quando o argumento nao foi informado.
ADMIN_USER="${1:-}"
# Localiza o template de SSH relativamente a este script; assim o caminho nao
# depende do diretorio atual de quem executou o comando.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSHD_TEMPLATE="${SCRIPT_DIR}/../config/sshd_config"

# O mesmo script atende VM e container. /.dockerenv e o indicador usado aqui
# para pular configuracoes que exigem systemd ou alteracao do kernel do host.
IN_CONTAINER=0
[[ -f /.dockerenv ]] && IN_CONTAINER=1

# Funcoes para padronizar as mensagens das etapas, informacoes e erros fatais.
# die encerra com status diferente de zero, fazendo o chamador detectar a falha.
step() { echo -e "\n\e[1;34m==> $*\e[0m"; }
info() { echo -e "\e[1;33m[info]\e[0m $*"; }
die()  { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]]      || die "Execute como root."
[[ -n "$ADMIN_USER" ]] || die "Informe o usuário admin. Ex.: bash $0 admin_grid"
id "$ADMIN_USER" &>/dev/null || die "Usuário '$ADMIN_USER' não existe."

# Trava de seguranca: o script vai desativar login SSH por senha. Antes disso,
# exige uma chave publica autorizada para o usuario, reduzindo o risco de perda
# de acesso remoto depois que o novo sshd_config for aplicado.
HOME_DIR="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
[[ -s "${HOME_DIR}/.ssh/authorized_keys" ]] || \
    die "Nenhuma chave pública em ${HOME_DIR}/.ssh/authorized_keys. Aguarde o container 'cliente' subir ou instale a chave (ssh-copy-id)."

# -----------------------------------------------------------------------------
step "1/7 Atualizações de segurança do sistema"
# -----------------------------------------------------------------------------
# Atualiza o indice de pacotes e instala atualizacoes disponiveis dentro desta
# imagem/VM. Em producao, planeje janela de manutencao e politica de atualizacao.
apt-get update -y
apt-get upgrade -y
if [[ $IN_CONTAINER -eq 0 ]]; then
    # Em uma VM, instala atualizacao automatica e auditoria do sistema.
    apt-get install -y unattended-upgrades gnupg auditd
    dpkg-reconfigure -f noninteractive unattended-upgrades   # updates automáticos
else
    # O container compartilha o kernel do host e nao usa systemd neste laboratorio.
    info "Container: atualizações automáticas (unattended-upgrades) não se aplicam;"
    info "em produção a imagem seria reconstruída periodicamente (docker compose build --pull)."
fi

# -----------------------------------------------------------------------------
step "2/7 Persistência das regras do firewall"
# -----------------------------------------------------------------------------
if [[ $IN_CONTAINER -eq 0 ]]; then
    # Em VM, instala suporte para salvar/carregar regras no boot, sem gravar
    # automaticamente as regras correntes durante a instalacao do pacote.
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
    apt-get install -y iptables iptables-persistent
else
    # No container, /etc/iptables e persistido pelo volume declarado no Compose.
    info "Container: regras ficam no volume /etc/iptables e são restauradas pelo entrypoint."
fi

# -----------------------------------------------------------------------------
step "3/7 Remoção de pacotes/serviços desnecessários (menor superfície de ataque)"
# -----------------------------------------------------------------------------
# Lista de ferramentas/servicos considerados desnecessarios neste laboratorio.
# Cada pacote e removido apenas se estiver instalado; autoremove limpa dependencias
# que deixaram de ser necessarias depois das remocoes.
UNNEEDED_PKGS=(telnet rsh-client rsh-server talk talkd nis xinetd tftp tftpd ftp \
               avahi-daemon cups cups-daemon rpcbind snmp)
for pkg in "${UNNEEDED_PKGS[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
        echo "Removendo: $pkg"
        apt-get purge -y "$pkg"
    fi
done
apt-get autoremove -y

# -----------------------------------------------------------------------------
step "4/7 Permissões em diretórios e arquivos críticos"
# -----------------------------------------------------------------------------
# Restringe alteracoes e leitura de arquivos importantes. /etc/passwd permanece
# legivel para ferramentas do sistema, mas so root pode escreve-lo; /etc/shadow
# fica acessivel apenas a root e ao grupo shadow.
chmod go-w /etc                               # ninguém além do root altera /etc
chmod 644 /etc/passwd /etc/group
chown root:shadow /etc/shadow /etc/gshadow
chmod 640 /etc/shadow /etc/gshadow            # hashes de senha: só root e grupo shadow
[[ -f /etc/sudoers ]] && chmod 440 /etc/sudoers
[[ -f /etc/crontab ]] && chmod 600 /etc/crontab
chmod 700 /root
chmod 755 /var/log
find /var/log -type f -exec chmod o-rwx {} \;  # logs não podem ser lidos por "outros"
sed -i 's/^UMASK.*/UMASK           027/' /etc/login.defs   # novos arquivos: sem acesso a "outros"

# -----------------------------------------------------------------------------
step "5/7 Parâmetros de kernel (sysctl)"
# -----------------------------------------------------------------------------
if [[ $IN_CONTAINER -eq 0 ]]; then
    # Em uma maquina real, grava configuracoes persistentes do kernel e aplica-as.
    cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# --- Roteamento (o servidor é gateway LAN <-> WAN) ---
net.ipv4.ip_forward = 1
# --- Proteção de rede ---
net.ipv4.tcp_syncookies = 1                    # mitiga SYN flood
net.ipv4.conf.all.rp_filter = 1                # anti-spoofing (reverse path filter)
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0         # ignora ICMP redirect
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0      # ignora source routing
net.ipv4.conf.all.log_martians = 1             # loga pacotes com origem impossível
net.ipv4.icmp_echo_ignore_broadcasts = 1       # evita ataque smurf
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
# --- Proteção do kernel ---
kernel.randomize_va_space = 2                  # ASLR completo
kernel.dmesg_restrict = 1                      # só root lê dmesg
kernel.kptr_restrict = 2                       # esconde endereços do kernel
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
    sysctl --system >/dev/null
else
    # Em container, o Compose ja define os parametros de rede namespaced.
    # Parametros kernel.* afetariam o host e, por isso, nao sao alterados aqui.
    info "Container: parâmetros net.* já aplicados pelo docker-compose.yml (bloco sysctls)."
    info "Parâmetros kernel.* pertencem ao host e não podem ser alterados de dentro do container."
fi

# -----------------------------------------------------------------------------
step "6/7 Auditoria contínua"
# -----------------------------------------------------------------------------
if [[ $IN_CONTAINER -eq 0 ]]; then
    # Regras do auditd registram alteracoes em contas, SSH e regras persistentes.
    cat > /etc/audit/rules.d/seg-grupo9.rules <<'EOF'
-w /etc/passwd -p wa -k identidade
-w /etc/shadow -p wa -k identidade
-w /etc/ssh/sshd_config -p wa -k config_ssh
-w /etc/iptables/ -p wa -k firewall
EOF
    augenrules --load >/dev/null 2>&1 || true
    systemctl enable --now auditd
else
    # Auditd depende do kernel/servicos do host. O projeto usa verificacao SHA-256
    # e log do sshd como alternativa dentro do container.
    info "Container: o auditd depende do kernel do host e não roda aqui."
    info "A auditoria é feita pelo integrity_check.sh (SHA-256) e pelo log do SSH (/var/log/sshd.log)."
fi

# -----------------------------------------------------------------------------
step "7/7 Hardening do SSH"
# -----------------------------------------------------------------------------
# O template contem a politica final de SSH; valida sua existencia antes de
# modificar qualquer configuracao.
[[ -f "$SSHD_TEMPLATE" ]] || die "Template não encontrado: $SSHD_TEMPLATE"
# Guarda a configuracao atual com timestamp para diagnostico ou restauracao
# manual. Uma nova execucao gera um novo backup, sem sobrescrever o anterior.
BACKUP="/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"
cp -a /etc/ssh/sshd_config "$BACKUP"
echo "Backup do sshd_config original em $BACKUP"

# Substitui o marcador do template pelo usuario informado e instala a politica
# resultante. O modo 600 restringe a leitura/escrita da configuracao ao root.
sed "s/__ADMIN_USER__/${ADMIN_USER}/g" "$SSHD_TEMPLATE" > /etc/ssh/sshd_config
chmod 600 /etc/ssh/sshd_config

cat > /etc/issue.net <<'EOF'
*******************************************************************
 SISTEMA RESTRITO - INFRAESTRUTURA CRÍTICA DE ENERGIA
 Acesso somente por pessoal autorizado. Toda atividade é
 monitorada e registrada. O uso indevido será punido conforme a PSI.
*******************************************************************
EOF

mkdir -p /run/sshd
# Valida a sintaxe ANTES de reiniciar; uma configuracao invalida e restaurada a
# partir do backup para evitar deixar o servico SSH sem configuracao utilizavel.
if ! sshd -t; then
    cp -a "$BACKUP" /etc/ssh/sshd_config
    die "sshd_config inválido. Configuração original restaurada."
fi

if [[ $IN_CONTAINER -eq 1 ]]; then
    # Sem systemd no container: encerra o processo sshd anterior quando o PID
    # existe e inicia o daemon com a configuracao nova e log em arquivo.
    if [[ -f /run/sshd.pid ]]; then
        kill "$(cat /run/sshd.pid)" 2>/dev/null || true
        sleep 1
    fi
    /usr/sbin/sshd -E /var/log/sshd.log
else
    # No Ubuntu 24.04, ssh.socket pode escutar por socket activation e ignorar a
    # porta configurada no sshd. Desativa o socket e reinicia o servico SSH.
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl enable ssh
    systemctl restart ssh
fi

PORT="$(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}')"
# Resume a porta efetiva e os sockets que estao ouvindo, facilitando o teste
# a partir da rede interna. A ultima listagem e apenas informativa.
echo -e "\n\e[1;32mHardening concluído!\e[0m"
echo "SSH agora escuta na porta ${PORT}. Teste a partir do cliente:"
echo "  ssh -p ${PORT} ${ADMIN_USER}@192.168.10.1"
ss -tlnp | grep sshd || true
