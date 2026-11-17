# Trabalho Final – Segurança da Informação | Grupo 9 (versão Docker)

**Cenário:** Setor de Energia e Smart Grid
**Plataforma:** containers Ubuntu 24.04 orquestrados com Docker Compose

Infraestrutura de uma distribuidora de energia com firewall perimetral (iptables), hardening do SO e do SSH, criptografia assimétrica (GPG) e verificação contínua de integridade (SHA-256).

> **Importante:** o enunciado fala em "Ubuntu Server". Em Docker o sistema é o Ubuntu 24.04 (userland), mas o **kernel é o do seu computador**. Confirme com o professor se Docker é aceito. A seção 7 lista as diferenças em relação a uma VM, para usar no relatório.

---

## 1. Requisitos

- Docker + Docker Compose v2 (`docker compose version`)
- **Linux nativo é o ideal.** No Windows/macOS (Docker Desktop) o firewall pode não funcionar se o kernel não tiver todos os módulos do netfilter. Por isso existe o teste da Etapa 2.
- No Windows: faça o `git clone` com `git config core.autocrlf false` (o repositório já traz um `.gitattributes` que força fim de linha LF nos `.sh`).

## 2. Estrutura

```
trabalho-seguranca-grupo9/
├── docker-compose.yml         <- topologia do laboratório (redes, IPs, volumes)
├── docker/                    <- imagens e inicialização dos containers
│   ├── Dockerfile.servidor
│   ├── Dockerfile.ferramentas <- usada por cliente e atacante
│   ├── servidor-entrypoint.sh <- rota estática, SSH, restaura firewall...
│   ├── ferramentas-entrypoint.sh
│   └── servicos_simulados.py  <- portas 443, 8883, 502, 20000, 2404, 4840
├── scripts/
│   ├── verificar_modulos.sh   <- testa o kernel do host
│   ├── hardening.sh           <- SO + SSH
│   ├── firewall.sh            <- regras iptables
│   └── integrity_check.sh     <- hashes SHA-256
├── config/
│   ├── sshd_config            <- SSH endurecido (template)
│   └── referencia-vm/01-netcfg.yaml  <- netplan (só se usar VM)
├── gpg/                       <- chaves públicas exportadas
├── evidencias/                <- prints e saídas de comandos
└── docs/                      <- diagramas e relatório (depois)
```

## 3. Topologia

```
 [atacante]                 [servidor]                    [cliente]
 172.31.200.60 --(wan)-- 172.31.200.10 | 192.168.10.1 --(lan)-- 192.168.10.10
                          gateway + firewall            administrador
                                 |
                      rota estática 10.20.0.0/24 via 192.168.10.2
                      (rede de campo / subestações)
```

| Container | Papel | Rede / IP |
|-----------|-------|-----------|
| `servidor` | Ubuntu: gateway, firewall, SSH, serviços simulados | wan `172.31.200.10` e lan `192.168.10.1` |
| `cliente` | Administrador (SSH, GPG) | lan `192.168.10.10` |
| `atacante` | Nmap e hping3 | wan `172.31.200.60` |

A rede `lan` é `internal: true`: o atacante **não** a alcança, e o cliente só sai para a internet passando pelo servidor (NAT).

Usuários de laboratório: `admin_grid` (senha `admin123`) e `root` (senha `root123`), fracos de propósito para mostrar o "antes" do hardening.

---

## 4. Passo a passo

Todos os comandos são rodados **na pasta do projeto**, no seu computador.

### Etapa 1 – Subir o laboratório
```bash
docker compose up -d --build
docker compose ps
```
Deve listar `servidor`, `cliente` e `atacante` como `running`.
Se der conflito de rede, mude `172.31.200.0/24` no `docker-compose.yml`, e no `firewall.sh` (variável `WAN_NET`).

Abra um terminal por container (use quando precisar):
```bash
docker compose exec servidor bash
docker compose exec cliente bash
docker compose exec atacante bash
```

### Etapa 2 – Testar se o kernel suporta o firewall
```bash
docker compose exec servidor bash /opt/projeto/scripts/verificar_modulos.sh
```
Tudo `[OK]` = pode seguir. Se aparecer `[FALHA]`, veja a seção 6 (problemas comuns).

