# Stub ComfyUI server for the headless checks: enough of /system_stats, /upload/image, /prompt,
# /history/{id}, /view and (optionally) /ws that the app's remote runner completes offline. /history answers
# empty for its first two calls per prompt, so the runner's polling loop is exercised. Received uploads and
# prompt graphs are dumped to a JSON file the checks read back.
# Run: python3 comfy_stub.py PORT PNG_B64 DUMP [mode]
#   mode ""        remote runner completes on polling alone (the WebSocket, if used, fails and is ignored)
#   mode progress  after each /prompt the socket sends step progress, then a finish event
#   mode error     /history reports a failed prompt and the socket sends execution_error
import base64, hashlib, json, os, re, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
PNG = base64.b64decode(open(sys.argv[2]).read())
DUMP = sys.argv[3]
MODE = sys.argv[4] if len(sys.argv) > 4 else ""
NONCE = sys.argv[5] if len(sys.argv) > 5 else ""
state = {"uploads": [], "prompts": [], "hits": {}, "outputs": {}, "interrupted": False}
sockets = {}   # client_id → raw ws socket, registered by the upgrade handler

def flush():
    tmp = DUMP + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, DUMP)

def ws_frame(text):
    payload = text.encode()
    length = len(payload)
    head = bytearray([0x81])              # FIN + text frame
    if length < 126:
        head.append(length)
    else:
        head.append(126); head += length.to_bytes(2, "big")
    return bytes(head) + payload

def ws_send(client_id, data):
    sock = sockets.get(client_id)
    if sock is None:
        return
    try:
        sock.sendall(ws_frame(json.dumps({"type": data[0], "data": {**data[1], "prompt_id": data[2]}})))
    except OSError:
        sockets.pop(client_id, None)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _png(self):
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(PNG)))
        self.end_headers()
        self.wfile.write(PNG)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/system_stats":
            self._json({"system": {"os": "stub", "python_version": "3.12.0 stub 1.0", "comfyui_version": "0.42.0", "nonce": NONCE}})
        elif path == "/ws":
            # minimal RFC 6455 server handshake; the connection is held open for the shared progress pump
            key = re.search(r"sec-websocket-key:\s*(\S+)", self.headers.as_string(), re.I).group(1)
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            cid = dict(pair.split("=", 1) for pair in query.split("&")).get("clientId")
            sockets[cid] = self.connection
            try:
                self.connection.settimeout(60)
                while True:
                    self.connection.recv(4096)   # ignore client frames; exit when the client closes
            except OSError:
                pass
        elif path.startswith("/history/"):
            pid = path[len("/history/"):]
            state["hits"][pid] = state["hits"].get(pid, 0) + 1
            flush()
            if MODE == "error":
                self._json({pid: {"status": {"status_str": "error", "completed": False, "messages": [
                    ["execution_error", {"exception_type": "OOM", "exception_message": "CUDA out of memory in stub"}]]}}})
            elif state["hits"][pid] < 3:      # two empty polls before the image "finishes"
                self._json({})
            else:
                self._json({pid: {"outputs": {"30": {"images": [
                    {"filename": state["outputs"][pid], "subfolder": "moss-remote", "type": "output"}]}}}})
        elif path == "/view":
            self._png()
        else:
            self._json({"error": "no such route"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._body()
        if path == "/upload/image":
            names = re.findall(rb'filename="([^"]+)"', body)
            name = names[0].decode() if names else "upload.bin"
            state["uploads"].append(name)
            flush()
            self._json({"name": name, "subfolder": ""})
        elif path == "/prompt":
            obj = json.loads(body)
            pid = "stub-%d" % (len(state["prompts"]) + 1)
            state["prompts"].append(obj.get("prompt", {}))
            state["outputs"][pid] = "mock_%d_.png" % len(state["prompts"])
            flush()
            cid = obj.get("client_id")
            if MODE in ("progress", "error"):
                def pump(mode=MODE, cid=cid, pid=pid):
                    time.sleep(0.4)
                    if mode == "progress":
                        ws_send(cid, ("progress", {"value": 7, "max": 8}, pid))
                        time.sleep(0.4)
                        ws_send(cid, ("executing", {"node": None}, pid))
                    else:
                        ws_send(cid, ("execution_error", {"node_type": "KSampler", "exception_message": "OOM"}, pid))
                threading.Thread(target=pump, daemon=True).start()
            self._json({"prompt_id": pid, "number": 1, "node_to_errors": {}})
        elif path == "/interrupt":
            state["interrupted"] = True
            flush()
            self._json({})
        else:
            self._json({"error": "no such route"}, 404)

server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
server.allow_reuse_address = True
try:
    server.serve_forever()
finally:
    flush()
