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
        # multipart (sendDocument / sendPhoto). The text fields are written
        # before the file part, so pull them out of the head of the body —
        # tests need to assert on caption and parse_mode, not just that an
        # upload happened. The file bytes themselves are never logged.
        if "multipart/form-data" in self.headers.get("Content-Type", ""):
            out = {"_multipart": [raw[:200]]}
            for name in ("chat_id", "caption", "parse_mode"):
                marker = 'name="%s"\r\n\r\n' % name
                i = raw.find(marker)
                if i == -1:
                    continue
                j = raw.find("\r\n", i + len(marker))
                out[name] = [raw[i + len(marker):j if j != -1 else None]]
            return out
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
        if method in ("sendMessage", "sendDocument", "sendPhoto"):
            if os.path.exists(os.environ.get("MOCK_FAIL_FILE", "")):
                return {"ok": False, "description": "Bad Request: simulated failure"}
            entry = {"method": method,
                     "chat_id": (params.get("chat_id") or [""])[0],
                     "text": (params.get("text") or [""])[0],
                     "caption": (params.get("caption") or [""])[0],
                     "parse_mode": (params.get("parse_mode") or [""])[0],
                     "multipart": "_multipart" in params}
            logline(entry)
            return {"ok": True, "result": {"message_id": 1}}
        if method == "sendPoll":
            logline({"method": "sendPoll",
                     "chat_id": (params.get("chat_id") or [""])[0],
                     "question": (params.get("question") or [""])[0],
                     "options": (params.get("options") or [""])[0],
                     "is_anonymous": (params.get("is_anonymous") or [""])[0],
                     "allows_multiple_answers":
                         (params.get("allows_multiple_answers") or [""])[0]})
            return {"ok": True, "result": {"message_id": 1,
                                           "poll": {"id": "mockpoll123"}}}
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