### Etapa 3 – IP estático e roteamento (Módulo 2)
```bash
docker compose exec servidor ip -br a        # IPs estáticos das duas interfaces
docker compose exec servidor ip route        # rota padrão (WAN) + rota estática 10.20.0.0/24
docker compose exec cliente ip route         # default via 192.168.10.1 (o servidor)
docker compose exec cliente ping -c 2 192.168.10.1
docker compose exec cliente ping -c 2 8.8.8.8   # sai pela internet passando pelo servidor (NAT)
```
**Tire prints.** Para salvar em arquivo: `docker compose exec -T servidor ip route > evidencias/rotas.txt`

### Etapa 4 – Estado inicial vulnerável (o "antes")
No `cliente`:
```bash
ssh root@192.168.10.1            # senha: root123 -> ENTRA (vulnerável!)
exit
```
Isso prova por que o hardening é necessário.

### Etapa 5 – Hardening do SO e do SSH
```bash
docker compose exec servidor bash /opt/projeto/scripts/hardening.sh admin_grid
```
O script só prossegue se a chave pública do admin estiver instalada (o container `cliente` a gera e publica sozinho ao subir).

Teste no `cliente` (a porta mudou e só entra com chave, sem senha):
```bash
ssh -p 2222 admin_grid@192.168.10.1      # responda "yes" na 1ª vez; entra SEM pedir senha
```

### Etapa 6 – Nmap ANTES do firewall (evidência)
No `atacante`:
```bash
nmap -sS -sV -p- -T4 172.31.200.10 -oN /evidencias/nmap_antes.txt
```
Deve listar abertas: 2222 (SSH), 443, 8883, 502, 20000, 2404, 4840. **Tire print.**

### Etapa 7 – Aplicar o firewall
```bash
docker compose exec servidor bash /opt/projeto/scripts/firewall.sh
```
> Em Docker você nunca fica trancado fora: o `docker exec` não passa pela rede. O modo `--safe` só protegeria uma sessão SSH aberta.

Conferir (**prints**):
```bash
docker compose exec servidor iptables -L -n -v --line-numbers
docker compose exec servidor iptables -t nat -L -n -v
```

### Etapa 8 – Nmap DEPOIS do firewall (evidência)
No `atacante`:
```bash
# 1) Portas liberadas na WAN: 443 e 8883 devem aparecer ABERTAS
nmap -sS -p 443,8883 172.31.200.10

# 2) Varredura completa: tudo "filtered" (o IP é banido ao tocar numa porta fechada)
nmap -sS -sV -p- -T4 172.31.200.10 -oN /evidencias/nmap_depois.txt

# 3) Scans furtivos (Null, FIN, Xmas) também são bloqueados
nmap -sN -sF -sX -p 1-1000 172.31.200.10
```
Prova do bloqueio no `servidor`:
```bash
docker compose exec servidor iptables -L SCAN_BLOCK -n -v     # contadores de pacotes descartados
docker compose exec servidor iptables -L LOG_DROP -n -v
docker compose exec servidor cat /proc/net/xt_recent/PORTSCAN # IPs banidos (172.31.200.60)
```
Para liberar o atacante e repetir os testes:
```bash
docker compose exec servidor sh -c 'echo / > /proc/net/xt_recent/PORTSCAN'
```
> **Logs do kernel:** por padrão o alvo `LOG` não escreve nada dentro de containers. Em **Linux nativo** ative no host `sudo sysctl -w net.netfilter.nf_log_all_netns=1` e veja com `sudo dmesg | grep -E "FW-DROP|FW-PORTSCAN"`. Caso contrário, use os **contadores** acima como evidência.

Teste de SYN flood (opcional, no `atacante`):
```bash
hping3 -S --flood -p 443 172.31.200.10      # Ctrl+C depois de uns 5 s
```
Depois, `iptables -L LOG_DROP -n -v` no servidor mostra o contador subindo.

### Etapa 9 – Evidência: SSH como root bloqueado
No `cliente`:
```bash
ssh -p 2222 root@192.168.10.1                 # Permission denied (publickey)
ssh -p 22 admin_grid@192.168.10.1             # trava/timeout (porta antiga fechada)
ssh -p 2222 -o PubkeyAuthentication=no admin_grid@192.168.10.1   # senha não é aceita
```
No `atacante`, o SSH pela WAN nem chega no servidor:
```bash
nc -zv -w 3 172.31.200.10 2222                # timeout
```
Registro no servidor:
```bash
docker compose exec servidor tail -20 /var/log/sshd.log
```
**Rate-limit anti força bruta** (no `cliente`; espere 60 s depois):
```bash
for i in 1 2 3 4 5 6; do ssh -p 2222 -o ConnectTimeout=3 -o PubkeyAuthentication=no teste@192.168.10.1; done
```
A partir da 4ª tentativa em 60 s a conexão expira (firewall descartando).

