# Plano de Testes e Evidências – Grupo 9 (Energia e Smart Grid)

Este documento descreve **todos os testes** do laboratório, o **resultado esperado** e **qual print tirar** em cada um. Os prints marcados com ★ são exigidos explicitamente no enunciado.

- **Ambiente:** 3 containers (`servidor`, `cliente`, `atacante`), definidos no `docker-compose.yml`
- **Onde salvar os prints:** pasta `evidencias/`, com o nome sugerido em cada teste
- **Executor / data:** ______________________ / ____/____/2026

---

## 0. Antes de começar

### Dicas para prints profissionais

1. **Mostre sempre o comando e a saída** no mesmo print (não corte o comando).
2. Rode `date` antes do comando principal, para a data/hora aparecer no print.
3. Aumente a fonte do terminal e use fundo escuro com letras claras (melhor leitura no PDF).
4. Um teste = um ou dois prints. Não junte vários testes numa imagem só.
5. Mantenha o padrão de nome: `NN_assunto.png` (ex.: `05_ssh_root_bloqueado.png`).

### Salvar a saída de comandos em arquivo (PowerShell)

No Windows, o `>` do PowerShell grava em UTF-16 e fica ilegível. Use:

```powershell
docker compose exec -T servidor iptables -L -n -v | Out-File -Encoding utf8 evidencias\iptables_regras.txt
```

### Ordem recomendada de execução

A ordem importa (o "antes" e o "depois" do firewall dependem dela):

`T01 → T02 → T03 → T04 → T05 → T06 → T07 → T08 → T09 → T10 → T11 → T12 → T13 → T14 → T15 → T16 → T17 → T18 → T19 → T20`

> **Atenção ao banimento:** o firewall bloqueia por 5 minutos o IP que toca em porta fechada. Antes de **cada** teste feito pelo `atacante` depois do firewall, libere-o:
> ```powershell
> docker compose exec servidor sh -c "echo / > /proc/net/xt_recent/PORTSCAN"
> ```
> Para zerar os contadores e ver só o efeito do teste atual: `docker compose exec servidor iptables -Z`

---

## Parte A – Ambiente e rede (Módulo 2)

### T01 – Laboratório no ar

| | |
|---|---|
| **Objetivo** | Comprovar que os 3 containers estão rodando |
| **Comando** | `docker compose ps` |
| **Esperado** | `servidor`, `cliente` e `atacante` com status `running` |
| **Print** | `evidencias/01_docker_compose_ps.png` |

### T02 – Kernel do host suporta o firewall

| | |
|---|---|
| **Objetivo** | Validar os módulos do netfilter usados (recent, hashlimit, connlimit...) |
| **Comando** | `docker compose exec servidor bash /opt/projeto/scripts/verificar_modulos.sh` |
| **Esperado** | Todos `[OK]` e a mensagem "pode rodar o firewall.sh" |
| **Print** | `evidencias/02_verificar_modulos.png` |

### T03 ★ – IP estático e roteamento estático

| | |
|---|---|
| **Objetivo** | Provar IPs fixos em WAN e LAN, rota padrão e rota estática |
| **Comandos** | `docker compose exec servidor ip -br a` <br> `docker compose exec servidor ip route` <br> `docker compose exec cliente ip route` |
| **Esperado** | Servidor com `172.31.200.10/24` (WAN) e `192.168.10.1/24` (LAN); rota `10.20.0.0/24 via 192.168.10.2`; cliente com `default via 192.168.10.1` |
| **Prints** | `evidencias/03a_servidor_ip_rotas.png` (os dois comandos do servidor juntos) e `evidencias/03b_cliente_rota.png` |

### T04 – Conectividade e NAT (antes do firewall)

| | |
|---|---|
| **Objetivo** | Mostrar que o cliente (rede interna isolada) sai para a internet passando pelo servidor |
| **Comandos** | `docker compose exec cliente ping -c 3 192.168.10.1` <br> `docker compose exec cliente ping -c 3 8.8.8.8` |
| **Esperado** | 0% de perda nos dois |
| **Print** | `evidencias/04_conectividade_nat.png` |

---

## Parte B – Hardening do SO e do SSH (Módulo 2)

### T05 – Estado inicial vulnerável ("antes")

