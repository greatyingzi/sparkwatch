#!/usr/bin/env python3
"""
全面 mock 接口测试：切换各种问题，看 SparkWatch 本来会显示什么。

跑法（mock 引擎要先起着）:
  python3 scripts/mock-tensorfold.py --port 18123 &
  python3 scripts/mock-scenarios.py            # 全部场景
  python3 scripts/mock-scenarios.py decoding engine_fatal   # 只跑指定场景

每个场景：切 mock → 用真实探针(--render，走真实 HTTP + 真实解析 + 真实显示函数)跑 3 拍
→ 解析渲染结果 → 与期望对比 → 打印表格 + PASS/FAIL 汇总。
"""
import json, os, re, subprocess, sys, time, urllib.request

MOCK = "http://127.0.0.1:18123"
PROBE = "./.build/debug/sparkwatch-probe"

# 场景 -> 期望（拿不准的写 None 表示只展示不断言）
EXPECT = {
    "idle":            dict(engine="TensorFold", bar_has_speed=False, rate="hidden",
                            banner=None, health="ok"),
    "decoding":        dict(engine="TensorFold", bar_has_speed=True,  rate="live", banner="decoding"),
    "decoding_slow":   dict(engine="TensorFold", bar_has_speed=True,  rate="live", banner="decoding"),
    "prefill":         dict(engine="TensorFold", bar_has_speed=False, banner="prefilling"),
    "prefill_and_dec": dict(engine="TensorFold", bar_has_speed=True,  banner="decoding"),
    "burst":           dict(engine="TensorFold", bar_has_speed=True,  rate="live"),
    "engine_fatal":    dict(engine="TensorFold", health="critical", alert=True,
                            bar_has_speed=False, names="引擎已崩"),
    "stalled":         dict(engine="TensorFold", health="warning", alert=False,
                            bar_has_speed=False),
    "metrics_lag":     dict(engine="TensorFold", bar_has_speed=False, rate="hidden"),   # 计数器每 3 拍才发布一次 → 不该硬编一个绿数字
    "no_metrics":      dict(bar_has_speed=False),                        # /metrics 501 → 没有计数器
    "metrics_garbage": dict(bar_has_speed=False),
    "health_missing":  dict(engine="TensorFold", bar_has_speed=True),     # /metrics 够用，速率照算
    "health_broken":   dict(engine="TensorFold", bar_has_speed=True),
    "all_500":         dict(engine="OpenAI 兼容", bar_has_speed=False),  # 500 也算"活着"（可达性判据），但没有计数器
    "timeout":         dict(probe_failed=True, must_return_within=20),
    "empty":           dict(engine="TensorFold", bar_has_speed=False),
    "vllm_style":      dict(engine="vLLM"),
    "llamacpp_style":  dict(engine="llama.cpp"),
    "ollama_style":    dict(engine="Ollama"),
}

ORDER = list(EXPECT.keys())


def ensure_mock(script_dir):
    """自己把 mock 起起来（先杀掉旧的）——改了 mock 脚本必须重启才生效，
    这个坑在本项目已经踩过两次，所以不靠人记得，交给脚本做。"""
    subprocess.run(["pkill", "-f", "mock-tensorfold.py"], capture_output=True)
    time.sleep(1)
    log = open("/tmp/mock.log", "a")
    subprocess.Popen([sys.executable, os.path.join(script_dir, "mock-tensorfold.py"), "--port", "18123"],
                     stdout=log, stderr=log, start_new_session=True)
    for _ in range(20):
        time.sleep(0.5)
        try:
            with urllib.request.urlopen(f"{MOCK}/__scenario", timeout=2) as r:
                json.load(r)
                return True
        except Exception:
            continue
    print("✗ mock 没起来（看 /tmp/mock.log）")
    return False


def set_scenario(name):
    with urllib.request.urlopen(f"{MOCK}/__scenario?name={name}", timeout=5) as r:
        return json.load(r)


def render(samples=3, interval=1.5, timeout=40):
    started = time.time()
    p = subprocess.run(
        [PROBE, "--render", MOCK, "--samples", str(samples), "--interval", str(interval)],
        capture_output=True, text=True, timeout=timeout,
    )
    out = p.stdout + p.stderr
    fields = {}
    failed = False
    for line in out.splitlines():
        m = re.match(r"RENDER (\w+)=(.*)", line)
        if m:
            fields[m.group(1)] = m.group(2)
        if "probe_failed=true" in line:
            failed = True
    return fields, failed, time.time() - started, p.returncode


def check(name, fields, failed, elapsed):
    exp = EXPECT[name]
    problems = []
    if exp.get("probe_failed"):
        if not failed:
            problems.append("期望探测失败但成功了")
    else:
        if failed:
            problems.append(f"探测失败: {fields.get('error', fields)}")
    if "engine" in exp and not failed:
        if fields.get("engine") != exp["engine"]:
            problems.append(f"引擎应为 {exp['engine']} 实为 {fields.get('engine')}")
    if "rate" in exp and not failed:
        if fields.get("rate") != exp["rate"]:
            problems.append(f"速率态应为 {exp['rate']} 实为 {fields.get('rate')}")
    if "bar_has_speed" in exp and not failed:
        has = "▶" in fields.get("bar", "")
        if has != exp["bar_has_speed"]:
            problems.append(f"菜单栏{'应' if exp['bar_has_speed'] else '不该'}有速度: {fields.get('bar')!r}")
    if exp.get("banner") and not failed:
        banner = fields.get("banner", "-")
        if not banner.startswith(exp["banner"]):
            problems.append(f"横幅应为 {exp['banner']} 实为 {banner!r}")
    if "health" in exp and not failed:
        if not fields.get("health", "").startswith(exp["health"]):
            problems.append(f"健康应为 {exp['health']} 实为 {fields.get('health')}")
    if "alert" in exp and not failed:
        is_alert = fields.get("health", "").split("/")[1] == "alert"
        if is_alert != exp["alert"]:
            problems.append(f"alert 应为 {exp['alert']} 实为 {is_alert}")
    if exp.get("names") and not failed:
        if exp["names"] not in fields.get("bar", "") + fields.get("health", ""):
            problems.append(f"界面上应出现 {exp['names']}")
    if "must_return_within" in exp:
        if elapsed > exp["must_return_within"]:
            problems.append(f"耗时 {elapsed:.1f}s 超过 {exp['must_return_within']}s（超时没生效？）")
    return problems


def main():
    names = sys.argv[1:] or ORDER
    if not ensure_mock(os.path.dirname(os.path.abspath(__file__))):
        sys.exit(2)
    rows, failures = [], 0
    for name in names:
        set_scenario(name)
        time.sleep(0.3)
        fields, failed, elapsed, rc = render()
        problems = check(name, fields, failed, elapsed)
        failures += bool(problems)
        rows.append((name, fields, failed, elapsed, problems))
        mark = "✗" if problems else "✓"
        bar = fields.get("bar", "-") if not failed else "(探测失败)"
        banner = fields.get("banner", "-")
        hp = fields.get("health", "-")
        print(f"{mark} {name:17s} {elapsed:5.1f}s engine={fields.get('engine','-'):11s} "
              f"rate={fields.get('rate','-'):8s} bar={bar!r:34s} banner={banner:22s} health={hp}")
        if failed:
            print(f"      probe_failed: {fields.get('error','')[:120]}")
        for p in problems:
            print(f"      ✗ {p}")
    print()
    print(f"=== {len(rows)} 个场景，{failures} 个不符合预期 ===")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
