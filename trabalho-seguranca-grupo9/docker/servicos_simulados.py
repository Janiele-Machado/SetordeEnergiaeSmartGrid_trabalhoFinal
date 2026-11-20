#!/usr/bin/env python3
"""
servicos_simulados.py - abre portas TCP que imitam os serviços do cenário Smart Grid,
para o Nmap ter o que encontrar antes/depois do firewall. Não implementa os protocolos
reais: apenas envia um banner e fecha a conexão.

Cada porta aceita uma conexao TCP por vez em sua propria thread. O banner serve
para demonstracao em ambiente isolado; nao ha negociacao TLS, formato Modbus,
DNP3, IEC 60870-5-104 ou OPC UA, nem leitura/escrita de dados de processo.
"""
import socket
import threading

# Mapa de porta TCP para texto indicativo enviado ao cliente. As portas abertas
# correspondem a servicos publicos e industriais descritos no README/testes;
# o nome do banner deixa explicito que a implementacao e somente simulada.
SERVICOS = {
    443:   "HTTPS-PAINEL-SIMULADO",
    8883:  "MQTT-TLS-MEDIDORES-SIMULADO",
    502:   "MODBUS-TCP-SIMULADO",
    20000: "DNP3-SIMULADO",
    2404:  "IEC60870-5-104-SIMULADO",
    4840:  "OPC-UA-SIMULADO",
}


def atender(porta: int, nome: str) -> None:
    """Escuta numa porta e envia um banner curto a cada conexao.

    Args:
        porta: Porta TCP local que o socket deve escutar.
        nome: Texto identificador enviado ao cliente antes de fechar a conexao.

    A funcao bloqueia em accept() enquanto aguarda clientes. Ela e executada
    numa thread daemon para que cada porta possa ser atendida independentemente.
    """
    # AF_INET seleciona IPv4 e SOCK_STREAM seleciona TCP.
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # Permite reiniciar o processo sem esperar que o sistema libere a porta
    # mantida temporariamente em TIME_WAIT por conexoes anteriores.
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Escuta em todas as interfaces IPv4 do container para que o firewall, e
    # nao o bind local, seja responsavel por permitir ou bloquear o acesso.
    srv.bind(("0.0.0.0", porta))
    # Fila de conexoes pendentes aceita ate 50 conexoes enquanto esta thread
    # aguarda a proxima chamada a accept().
    srv.listen(50)
    while True:
        # accept bloqueia ate chegar uma conexao e devolve um socket dedicado
        # a essa conexao, alem do endereco do cliente (nao usado pelo simulador).
        conn, _ = srv.accept()
        try:
            # Converte o texto para bytes UTF-8 e envia uma linha ao cliente.
            conn.sendall((nome + "\n").encode())
        except OSError:
            # O cliente pode fechar a conexao antes de receber todos os bytes.
            # Nesse caso nao ha recuperacao util: a conexao atual e encerrada.
            pass
        finally:
            # Fecha o socket mesmo quando o envio falha, liberando o recurso.
            conn.close()


# Cria uma thread daemon por porta para que a espera por uma conexao em uma
# porta nao impeça as demais de aceitarem conexoes.
for porta, nome in SERVICOS.items():
    threading.Thread(target=atender, args=(porta, nome), daemon=True).start()

# As threads daemon terminariam quando a thread principal terminasse. A espera
# indefinida mantem o processo vivo ate o container ser encerrado.
threading.Event().wait()   # mantém o processo vivo
