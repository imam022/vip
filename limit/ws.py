#!/usr/bin/env python3
import socket
import select
import threading
import sys
import base64
import hashlib

# Pengaturan Default
LISTENING_ADDR = '127.0.0.1'
LISTENING_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 10015
DEFAULT_HOST = '127.0.0.1:143'  # Port Dropbear lokal
BUFLEN = 65536
TIMEOUT = 60
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

class ConnectionHandler(threading.Thread):
    def __init__(self, client_sock, client_addr):
        super().__init__()
        self.client = client_sock
        self.target = None
        self.client_addr = client_addr
        self.daemon = True

    def close(self):
        for s in (self.client, self.target):
            if s:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except Exception:
                    pass
                try:
                    s.close()
                except Exception:
                    pass

    def run(self):
        try:
            raw_header = self.client.recv(4096)
            if not raw_header:
                return

            header_text = raw_header.decode('latin1', errors='ignore')
            lines = header_text.split('\r\n')
            headers = {}
            for line in lines[1:]:
                if ': ' in line:
                    k, v = line.split(': ', 1)
                    headers[k.strip().lower()] = v.strip()

            # Target redirector (dukung X-Real-Host payload)
            target_raw = headers.get('x-real-host', DEFAULT_HOST)
            if not (target_raw.startswith('127.0.0.1') or target_raw.startswith('localhost')):
                target_raw = DEFAULT_HOST

            parts = target_raw.split(':')
            t_host = parts[0]
            t_port = int(parts[1]) if len(parts) > 1 else 143

            # Validasi WebSocket Handshake Key (RFC 6455)
            ws_key = headers.get('sec-websocket-key')
            if ws_key:
                accept_val = base64.b64encode(
                    hashlib.sha1((ws_key + WS_GUID).encode('utf-8')).digest()
                ).decode('utf-8')
                resp = (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept_val}\r\n\r\n"
                )
            else:
                # Fallback untuk payload lawas / raw HTTP
                resp = (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n\r\n"
                )

            # Sambungkan ke Dropbear lokal
            self.target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.target.settimeout(5)
            self.target.connect((t_host, t_port))
            self.target.settimeout(None)

            # Kirim status 101 ke injector/klien
            self.client.sendall(resp.encode('latin1'))

            # Salurkan data bolak-balik (Piping)
            self.forward_data()

        except Exception:
            pass
        finally:
            self.close()

    def forward_data(self):
        sockets = [self.client, self.target]
        idle_count = 0
        while True:
            r, _, w = select.select(sockets, [], sockets, 2)
            if w:
                break
            if r:
                idle_count = 0
                for s in r:
                    other = self.target if s is self.client else self.client
                    try:
                        data = s.recv(BUFLEN)
                        if not data:
                            return
                        other.sendall(data)
                    except Exception:
                        return
            else:
                idle_count += 2
                if idle_count >= TIMEOUT:
                    break

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind((LISTENING_ADDR, LISTENING_PORT))
        server.listen(1024)
    except Exception as e:
        sys.exit(1)

    while True:
        try:
            client_sock, client_addr = server.accept()
            ConnectionHandler(client_sock, client_addr).start()
        except KeyboardInterrupt:
            break
        except Exception:
            continue

if __name__ == '__main__':
    main()