### Etapa 10 – GPG: chaves e troca criptografada (Módulo 3)
Simulamos 3 administradores: **Admin1** (no `cliente`), **Admin2** (usuário `admin_grid` no `servidor`) e **Admin3** (outro diretório GPG no `cliente`). Em todo terminal que gerar chave rode antes `export GPG_TTY=$(tty)`.

**1) Gerar as chaves**
```bash
# Admin1 - no cliente
docker compose exec cliente bash
export GPG_TTY=$(tty)
gpg --quick-generate-key "Admin Um <admin1@grupo9.lab>" default default 2y
gpg --armor --export admin1@grupo9.lab > /gpg/admin1_publica.asc

# Admin3 - no cliente, com outro chaveiro
mkdir -m 700 /root/gpg_admin3
GNUPGHOME=/root/gpg_admin3 gpg --quick-generate-key "Admin Tres <admin3@grupo9.lab>" default default 2y
GNUPGHOME=/root/gpg_admin3 gpg --armor --export admin3@grupo9.lab > /gpg/admin3_publica.asc
exit

# Admin2 - no servidor, como admin_grid
docker compose exec -u admin_grid servidor bash
export GPG_TTY=$(tty)
gpg --quick-generate-key "Admin Dois <admin2@grupo9.lab>" default default 2y
gpg --armor --export admin2@grupo9.lab > ~/admin2_publica.asc
exit
```

**2) Trocar chaves públicas pelo SSH endurecido e assiná-las** (no `cliente`)
```bash
docker compose exec cliente bash
export GPG_TTY=$(tty)
scp -P 2222 admin_grid@192.168.10.1:admin2_publica.asc /gpg/
gpg --import /gpg/admin2_publica.asc /gpg/admin3_publica.asc
gpg --fingerprint admin2@grupo9.lab            # confira o fingerprint com o colega
gpg --sign-key admin2@grupo9.lab
gpg --sign-key admin3@grupo9.lab
gpg --list-sigs                                # mostra as assinaturas (print!)
```
O Admin2 também precisa das chaves dos colegas. Envie-as do `cliente` para o `servidor` e importe lá:
```bash
# no cliente:
scp -P 2222 /gpg/admin1_publica.asc /gpg/admin3_publica.asc admin_grid@192.168.10.1:
# no servidor (como admin_grid):
gpg --import admin1_publica.asc admin3_publica.asc
gpg --sign-key admin1@grupo9.lab
```

**3) Cifrar arquivo sensível para os 3 admins** (no `cliente`)
```bash
cat > /root/config_sensivel.env <<'EOF'
DB_USER=telemetria_app
DB_PASS=Tr0c4-Est4-Senh4!
API_TOKEN=tok_grid_9f8a7b6c5d4e3f2a1b
EOF

gpg --encrypt --sign --armor \
    -r admin1@grupo9.lab -r admin2@grupo9.lab -r admin3@grupo9.lab \
    -o /root/config_sensivel.env.asc /root/config_sensivel.env
shred -u /root/config_sensivel.env             # apaga o original em texto puro
cat /root/config_sensivel.env.asc              # ilegível (print!)
scp -P 2222 /root/config_sensivel.env.asc admin_grid@192.168.10.1:
```

**4) Decifrar** (no `servidor`, como Admin2)
```bash
gpg --decrypt config_sensivel.env.asc          # mostra o conteúdo + "Good signature" (print!)
```
**5) Prova de que quem não tem a chave não lê** (no `servidor`, como root):
```bash
docker compose exec servidor gpg --decrypt /home/admin_grid/config_sensivel.env.asc
# -> "decryption failed: No secret key"
```
As chaves públicas ficam em `gpg/*.asc`. **Nunca** suba chave privada ao GitHub.

