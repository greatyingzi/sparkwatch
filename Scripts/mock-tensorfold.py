#!/usr/bin/env python3
"""
假的 TensorFold 引擎，用来「切换各种问题」看 SparkWatch 怎么显示。

真机接口（实测抄下来的形状）:
  GET /v1/models  -> {"data":[{"id":"<name>"}]}
  GET /health     -> 实时态 JSON（completion_tokens_total 等）
  GET /metrics    -> Prometheus 文本（tensorfold: 前缀，慢速重发布是它的真实行为）

场景用 `GET /__scenario?name=<x>` 切换，`GET /__scenario` 查看当前场景，
`GET /__state` 看这个 mock 内部的时间轴（第几拍、计数器走到哪）。

用法:
  ./scripts/mock-tensorfold.py --port 18123 &
  curl -s 'http://127.0.0.1:18123/__scenario?name=decoding'
  ./build/debug/sparkwatch-probe --render http://127.0.0.1:18123 --samples 3 --interval 1.5
"""
import argparse, json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

T0 = time.time()
LOCK = threading.Lock()
STATE = {"scenario": "idle", "tick": 0}

# 每个场景: (每拍新增 completion tokens, 每拍新增 prompt tokens, prefilling, decoding, fatal, stalled, metrics_lag_ticks)
SCENARIOS = {
    # ---- 正常态 ----
    "idle":            dict(comp_step=0,    prompt_step=0,     pf=0, dec=0, fatal=0, stalled=0, lag=0),
    "decoding":        dict(comp_step=40,   prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=0),
    "decoding_slow":   dict(comp_step=1,    prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=0),
    "prefill":         dict(comp_step=0,    prompt_step=6000,  pf=1, dec=0, fatal=0, stalled=0, lag=0),
    "prefill_and_dec": dict(comp_step=20,   prompt_step=6000,  pf=1, dec=1, fatal=0, stalled=0, lag=0),
    "burst":           dict(comp_step=2000, prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=0),
    # ---- 引擎自报的坏状态 ----
    "engine_fatal":    dict(comp_step=0,    prompt_step=0,     pf=0, dec=0, fatal=1, stalled=0, lag=0),
    "stalled":         dict(comp_step=0,    prompt_step=0,     pf=0, dec=1, fatal=0, stalled=2, lag=0),
    # ---- 接口层面各种坏法 ----
    # 慢速重发布：唯一计数源就是 /metrics，而它每 3 拍才发布一次 → 两次发布之间数值不动
    # → 差值法算不出速率。这正是真机上"速度算不出来"的经典成因，必须能复现。
    "metrics_lag":     dict(comp_step=40,   prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=9999, health_status=404),
    "no_metrics":      dict(comp_step=40,   prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=0, metrics_status=501),
    "metrics_garbage": dict(comp_step=40,   prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=0, metrics_status=200, metrics_body="<html>not metrics</html>"),
    "health_missing":  dict(comp_step=40,   prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=0, health_status=404),
    "health_broken":   dict(comp_step=40,   prompt_step=0,     pf=0, dec=1, fatal=0, stalled=0, lag=0, health_status=200, health_body="{not json"),
    "all_500":         dict(comp_step=0,    prompt_step=0,     pf=0, dec=0, fatal=0, stalled=0, lag=0, all_status=500),
    "timeout":         dict(comp_step=0,    prompt_step=0,     pf=0, dec=0, fatal=0, stalled=0, lag=0, sleep=30),
    "empty":           dict(comp_step=0,    prompt_step=0,     pf=0, dec=0, fatal=0, stalled=0, lag=0, empty_models=True),
    # ---- 当前 build（2026-10+）的真实形状 ----
    # /health 只给 live 实时态（没有任何计数器）；/metrics 的 *_total 只在"请求结束"那一拍
    # 发布，中间靠 generation_tokens_running 这个 gauge 反映进度。客户的 TensorFold 就是
    # 这样：11.2 秒的请求里计数器一次没动，结束时 +400。旧算法在这条轨迹上会读 0，
    # 然后在边界拍冒充 ~200 tok/s —— 这两个数字都必须能在 mock 上复现。
    "new_build_decoding": dict(comp_step=0, prompt_step=0, pf=0, dec=1, fatal=0, stalled=0, lag=0,
                               shape="new_live", live_dec=25.0, live_pre=0.0,
                               gauge_step=25, boundary_every=4, boundary_tokens=300),
    "new_build_prefill":  dict(comp_step=0, prompt_step=0, pf=1, dec=0, fatal=0, stalled=0, lag=0,
                               shape="new_live", live_dec=0.0, live_pre=900.0,
                               gauge_step=0, boundary_every=4, boundary_tokens=0),
    "new_build_idle":     dict(comp_step=0, prompt_step=0, pf=0, dec=0, fatal=0, stalled=0, lag=0,
                               shape="new_live", live_dec=0.0, live_pre=0.0,
                               gauge_step=0, boundary_every=4, boundary_tokens=0),
    # ---- 别的引擎形状（防止只认 TensorFold）----
    "vllm_style":      dict(kind="vllm"),
    "llamacpp_style":  dict(kind="llamacpp"),
    "ollama_style":    dict(kind="ollama"),
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):        # 安静点，编排脚本自己打印
        pass

    def _send(self, code, body, ctype="application/json"):
        raw = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path == "/__scenario":
            with LOCK:
                if "name" in q:
                    name = q["name"][0]
                    if name not in SCENARIOS:
                        self._send(400, json.dumps({"error": f"未知场景 {name}", "known": sorted(SCENARIOS)}))
                        return
                    STATE["scenario"] = name
                    STATE["tick"] = 0
                self._send(200, json.dumps({"scenario": STATE["scenario"], "tick": STATE["tick"]}))
            return

        if u.path == "/__state":
            s = self.step_spec()
            with LOCK:
                self._send(200, json.dumps({"scenario": STATE["scenario"], "tick": STATE["tick"], "spec": s}))
            return

        # 时间轴由「被读的次数」驱动：/health 与 /metrics 都算一拍，否则只读 /metrics 的
        # 客户端永远看不到计数器增长（第一版就这样，害得 health_missing 场景假失败）。
        if u.path in ("/health", "/metrics"):
            self.advance()

        spec = self.step_spec()

        if spec.get("sleep"):
            time.sleep(spec["sleep"])          # 模拟挂死（客户端必须自己超时）

        if spec.get("all_status", 200) != 200:
            self._send(spec["all_status"], json.dumps({"error": "boom"}))
            return

        if u.path == "/v1/models":
            if spec.get("kind") == "ollama":
                self._send(404, '{"error":"not found"}')
                return
            name = "mock-model-32B"
            if spec.get("empty_models"):
                self._send(200, '{"object":"list","data":[]}')
                return
            self._send(200, json.dumps({"object": "list", "data": [{"id": name, "object": "model"}]}))
            return

        if u.path == "/api/ps" and spec.get("kind") == "ollama":
            self._send(200, json.dumps({"models": [{
                "name": "mock:7b", "model": "mock:7b", "size_vram": 5_000_000_000,
                "details": {"quantization_level": "Q4_K_M", "parameter_size": "7.6B", "family": "llama"}}]}))
            return

        if u.path == "/health":
            code = spec.get("health_status", 200)
            if code != 200:
                self._send(code, json.dumps({"error": "no health"}))
                return
            body = spec.get("health_body")
            self._send(200, body if body else json.dumps(self.health()))
            return

        if u.path == "/metrics":
            code = spec.get("metrics_status", 200)
            if code != 200:
                self._send(code, "no metrics", "text/plain")
                return
            body = spec.get("metrics_body")
            if body:
                self._send(200, body, "text/plain")
                return
            if spec.get("kind"):
                self._send(200, self.other_engine_metrics(spec["kind"]), "text/plain")
                return
            self._send(200, self.metrics(), "text/plain")
            return

        self._send(404, json.dumps({"error": "not found", "path": u.path}))

    # ---- 内部 ----

    def step_spec(self):
        with LOCK:
            base = dict(SCENARIOS[STATE["scenario"]])
            base["_scenario"] = STATE["scenario"]
            return base

    def advance(self):
        """每个 /health 或 /metrics 请求算一拍 —— mock 的时间轴由被读的次数驱动。"""
        with LOCK:
            STATE["tick"] += 1
            return STATE["tick"]

    def totals(self, lag=0):
        with LOCK:
            spec = dict(SCENARIOS[STATE["scenario"]])
            ticks = max(0, STATE["tick"] - lag)
        return (spec["comp_step"] * ticks,
                spec["prompt_step"] * ticks,
                spec)

    def health(self):
        comp, prompt, spec = self.totals()
        if spec.get("shape") == "new_live":
            # 与客户机逐键一致的形状（没有任何计数器）。
            return {
                "status": "ok", "model": "dgx-spark", "model_ids": ["dgx-spark"],
                "max_batch_size": 8, "warming": False, "memory": {},
                "live": {"connections": spec["pf"] + spec["dec"], "waiting": 0,
                         "decode_tokens_per_second": spec.get("live_dec", 0.0),
                         "prefill_tokens_per_second": spec.get("live_pre", 0.0)},
            }
        return {
            "ok": True, "backend": "tensorfold", "busy": bool(spec["pf"] or spec["dec"]),
            "requests_running": spec["pf"] + spec["dec"], "requests_total": 42,
            "prompt_tokens_total": 1_000_000 + prompt,
            "completion_tokens_total": 50_000 + comp,
            "cached_tokens_total": 900_000,
            "prefill_seconds_total": 100.0 + (prompt / 6000.0),
            "decode_seconds_total": 500.0 + (comp / 40.0),
            "drafted_total": 1000, "accepted_total": 700,
            "streams": {"decoding": spec["dec"], "prefilling": spec["pf"], "max": 4,
                        "filling": 0, "paused": 0},
            "oldest_s": 3.0 if (spec["pf"] or spec["dec"]) else 0.0,
            "idle_s": 0.0 if (spec["pf"] or spec["dec"]) else 5.0,
            "context_length": 1048576,
        }

    # 慢速重发布：/metrics 只在每 lag 拍"发布"一次（真机行为）。读起来是：两次发布之间数值不动
    # → 差值法算不出速率；这也正是"速度算不出来"的经典成因，必须能复现。
    def metrics(self):
        with LOCK:
            spec = dict(SCENARIOS[STATE["scenario"]])
            tick = STATE["tick"]
        if spec.get("shape") == "new_live":
            # 一个"请求周期"= boundary_every 拍：周期内 *_total 冻结、gauge 线性增长；
            # 周期末 *_total 一次性 +boundary_tokens、gauge 归零 —— 真机边界发布的形状。
            every = max(1, int(spec.get("boundary_every", 4)))
            inside = tick % every
            boundaries = tick // every
            tokens = int(spec.get("boundary_tokens", 0))
            gauge = int(spec.get("gauge_step", 0)) * inside
            decode_sum = 500.0 + boundaries * (tokens / 37.0 if tokens else 0.0)
            lines = [
                "tensorfold:num_requests_running %d" % (spec["pf"] + spec["dec"]),
                "tensorfold:requests_waiting 0",
                "tensorfold:generation_tokens_running %d" % gauge,
                "tensorfold:generation_tokens_total %d" % (50000 + tokens * boundaries),
                "tensorfold:prompt_tokens_total %d" % (1000000 + 100 * boundaries),
                "tensorfold:request_decode_time_seconds_sum %.3f" % decode_sum,
                "tensorfold:request_decode_time_seconds_count %d" % max(1, boundaries),
                'tensorfold:kv_cache_usage_ratio{pool="0"} 0.0839',
            ]
            return "\n".join(lines) + "\n"
        with LOCK:
            lag = spec.get("lag", 0)
            if lag:
                # 第一次读就发布一次，之后每 lag 拍才发布新值 —— 所以 lag 很大时
                # 计数器在整段观测里真的不动（第一版没有"首读发布"，published 一直是
                # None → 回落到实时值 → 每次都涨 → 场景永远测不出"算不出速率"）。
                if STATE.get("published") is None \
                        or tick - STATE.get("published_tick", -10**9) >= lag:
                    STATE["published_tick"] = tick
                    STATE["published"] = (spec["comp_step"] * tick, spec["prompt_step"] * tick)
            published = STATE.get("published")
        if lag and published:
            comp, prompt = published
        else:
            comp, prompt = spec["comp_step"] * tick, spec["prompt_step"] * tick
        lines = [
            f"tensorfold:requests_running {spec['pf'] + spec['dec']}",
            f"tensorfold:requests_waiting 0",
            f"tensorfold:prompt_tokens_total {1_000_000 + prompt}",
            f"tensorfold:generation_tokens_total {50_000 + comp}",
            "tensorfold:kv_cache_usage_ratio{pool=\"0\"} 0.0839",
            "tensorfold:mtp_drafted_total 1000",
            "tensorfold:mtp_accepted_total 700",
            f"tensorfold_health:completion_tokens_total {50_000 + comp}",
            f"tensorfold_health:prompt_tokens_total {1_000_000 + prompt}",
            f"tensorfold_health:cached_tokens_total 900_000",
            f"tensorfold_health:decode_seconds_total {500.0 + comp / 40.0}",
            f"tensorfold_health:prefill_seconds_total {100.0 + prompt / 6000.0}",
            f"tensorfold_health:requests_total 42",
            "tensorfold_health:context_length 1048576",
            f"tensorfold_health:streams{{state=\"decoding\"}} {spec['dec']}",
            f"tensorfold_health:streams{{state=\"filling\"}} 0",
            "tensorfold_health:streams_max 4",
        ]
        for k, v in (("engine_fatal", spec["fatal"]), ("requests_stalled", spec["stalled"])):
            lines.append(f"tensorfold_{k} {v}")
        return "\n".join(lines) + "\n"

    def other_engine_metrics(self, kind):
        if kind == "vllm":
            return ("vllm:generation_tokens_total 500\nvllm:prompt_tokens_total 1000\n"
                    "vllm:num_requests_running 1\nvllm:num_requests_waiting 0\n"
                    "vllm:request_success_total 7\nvllm:gpu_cache_usage_perc 0.2\n")
        if kind == "llamacpp":
            return ("llamacpp:tokens_predicted_total 500\nllamacpp:prompt_tokens_total 1000\n"
                    "llamacpp:requests_processing 1\nllamacpp:requests_deferred 0\n"
                    "llamacpp:predicted_tokens_seconds 42\n")
        return ""


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18123)
    ap.add_argument("--scenario", default="idle")
    a = ap.parse_args()
    STATE["scenario"] = a.scenario
    print(f"mock tensorfold on :{a.port} scenario={a.scenario}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
