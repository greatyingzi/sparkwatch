#!/usr/bin/env python3
"""A known-good OpenAI-compatible SSE server, for verifying the decode benchmark.

Why this exists: the benchmark is the only feature in SparkWatch that sends work
*to* a machine, and the fleet's engine is usually busy serving real traffic. Pointing
the benchmark at this mock instead means the arithmetic (decode tok/s, TTFT, wave
aggregation) can be checked against a server whose answers are known in advance.

It streams `--tokens` content chunks with a fixed `--interval` between them, so a
correct client must report roughly `1 / interval` tokens per second per stream.

Usage:
    python3 Scripts/mock-openai-sse.py --port 18123 --tokens 200 --interval 0.02
    SparkWatch --bench http://127.0.0.1:18123 --concurrency 1,2,4 --max-tokens 200
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18123)
    parser.add_argument("--tokens", type=int, default=200, help="content chunks per request")
    parser.add_argument("--interval", type=float, default=0.02, help="seconds between chunks")
    parser.add_argument("--ttft", type=float, default=0.05, help="delay before the first chunk")
    arguments = parser.parse_args()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # keep the console quiet
            pass

        def do_GET(self):
            # The client probes /v1/models first on the real page; answer it so the
            # mock can also be used through the UI.
            if self.path.rstrip("/") in ("/v1/models", "/models"):
                body = json.dumps({
                    "object": "list",
                    "data": [{"id": "mock-50tps", "object": "model", "owned_by": "mock"}],
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_error(404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                request = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                request = {}
            # Warmup runs ask for fewer tokens; honour max_tokens so the count is
            # predictable either way.
            wanted = min(int(request.get("max_tokens", arguments.tokens)), arguments.tokens)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            # `Connection: close` matters: without it (and without chunked encoding or
            # a Content-Length) an HTTP/1.1 response body never ends, so a client that
            # reads to EOF waits out its timeout — measured, this cost a 360-second
            # hang per wave while the mock looked perfectly healthy.
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()

            def chunk(payload: dict) -> None:
                self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
                self.wfile.flush()

            started = time.time()
            time.sleep(arguments.ttft)
            chunk({"choices": [{"delta": {"role": "assistant"}, "index": 0}]})
            for index in range(wanted):
                chunk({"choices": [{"delta": {"content": f"tok{index} "}, "index": 0}]})
                time.sleep(arguments.interval)
            chunk({"choices": [{"delta": {}, "finish_reason": "stop", "index": 0}]})
            chunk({"choices": [], "usage": {
                "prompt_tokens": 40,
                "completion_tokens": wanted,
                "total_tokens": wanted + 40,
            }})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            print(
                f"  served {wanted} chunks in {time.time() - started:.2f}s "
                f"({wanted / max(time.time() - started, 1e-6):.1f} tok/s)",
                flush=True,
            )

    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    expected = arguments.tokens
    print(
        f"mock openai sse on http://127.0.0.1:{arguments.port} "
        f"tokens={expected} interval={arguments.interval}s → 预期 {1 / arguments.interval:.1f} tok/s/流"
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