### Etapa 11 – Verificação de integridade SHA-256 (Módulo 3)
> Rode `--init` **depois** do firewall, para o hash das regras ser o definitivo.
```bash
docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --init
docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --check   # tudo [OK] (print!)
```
**Simular uma alteração não autorizada:**
```bash
docker compose exec servidor useradd intruso_teste
docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --check   # ALERTA vermelho (print!)
docker compose exec servidor tail /var/log/integrity_check.log
```
**Verificação automática:** o servidor roda `--check` sozinho a cada 60 s (variável `INTEGRITY_INTERVAL`). Depois de uma alteração, em até 1 minuto:
```bash
docker compose exec servidor tail /var/log/integrity_check.log
```
Limpar e refazer a base:
```bash
docker compose exec servidor userdel intruso_teste
docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --init
```
Para testar as regras do firewall: `docker compose exec servidor iptables -A INPUT -p tcp --dport 8080 -j ACCEPT`, e o `--check` acusa "regras ATIVAS modificadas". Depois rode o `firewall.sh` e o `--init` de novo.

### Etapa 12 – Parar, reiniciar e limpar
```bash
docker compose stop                 # para (mantém tudo)
docker compose start                # volta; o firewall é restaurado do volume
docker compose down                 # remove containers (volumes e regras ficam)
docker compose down -v              # remove TUDO (volta ao estado inicial vulnerável)
```
> Após `down -v` refaça o hardening, o firewall e o `--init`.

### Etapa 13 – GitHub
```bash
git add .
git commit -m "Laboratório Docker: firewall, hardening, GPG e integridade"
git push
```

---

## 5. Checklist de evidências exigidas

- [ ] `ip -br a` e `ip route` no servidor (IP estático + rota estática)
- [ ] Nmap antes do firewall (`evidencias/nmap_antes.txt`)
- [ ] Nmap depois do firewall (`evidencias/nmap_depois.txt`) + contadores do iptables
- [ ] Tentativa de SSH como root bloqueada
- [ ] Chaves GPG listadas/assinadas + arquivo cifrado + decifragem
- [ ] Alerta automático de alteração via SHA-256
- [ ] Chaves públicas GPG exportadas (`gpg/*.asc`)

## 6. Problemas comuns

| Problema | Solução |
|----------|---------|
| `verificar_modulos.sh` mostra `[FALHA]` | O kernel do host não tem o módulo. Tente `update-alternatives --set iptables /usr/sbin/iptables-legacy` no servidor; se persistir, use Linux nativo ou uma VM Linux com Docker |
| `bad interpreter: /usr/bin/env bash^M` | Fim de linha do Windows. `git config core.autocrlf false`, apague a pasta e clone de novo |
| `hardening.sh` diz que não há chave | Espere alguns segundos após o `up` ou veja `docker compose logs cliente` |
| `Permission denied (publickey)` na 2222 | Rode o hardening antes; confira `docker compose exec servidor ls -l /home/admin_grid/.ssh` |
| Fui banido do próprio servidor por scan | `docker compose exec servidor sh -c 'echo / > /proc/net/xt_recent/PORTSCAN'` |
| Alerta de integridade após `useradd`/`passwd` | Mudança legítima: rode `--init` de novo |
| `gpg: problema com o agente` / sem pedir senha | `export GPG_TTY=$(tty)` no terminal |
| Conflito de sub-rede ao subir | Troque `172.31.200.0/24` (docker-compose.yml e `WAN_NET` no firewall.sh) |

## 7. Diferenças VM x Docker (para o relatório)

| Item | VM Ubuntu Server | Este laboratório (Docker) |
|------|------------------|---------------------------|
| Kernel | Próprio | Compartilhado com o host |
| IP estático | netplan | `ipv4_address` no Compose |
| Rotas estáticas | netplan `routes` | `ip route` no entrypoint |
| Persistência do firewall | iptables-persistent | volume + `iptables-restore` no entrypoint |
| Reiniciar SSH | `systemctl restart ssh` | reinício do daemon pelo script |
| sysctl de rede (`net.*`) | `/etc/sysctl.d` | bloco `sysctls` do Compose |
| sysctl de kernel (`kernel.*`) | aplicado | não aplicável (pertence ao host) |
| `auditd` / atualizações automáticas | ativos | não se aplicam; usa-se hash SHA-256 e log do SSH |
| Logs do iptables (`LOG`) | `journalctl -k` | contadores (`-v`) ou `dmesg` do host |

O arquivo `config/referencia-vm/01-netcfg.yaml` mostra a configuração equivalente em netplan, caso o professor exija VM.
