# HTTP server that misbehaves on purpose, one mode per path:
#   /silent   accept and read the request, never answer (the 2026-09-08 symptom)
#   /midbody  send headers and part of the body, then stall
#   /ok       normal response (control)
import socket, sys, threading, time

def handle(conn):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(65536)
            if not chunk: return
            req += chunk
        path = req.split(b" ")[1].decode()
        if path.startswith("/ok"):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        elif path.startswith("/midbody"):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial")
            time.sleep(3600)
        else:
            time.sleep(3600)
    finally:
        conn.close()

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(16)
print("listening", flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
