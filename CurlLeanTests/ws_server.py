# WebSocket server for the receive regression test (raw sockets, no dependencies).
# The client sends "case <name>"; the server answers with that case's message, shaped to
# exercise reassembly: frames larger than one read, frame bytes written in pieces with
# pauses, fragmented messages with a ping in between, and delayed / absent messages.
import base64, hashlib, socket, struct, sys, threading, time

def frame(payload: bytes, opcode=0x1, fin=True) -> bytes:
    b0 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126: hdr = struct.pack("!BB", b0, n)
    elif n < 65536: hdr = struct.pack("!BBH", b0, 126, n)
    else: hdr = struct.pack("!BBQ", b0, 127, n)
    return hdr + payload

LARGE = "".join(str(i % 10) for i in range(200000)).encode()
SPLIT = ("S" * 500 + "|" + "T" * 500).encode()
UNICODE = "héllo € 日本 ✓".encode()

def answer(c, case):
    if case == "small":
        c.sendall(frame(b"hello"))
    elif case == "large":
        c.sendall(frame(LARGE))
    elif case == "split":
        f = frame(SPLIT)
        c.sendall(f[:300]); time.sleep(0.3); c.sendall(f[300:])
    elif case == "header-split":
        f = frame(SPLIT)  # pause inside the frame header itself
        c.sendall(f[:1]); time.sleep(0.2); c.sendall(f[1:])
    elif case == "unicode":
        f = frame(UNICODE)
        cut = 2 + 2  # inside the two-byte "é"
        c.sendall(f[:cut]); time.sleep(0.2); c.sendall(f[cut:])
    elif case == "fragmented":
        c.sendall(frame(b"part1-", 0x1, fin=False)); time.sleep(0.05)
        c.sendall(frame(b"ping!", 0x9)); time.sleep(0.05)
        c.sendall(frame(b"part2-", 0x0, fin=False)); time.sleep(0.05)
        c.sendall(frame(b"part3", 0x0, fin=True))
    elif case == "burst":
        c.sendall(b"".join(frame(f"m{i}".encode()) for i in range(1000)))
    elif case == "delayed":
        time.sleep(0.05); c.sendall(frame(b"late"))
    elif case == "quiet":
        pass

def read_frame(c):
    def rd(k):
        b = b""
        while len(b) < k:
            x = c.recv(k - len(b))
            if not x: raise ConnectionError
            b += x
        return b
    b0, b1 = rd(2); n = b1 & 0x7F
    if n == 126: n = struct.unpack("!H", rd(2))[0]
    elif n == 127: n = struct.unpack("!Q", rd(8))[0]
    mask = rd(4) if b1 & 0x80 else b"\0\0\0\0"
    return b0 & 0x0F, bytes(x ^ mask[i % 4] for i, x in enumerate(rd(n)))

def serve(c):
    req = b""
    while b"\r\n\r\n" not in req: req += c.recv(4096)
    key = [l.split(b":", 1)[1].strip() for l in req.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key")][0]
    acc = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + acc + b"\r\n\r\n")
    try:
        while True:
            op, data = read_frame(c)
            if op == 0x8: break
            if op == 0x1 and data.startswith(b"case "):
                answer(c, data[5:].decode())
    except (ConnectionError, OSError):
        pass
    c.close()

s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4)
print("listening", flush=True)
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