| | |
|---|---|
| **Objetivo** | Mostrar o risco antes do hardening: root entra com senha na porta 22 |
| **Comando** | `docker compose exec cliente ssh -o StrictHostKeyChecking=accept-new root@192.168.10.1` (senha: `root123`) |
| **Esperado** | Login como root **bem-sucedido** (prompt `root@servidor-energia`). Digite `exit` |
| **Print** | `evidencias/05_antes_root_entra.png` |

### T06 – Aplicação do hardening

| | |
|---|---|
| **Objetivo** | Executar o hardening do SO e do SSH |
| **Comando** | `docker compose exec servidor bash /opt/projeto/scripts/hardening.sh admin_grid` |
| **Esperado** | Passos 1/7 a 7/7 concluídos e a mensagem "Hardening concluído! SSH agora escuta na porta 2222" |
| **Prints** | `evidencias/06a_hardening_inicio.png` e `evidencias/06b_hardening_fim.png` (a saída é longa: tire do início e do fim) |

### T07 – Parâmetros efetivos do SSH e permissões do SO

| | |
|---|---|
| **Objetivo** | Provar a configuração aplicada |
| **Comandos** | `docker compose exec servidor bash -c "sshd -T \| grep -Ei '^(port\|permitrootlogin\|passwordauthentication\|pubkeyauthentication\|allowusers\|maxauthtries)'"` <br> `docker compose exec servidor ls -l /etc/passwd /etc/shadow /etc/ssh/sshd_config` <br> `docker compose exec servidor ls -ld /etc /var/log /root` <br> `docker compose exec servidor sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects` |
| **Esperado** | `port 2222`, `permitrootlogin no`, `passwordauthentication no`, `pubkeyauthentication yes`, `allowusers admin_grid`, `maxauthtries 3`; `/etc/shadow` com `-rw-r-----`; `sshd_config` com `-rw-------`; `rp_filter = 1` |
| **Print** | `evidencias/07a_sshd_parametros.png` e `evidencias/07b_permissoes_sysctl.png` |

### T08 ★ – SSH como root bloqueado e demais bloqueios

| | |
|---|---|
| **Objetivo** | Provar: root negado, senha negada, porta 22 fechada, usuário admin entra só com chave |
| **Comandos** | 1) `docker compose exec cliente ssh -p 2222 root@192.168.10.1` <br> 2) `docker compose exec cliente ssh -p 2222 -o PubkeyAuthentication=no admin_grid@192.168.10.1` <br> 3) `docker compose exec cliente ssh -p 22 -o ConnectTimeout=5 admin_grid@192.168.10.1` <br> 4) `docker compose exec cliente ssh -p 2222 admin_grid@192.168.10.1` (depois `exit`) <br> 5) `docker compose exec servidor tail -20 /var/log/sshd.log` |
| **Esperado** | 1) `Permission denied (publickey)` <br> 2) `Permission denied (publickey)` (senha não é aceita) <br> 3) `Connection refused` ou *timeout* <br> 4) entra **sem pedir senha**, exibindo o banner "SISTEMA RESTRITO" <br> 5) log com a recusa do root (ex.: *User root ... not allowed because not listed in AllowUsers*) |
| **Prints** | `evidencias/08a_ssh_root_negado.png` ★, `evidencias/08b_ssh_senha_negada.png`, `evidencias/08c_ssh_porta22.png`, `evidencias/08d_ssh_chave_ok_banner.png`, `evidencias/08e_log_sshd.png` |

---

## Parte C – Firewall (Módulo 2)

### T09 ★ – Nmap ANTES do firewall

| | |
|---|---|
| **Objetivo** | Mostrar a superfície de ataque exposta sem firewall |
| **Comandos** | `docker compose exec atacante bash -c "date; nmap -sS -sV -p- -T4 172.31.200.10 -oN /evidencias/nmap_antes.txt"` <br> `docker compose exec atacante nc -zv -w 3 172.31.200.10 502` |
| **Esperado** | Portas **abertas**: 2222 (ssh), 443, 8883, 502, 20000, 2404, 4840. O `nc` na 502 conecta |
| **Print** | `evidencias/09_nmap_antes.png` ★ (e o arquivo `evidencias/nmap_antes.txt` gerado) |

### T10 ★ – Aplicação e regras do firewall

