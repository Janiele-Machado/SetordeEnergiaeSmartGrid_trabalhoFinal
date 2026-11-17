#!/usr/bin/env python3
"""
servicos_simulados.py - abre portas TCP que imitam os serviços do cenário Smart Grid,
para o Nmap ter o que encontrar antes/depois do firewall. Não implementa os protocolos
reais: apenas envia um banner e fecha a conexão.
"""
import socket
import threading

SERVICOS = {
    443:   "HTTPS-PAINEL-SIMULADO",
    8883:  "MQTT-TLS-MEDIDORES-SIMULADO",
    502:   "MODBUS-TCP-SIMULADO",
    20000: "DNP3-SIMULADO",
    2404:  "IEC60870-5-104-SIMULADO",
    4840:  "OPC-UA-SIMULADO",
}


def atender(porta: int, nome: str) -> None:
    """Escuta em uma porta e responde com um banner a cada conexão."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", porta))
    srv.listen(50)
    while True:
        conn, _ = srv.accept()
        try:
            conn.sendall((nome + "\n").encode())
        except OSError:
            pass
        finally:
            conn.close()


for porta, nome in SERVICOS.items():
    threading.Thread(target=atender, args=(porta, nome), daemon=True).start()

threading.Event().wait()   # mantém o processo vivo
