#!/usr/bin/env python3
"""Minimal mock of the Telegram Bot API for testing tg-send / tg-bot."""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LOG = os.environ["MOCK_LOG"]
UPDATES_FILE = os.environ.get("MOCK_UPDATES", "")

def load_updates():
    if UPDATES_FILE and os.path.exists(UPDATES_FILE):
        with open(UPDATES_FILE) as f:
            return json.load(f)
    return []

def logline(d):
    with open(LOG, "a") as f:
        f.write(json.dumps(d) + "\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _method(self):
        return urlparse(self.path).path.rsplit("/", 1)[-1]

    def _form(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        # multipart (sendDocument) — just grab a marker; we only assert it was called
        if "multipart/form-data" in self.headers.get("Content-Type", ""):
            return {"_multipart": [raw[:200]]}
        return parse_qs(raw)

    def handle_method(self, method, params):
        if method == "getMe":
            return {"ok": True, "result": {"id": 1, "is_bot": True,
                    "username": "mockbot", "first_name": "Mock"}}
        if method == "deleteWebhook":
            return {"ok": True, "result": True}
        if method == "getUpdates":
            offset = int((params.get("offset") or ["0"])[0])
            ups = [u for u in load_updates() if u["update_id"] >= offset]
            if not ups:
                time.sleep(0.3)  # cheap fake long-poll
            return {"ok": True, "result": ups}
        if method in ("sendMessage", "sendDocument"):
            if os.path.exists(os.environ.get("MOCK_FAIL_FILE", "")):
                return {"ok": False, "description": "Bad Request: simulated failure"}
            entry = {"method": method,
                     "chat_id": (params.get("chat_id") or [""])[0],
                     "text": (params.get("text") or [""])[0],
                     "multipart": "_multipart" in params}
            logline(entry)
            return {"ok": True, "result": {"message_id": 1}}
        if method == "setMyCommands":
            logline({"method": "setMyCommands",
                     "commands": (params.get("commands") or [""])[0]})
            return {"ok": True, "result": True}
        if method == "fail":  # error-path endpoint
            return {"ok": False, "description": "Bad Request: simulated failure"}
        return {"ok": False, "description": f"unknown method {method}"}

    def do_GET(self):
        params = parse_qs(urlparse(self.path).query)
        self._send(self.handle_method(self._method(), params))

    def do_POST(self):
        self._send(self.handle_method(self._method(), self._form()))

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
port = srv.server_address[1]
with open(os.environ["MOCK_PORT_FILE"], "w") as f:
    f.write(str(port))
srv.serve_forever()