| | |
|---|---|
| **Objetivo** | Aplicar o `firewall.sh` e mostrar as regras ativas |
| **Comandos** | `docker compose exec servidor bash /opt/projeto/scripts/firewall.sh` <br> `docker compose exec servidor iptables -L INPUT -n -v --line-numbers` <br> `docker compose exec servidor iptables -L FORWARD -n -v --line-numbers` <br> `docker compose exec servidor iptables -t nat -L POSTROUTING -n -v` <br> `docker compose exec servidor iptables -S` |
| **Esperado** | Saída do script com as interfaces detectadas; `Chain INPUT (policy DROP)` e `Chain FORWARD (policy DROP)`; regra `MASQUERADE` na NAT |
| **Prints** | `evidencias/10a_firewall_aplicado.png`, `evidencias/10b_iptables_input.png` (se não couber, divida em dois), `evidencias/10c_iptables_forward_nat.png` |

### T11 ★ – Nmap DEPOIS do firewall

| | |
|---|---|
| **Objetivo** | Mostrar que só as portas públicas continuam acessíveis pela WAN |
| **Comandos** (nesta ordem) | 1) `docker compose exec servidor sh -c "echo / > /proc/net/xt_recent/PORTSCAN"` <br> 2) `docker compose exec atacante nmap -sS -p 443,8883 172.31.200.10` <br> 3) `docker compose exec atacante bash -c "date; nmap -sS -sV -p- -T4 172.31.200.10 -oN /evidencias/nmap_depois.txt"` |
| **Esperado** | 2) **443 e 8883 `open`**. 3) as demais portas (2222, 502, 20000, 2404, 4840) **`filtered`**; como o IP é banido ao tocar numa porta fechada, o scan completo pode mostrar quase tudo `filtered` |
| **Prints** | `evidencias/11a_nmap_portas_liberadas.png`, `evidencias/11b_nmap_depois_completo.png` ★ |

> Para o relatório, compare lado a lado `nmap_antes.txt` x `nmap_depois.txt` (abertas → filtradas).

### T12 – Detecção de port scan (Null, FIN, Xmas) e banimento

| | |
|---|---|
| **Objetivo** | Provar que scans furtivos são detectados e o IP é banido |
| **Comandos** | 1) `docker compose exec servidor sh -c "echo / > /proc/net/xt_recent/PORTSCAN"` <br> 2) `docker compose exec servidor iptables -Z` <br> 3) `docker compose exec atacante nmap -sN -sF -sX -p 1-1000 172.31.200.10` <br> 4) `docker compose exec servidor iptables -L SCAN_BLOCK -n -v` <br> 5) `docker compose exec servidor cat /proc/net/xt_recent/PORTSCAN` |
| **Esperado** | 3) portas `open\|filtered`/`filtered` (sem resposta). 4) contadores `pkts` **maiores que zero** em SCAN_BLOCK. 5) aparece `src=172.31.200.60` (IP do atacante banido) |
| **Prints** | `evidencias/12a_nmap_scans_furtivos.png`, `evidencias/12b_contadores_scan_block.png`, `evidencias/12c_lista_banidos.png` |

### T13 – Proteção contra força bruta no SSH (rate-limit)

| | |
|---|---|
| **Objetivo** | Mostrar que após 3 conexões em 60 s o firewall passa a descartar as seguintes |
| **Comando** | `docker compose exec cliente bash -c "date; for i in 1 2 3 4 5 6; do echo tentativa \$i; ssh -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=4 teste@192.168.10.1; done"` |
| **Esperado** | Tentativas 1–3: `Permission denied`. Tentativas 4–6: *timeout* (conexão descartada). Em seguida: `docker compose exec servidor iptables -L LOG_DROP -n -v` com contador > 0 |
| **Print** | `evidencias/13a_bruteforce_ssh.png` e `evidencias/13b_contador_log_drop.png` |

> Aguarde 60 s antes de usar o SSH de novo (a lista de bloqueio expira).

> No PowerShell, se o `\$i` der problema, apague a parte `echo tentativa \$i;`. O teste funciona igual.

### T14 – Proteção contra DoS (SYN flood)

| | |
|---|---|
| **Objetivo** | Mostrar o limite de SYN por IP funcionando |
| **Comandos** | 1) `docker compose exec servidor sh -c "echo / > /proc/net/xt_recent/PORTSCAN"` <br> 2) `docker compose exec servidor iptables -Z` <br> 3) `docker compose exec atacante timeout 5 hping3 -S --flood -p 443 172.31.200.10` <br> 4) `docker compose exec servidor iptables -L LOG_DROP -n -v` <br> 5) `docker compose exec servidor iptables -L INPUT -n -v` |
| **Esperado** | Contador `pkts` de LOG_DROP **muito alto** (milhares de SYN descartados); a regra `hashlimit` aparece com contador alto no INPUT |
| **Print** | `evidencias/14a_hping3_flood.png` e `evidencias/14b_contadores_synflood.png` |

