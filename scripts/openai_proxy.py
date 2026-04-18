#!/usr/bin/env python3
"""OpenAI-compatible proxy for a local MLX server.

Endpoints:
    POST /v1/chat/completions  -> {MLX_BASE}/chat/completions   (pass-through, streaming-aware)
    POST /v1/responses         -> translates to /chat/completions then re-shapes as Responses API
    GET  /v1/models            -> {MLX_BASE}/models  (re-shaped to OpenAI list)

The Responses API shim supports both streaming (SSE) and non-streaming requests,
so tools like the OpenAI Codex CLI that call /v1/responses work transparently.
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_MLX_BASE = "http://127.0.0.1:5001"
DEFAULT_MODEL_DIR = "models/mlx-community__Qwen3.5-35B-A3B-4bit"
PROXY_TIMEOUT = 600  # seconds


def make_handler(mlx_base: str, default_model: str) -> type[BaseHTTPRequestHandler]:
    class ProxyHandler(BaseHTTPRequestHandler):
        # ── /v1/chat/completions — streaming-aware pass-through ───────────────

        def _proxy_chat(self, payload: dict) -> None:
            if not payload.get("model"):
                payload["model"] = default_model
            data = json.dumps(payload).encode()
            req = urllib.request.Request(
                mlx_base + "/chat/completions",
                data=data,
                headers={"Content-Type": "application/json"},
            )
            is_stream = bool(payload.get("stream"))
            try:
                with urllib.request.urlopen(req, timeout=PROXY_TIMEOUT) as r:
                    self.send_response(r.getcode())
                    for k, v in r.getheaders():
                        if k.lower() in {
                            "transfer-encoding",
                            "content-length",
                            "connection",
                        }:
                            continue
                        self.send_header(k, v)
                    if is_stream:
                        self.send_header("Transfer-Encoding", "chunked")
                        self.end_headers()
                        while True:
                            chunk = r.read(4096)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            self.wfile.flush()
                    else:
                        body = r.read()
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
            except urllib.error.HTTPError as e:
                try:
                    body = e.read()
                except (ConnectionResetError, OSError):
                    body = json.dumps(
                        {"error": {"message": f"upstream {e.code}"}}
                    ).encode()
                self._send_json(e.code, body, list(e.headers.items()))
            except urllib.error.URLError as e:
                self._send_json(
                    502, json.dumps({"error": {"message": str(e)}}).encode()
                )

        # ── /v1/responses — Responses API shim ───────────────────────────────

        @staticmethod
        def _responses_to_chat(r_req: dict) -> dict:
            """Translate Responses API request -> Chat Completions request."""
            messages: list[dict] = []
            if r_req.get("instructions"):
                messages.append({"role": "system", "content": r_req["instructions"]})
            inp = r_req.get("input", "")
            if isinstance(inp, str):
                messages.append({"role": "user", "content": inp})
            elif isinstance(inp, list):
                for item in inp:
                    if isinstance(item, str):
                        messages.append({"role": "user", "content": item})
                    elif isinstance(item, dict):
                        role = item.get("role", "user")
                        content = item.get("content", "")
                        if isinstance(content, list):
                            parts = []
                            for p in content:
                                if isinstance(p, dict):
                                    t = (
                                        p.get("text")
                                        or p.get("input_text")
                                        or p.get("output_text")
                                        or ""
                                    )
                                elif isinstance(p, str):
                                    t = p
                                else:
                                    t = ""
                                if t:
                                    parts.append(t)
                            content = "".join(parts)
                        messages.append({"role": role, "content": content})
            chat: dict = {
                "model": r_req.get("model") or default_model,
                "messages": messages,
            }
            if r_req.get("stream"):
                chat["stream"] = True
            if "max_output_tokens" in r_req:
                chat["max_tokens"] = r_req["max_output_tokens"]
            else:
                # Qwen3.5 uses reasoning tokens before writing content;
                # without a budget the model exhausts a small cap on thinking alone.
                chat.setdefault("max_tokens", 4096)
            for k in ("temperature", "top_p"):
                if k in r_req:
                    chat[k] = r_req[k]
            return chat

        @staticmethod
        def _chat_to_responses(
            chat_resp: dict, model: str, response_id: str, item_id: str
        ) -> dict:
            """Translate Chat Completions response -> Responses API response."""
            choice = (chat_resp.get("choices") or [{}])[0]
            msg = choice.get("message", {})
            # Qwen3.5 stores chain-of-thought in "reasoning"; "content" holds the final answer.
            # Fall back to reasoning when content is empty (e.g. tokens exhausted mid-think).
            text = msg.get("content") or msg.get("reasoning") or ""
            usage = chat_resp.get("usage", {})
            return {
                "id": response_id,
                "object": "response",
                "created_at": chat_resp.get("created", int(time.time())),
                "status": "completed",
                "model": chat_resp.get("model", model),
                "output": [
                    {
                        "type": "message",
                        "id": item_id,
                        "status": "completed",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": text}],
                    }
                ],
                "usage": {
                    "input_tokens": usage.get("prompt_tokens", 0),
                    "output_tokens": usage.get("completion_tokens", 0),
                    "total_tokens": usage.get("total_tokens", 0),
                },
            }

        def _handle_responses(self, r_req: dict) -> None:
            response_id = "resp_" + uuid.uuid4().hex[:20]
            item_id = "msg_" + uuid.uuid4().hex[:20]
            model = r_req.get("model") or default_model
            chat_req = self._responses_to_chat(r_req)
            data = json.dumps(chat_req).encode()
            req = urllib.request.Request(
                mlx_base + "/chat/completions",
                data=data,
                headers={"Content-Type": "application/json"},
            )

            if not chat_req.get("stream"):
                # ── non-streaming ────────────────────────────────────────────
                try:
                    with urllib.request.urlopen(req, timeout=PROXY_TIMEOUT) as r:
                        chat_resp = json.load(r)
                except urllib.error.HTTPError as e:
                    self._send_json(
                        e.code,
                        json.dumps(
                            {"error": {"message": f"upstream {e.code}"}}
                        ).encode(),
                    )
                    return
                except urllib.error.URLError as e:
                    self._send_json(
                        502, json.dumps({"error": {"message": str(e)}}).encode()
                    )
                    return
                body = json.dumps(
                    self._chat_to_responses(chat_resp, model, response_id, item_id)
                ).encode()
                self._send_json(200, body)
            else:
                # ── streaming: translate chat SSE -> Responses API SSE ────────
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("X-Accel-Buffering", "no")
                self.end_headers()

                seq = 0

                def sse(name: str, payload: dict) -> None:
                    nonlocal seq
                    payload["sequence_number"] = seq
                    seq += 1
                    self.wfile.write(
                        f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode()
                    )
                    self.wfile.flush()

                sse(
                    "response.created",
                    {
                        "type": "response.created",
                        "response": {
                            "id": response_id,
                            "object": "response",
                            "created_at": int(time.time()),
                            "status": "in_progress",
                            "model": model,
                            "output": [],
                        },
                    },
                )
                sse(
                    "response.output_item.added",
                    {
                        "type": "response.output_item.added",
                        "output_index": 0,
                        "item": {
                            "id": item_id,
                            "type": "message",
                            "status": "in_progress",
                            "role": "assistant",
                            "content": [],
                        },
                    },
                )
                sse(
                    "response.content_part.added",
                    {
                        "type": "response.content_part.added",
                        "item_id": item_id,
                        "output_index": 0,
                        "content_index": 0,
                        "part": {"type": "output_text", "text": ""},
                    },
                )

                accumulated: list[str] = []
                try:
                    with urllib.request.urlopen(req, timeout=PROXY_TIMEOUT) as r:
                        while True:
                            line = r.readline()
                            if not line:
                                break
                            line = line.strip()
                            if not line or not line.startswith(b"data: "):
                                continue
                            chunk_data = line[6:]
                            if chunk_data == b"[DONE]":
                                break
                            try:
                                chunk = json.loads(chunk_data)
                            except json.JSONDecodeError:
                                continue
                            choices = chunk.get("choices") or []
                            if not choices:
                                continue
                            delta = choices[0].get("delta", {})
                            # Prefer content; fall back to reasoning for Qwen3.5 thinking models
                            delta_text = delta.get("content") or delta.get("reasoning")
                            if delta_text:
                                accumulated.append(delta_text)
                                sse(
                                    "response.output_text.delta",
                                    {
                                        "type": "response.output_text.delta",
                                        "item_id": item_id,
                                        "output_index": 0,
                                        "content_index": 0,
                                        "delta": delta_text,
                                    },
                                )
                except (urllib.error.URLError, OSError):
                    pass

                full_text = "".join(accumulated)
                completed_item = {
                    "id": item_id,
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": full_text}],
                }
                sse(
                    "response.output_text.done",
                    {
                        "type": "response.output_text.done",
                        "item_id": item_id,
                        "output_index": 0,
                        "content_index": 0,
                        "text": full_text,
                    },
                )
                sse(
                    "response.content_part.done",
                    {
                        "type": "response.content_part.done",
                        "item_id": item_id,
                        "output_index": 0,
                        "content_index": 0,
                        "part": {"type": "output_text", "text": full_text},
                    },
                )
                sse(
                    "response.output_item.done",
                    {
                        "type": "response.output_item.done",
                        "output_index": 0,
                        "item": completed_item,
                    },
                )
                sse(
                    "response.completed",
                    {
                        "type": "response.completed",
                        "response": {
                            "id": response_id,
                            "object": "response",
                            "status": "completed",
                            "created_at": int(time.time()),
                            "model": model,
                            "output": [completed_item],
                        },
                    },
                )

        # ── /v1/models ────────────────────────────────────────────────────────

        def _list_models(self) -> None:
            req = urllib.request.Request(mlx_base + "/models")
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    raw = json.load(r)
            except (
                urllib.error.HTTPError,
                urllib.error.URLError,
                json.JSONDecodeError,
            ):
                raw = {"data": []}

            if isinstance(raw, dict) and isinstance(raw.get("data"), list):
                items = raw["data"]
            elif isinstance(raw, list):
                items = raw
            else:
                items = []

            out_data = []
            for item in items:
                name = (
                    item.get("id")
                    if isinstance(item, dict)
                    else (item if isinstance(item, str) else None)
                )
                if name:
                    out_data.append({"id": name, "object": "model"})
            if not out_data:
                out_data.append({"id": default_model, "object": "model"})

            self._send_json(
                200, json.dumps({"object": "list", "data": out_data}).encode()
            )

        # ── helpers ───────────────────────────────────────────────────────────

        def _send_json(
            self, code: int, body: bytes, extra_headers: list | None = None
        ) -> None:
            self.send_response(code)
            has_ct = False
            for k, v in extra_headers or []:
                if k.lower() in {"transfer-encoding", "content-length"}:
                    continue
                if k.lower() == "content-type":
                    has_ct = True
                self.send_header(k, v)
            if not has_ct:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        # ── routing ───────────────────────────────────────────────────────────

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b""
            try:
                payload = json.loads(raw.decode() or "{}")
            except json.JSONDecodeError:
                payload = {}
            if self.path == "/v1/chat/completions":
                return self._proxy_chat(payload)
            if self.path == "/v1/responses":
                return self._handle_responses(payload)
            self.send_error(404, "Not Found")

        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/v1/models":
                return self._list_models()
            self.send_error(404, "Not Found")

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            return

    return ProxyHandler


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5101)
    ap.add_argument("--mlx-base", default=DEFAULT_MLX_BASE)
    ap.add_argument("--default-model", default=DEFAULT_MODEL_DIR)
    args = ap.parse_args()

    handler_cls = make_handler(args.mlx_base.rstrip("/"), args.default_model)
    server = HTTPServer((args.host, args.port), handler_cls)
    print(
        f"OpenAI-compat proxy listening on http://{args.host}:{args.port} "
        f"-> {args.mlx_base} (default model: {args.default_model})",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
