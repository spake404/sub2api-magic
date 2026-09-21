#!/usr/bin/env python3
"""Local OpenAI-compatible mock for walking through the relay path."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import sys
import time

HOST = os.environ.get("MOCK_OPENAI_HOST", "127.0.0.1")
PORT = int(os.environ.get("MOCK_OPENAI_PORT", "18080"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), fmt % args))

    def _json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.endswith("/models") or path == "/models":
            self._json(200, {
                "object": "list",
                "data": [{"id": "gpt-4o-mini", "object": "model", "owned_by": "local-mock"}],
            })
            return
        self._json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            req = {}
        model = req.get("model") or "gpt-4o-mini"
        if path.endswith("/responses") or path == "/responses":
            self._json(404, {
                "error": {
                    "message": "Unknown request URL. This mock only serves /v1/chat/completions.",
                    "type": "invalid_request_error",
                }
            })
            return
        if "chat/completions" in path:
            self._json(200, {
                "id": "chatcmpl-local-mock",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": "pong from local mock"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 8, "completion_tokens": 6, "total_tokens": 14},
            })
            return
        self._json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("mock-openai listening on http://%s:%s" % (HOST, PORT), flush=True)
    server.serve_forever()