### T15 – Segmentação: protocolos industriais só na rede interna

| | |
|---|---|
| **Objetivo** | Provar que Modbus/DNP3/IEC-104/OPC UA **não** são acessíveis pela WAN, mas são pela LAN |
| **Comandos** | 1) `docker compose exec servidor sh -c "echo / > /proc/net/xt_recent/PORTSCAN"` <br> 2) `docker compose exec atacante nc -zv -w 3 172.31.200.10 502` <br> 3) `docker compose exec cliente nc -zv -w 3 192.168.10.1 502` <br> 4) `docker compose exec cliente nc -zv -w 3 192.168.10.1 20000` <br> 5) `docker compose exec atacante nc -zv -w 3 172.31.200.10 443` (a pública) |
| **Esperado** | 2) *timed out* (bloqueado na WAN). 3) e 4) `succeeded` (liberado na LAN). 5) `succeeded` |
| **Print** | `evidencias/15_segmentacao_ot.png` (os 4 comandos no mesmo print, se possível) |

> Dica: rode o item 1 de novo antes do item 5, pois o item 2 já bane o atacante.

### T16 – NAT e filtragem de saída (FORWARD)

| | |
|---|---|
| **Objetivo** | Mostrar que a rede interna só sai com o essencial (web/DNS/NTP) |
| **Comandos** | 1) `docker compose exec cliente nc -zv -w 4 1.1.1.1 443` <br> 2) `docker compose exec cliente nc -zv -w 4 1.1.1.1 22` <br> 3) `docker compose exec cliente ping -c 2 8.8.8.8` |
| **Esperado** | 1) `succeeded` (HTTPS permitido). 2) *timed out* (SSH de saída bloqueado). 3) responde |
| **Print** | `evidencias/16_forward_saida.png` |

### T17 – Persistência do firewall após reinício

| | |
|---|---|
| **Objetivo** | Provar que as regras sobrevivem a um restart (equivale ao iptables-persistent) |
| **Comandos** | `docker compose restart servidor` <br> `docker compose exec servidor iptables -L INPUT -n \| head -5` |
| **Esperado** | Após o restart, `Chain INPUT (policy DROP)` com as regras restauradas (log do container: "regras do iptables restauradas") |
| **Print** | `evidencias/17_persistencia_firewall.png` |

---

## Parte D – GPG e integridade (Módulo 3)

### T18 ★ – GPG: chaves, assinatura e troca criptografada

Siga a **Etapa 10 do README** (geração das 3 chaves, troca de chaves públicas via `scp -P 2222`, assinatura mútua, cifragem e decifragem). Os prints necessários:

| Print | O que deve aparecer |
|---|---|
| `evidencias/18a_gpg_chaves_geradas.png` | `gpg --list-keys` com as chaves dos admins |
| `evidencias/18b_gpg_fingerprint_assinatura.png` | `gpg --fingerprint` e `gpg --list-sigs` mostrando as **assinaturas cruzadas** |
| `evidencias/18c_gpg_arquivo_cifrado.png` | `cat config_sensivel.env.asc` (bloco `-----BEGIN PGP MESSAGE-----` ilegível) |
| `evidencias/18d_gpg_transferencia_scp.png` | `scp -P 2222 ...` enviando o `.asc` ao servidor |
| `evidencias/18e_gpg_decifragem_ok.png` ★ | `gpg --decrypt` no servidor exibindo as credenciais e **"Good signature from Admin Um"** |
| `evidencias/18f_gpg_sem_chave_falha.png` | `docker compose exec servidor gpg --decrypt /home/admin_grid/config_sensivel.env.asc` → **"decryption failed: No secret key"** |

Entregável: arquivos `gpg/admin1_publica.asc`, `gpg/admin2_publica.asc` e `gpg/admin3_publica.asc` versionados no repositório.

### T19 ★ – Integridade SHA-256: linha de base e verificação limpa

| | |
|---|---|
| **Objetivo** | Criar a base de hashes e validar que tudo está íntegro |
| **Comandos** | `docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --init` <br> `docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --check` |
| **Esperado** | `--init` lista os hashes de `/etc/passwd`, `/etc/shadow` e `rules.v4`; `--check` mostra `[OK]` em verde para os três e para as regras ativas |
| **Print** | `evidencias/19a_integridade_init.png` e `evidencias/19b_integridade_ok.png` |

### T20 ★ – Detecção automática de alteração não autorizada

| | |
|---|---|
| **Objetivo** | Provar que o alerta dispara quando um arquivo monitorado muda |
| **Comandos** | 1) `docker compose exec servidor useradd intruso_teste` <br> 2) `docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --check` <br> 3) `docker compose exec servidor tail -10 /var/log/integrity_check.log` <br> 4) *(automático)* aguarde até 60 s e rode `docker compose exec servidor tail /var/log/integrity_check.log` de novo, sem executar o `--check` manualmente |
| **Esperado** | 2) **[!!! ALERTA DE INTEGRIDADE !!!]** em vermelho para `/etc/passwd` e `/etc/shadow`. 3) e 4) linhas `[ALERTA]` no log com data/hora (4 prova a verificação periódica) |
| **Prints** | `evidencias/20a_alerta_passwd_shadow.png` ★, `evidencias/20b_log_alerta.png`, `evidencias/20c_alerta_automatico.png` |

**Alteração das regras do firewall (bônus):**

| | |
|---|---|
| **Comandos** | `docker compose exec servidor iptables -A INPUT -p tcp --dport 8080 -j ACCEPT` <br> `docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --check` |
| **Esperado** | Alerta "Regras ATIVAS do iptables foram modificadas!" |
| **Print** | `evidencias/20d_alerta_regras_iptables.png` |

**Restaurar o ambiente depois do teste:**

```powershell
docker compose exec servidor userdel intruso_teste
docker compose exec servidor bash /opt/projeto/scripts/firewall.sh
docker compose exec servidor bash /opt/projeto/scripts/integrity_check.sh --init
```

---

## Resumo dos resultados (preencher)

| ID | Teste | Requisito | Resultado | Print |
|----|-------|-----------|:---------:|-------|
| T01 | Containers no ar | Infra | ☐ OK ☐ Falhou | 01 |
| T02 | Módulos do kernel | Infra | ☐ OK ☐ Falhou | 02 |
| T03 | IP estático + rotas | M2 – Rede | ☐ OK ☐ Falhou | 03a, 03b |
| T04 | Conectividade / NAT | M2 – Rede | ☐ OK ☐ Falhou | 04 |
| T05 | Estado vulnerável (antes) | M2 – SSH | ☐ OK ☐ Falhou | 05 |
| T06 | Hardening aplicado | M2 – Hardening | ☐ OK ☐ Falhou | 06a, 06b |
| T07 | Parâmetros SSH e permissões | M2 – Hardening | ☐ OK ☐ Falhou | 07a, 07b |
| T08 | Root/senha bloqueados | M2 – SSH ★ | ☐ OK ☐ Falhou | 08a–e |
| T09 | Nmap antes | M2 – Firewall ★ | ☐ OK ☐ Falhou | 09 |
| T10 | Regras do firewall | M2 – Firewall ★ | ☐ OK ☐ Falhou | 10a–c |
| T11 | Nmap depois | M2 – Firewall ★ | ☐ OK ☐ Falhou | 11a, 11b |
| T12 | Port scan detectado | M2 – Firewall | ☐ OK ☐ Falhou | 12a–c |
| T13 | Rate-limit força bruta | M2 – Firewall | ☐ OK ☐ Falhou | 13a, 13b |
| T14 | SYN flood (DoS) | M2 – Firewall | ☐ OK ☐ Falhou | 14a, 14b |
| T15 | Segmentação OT | Cenário Smart Grid | ☐ OK ☐ Falhou | 15 |
| T16 | NAT e FORWARD | M2 – Firewall | ☐ OK ☐ Falhou | 16 |
| T17 | Persistência | M2 – Firewall | ☐ OK ☐ Falhou | 17 |
| T18 | GPG (troca cifrada) | M3 – GPG ★ | ☐ OK ☐ Falhou | 18a–f |
| T19 | Integridade – base e check | M3 – Hashes ★ | ☐ OK ☐ Falhou | 19a, 19b |
| T20 | Alteração detectada | M3 – Hashes ★ | ☐ OK ☐ Falhou | 20a–d |

## Observações / problemas encontrados

_(Anote aqui qualquer divergência do resultado esperado e como foi resolvida. Isso rende bons pontos na arguição e no relatório.)_

-
-
