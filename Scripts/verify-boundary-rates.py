#!/usr/bin/env python3
"""边界发布计数器下的速率判别力检查（无需任何真机权限）。

它做的事，按顺序：

1. 起 `Scripts/mock-tensorfold.py`，切到 `new_build_decoding` —— 这条轨迹照抄客户机
   2026-10-30 的真实行为：`*_total` 在"请求周期"内冻结、周期末一次性跳 `boundary_tokens`，
   进度只体现在 `generation_tokens_running` gauge 上，`/health` 只给 `live.*` 实时速率。
2. 用 `sparkwatch-probe --render` 跑同一套采样管线，断言"修好之后应该看到什么"：
   在飞期间的速率贴着引擎的 25 tok/s、**没有任何一次采样超过 60 tok/s**、prefill 出数。
3. 把修复**故意撤回**（`InferenceRate.swift` 里把 health / gauge 两个分支短路成 false，
   等于回到"只认计数器差值"的旧行为），重新编译，同一组断言必须**变红**。
4. 还原源码、重新编译，断言再次变绿。

第 3 步是重点：一个测试如果对 bug 版也全绿，它证明不了任何东西。
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 18124
MOCK = os.path.join(ROOT, "Scripts", "mock-tensorfold.py")
PROBE = os.path.join(ROOT, ".build", "debug", "sparkwatch-probe")
TARGET = os.path.join(ROOT, "Sources", "SparkWatchCore", "InferenceRate.swift")

LIVE_RATE = 25.0


def build() -> None:
    subprocess.run(["swift", "build"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)


def set_scenario(name: str) -> None:
    urllib.request.urlopen(f"http://127.0.0.1:{PORT}/__scenario?name={name}", timeout=5).read()


def render(scenario: str, samples: int = 12, interval: float = 0.6) -> list[dict]:
    set_scenario(scenario)
    out = subprocess.run(
        [PROBE, "--render", f"http://127.0.0.1:{PORT}", "--samples", str(samples),
         "--interval", str(interval)],
        capture_output=True, text=True, timeout=300,
    ).stdout
    rows = []
    for line in out.splitlines():
        if not line.startswith("SAMPLE"):
            continue
        row = {}
        for key, value in re.findall(r"(\w+)=(\S+)", line):
            row[key] = value
        rows.append(row)
    return rows


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def check_fixed(rows: list[dict], prefill_rows: list[dict]) -> list[str]:
    """修好之后必须成立的事实。返回违规列表（空 = 通过）。"""
    problems = []
    busy = [r for r in rows if r.get("busy") not in (None, "0", "0.0")]
    if len(busy) < 2:
        problems.append(f"在飞采样只有 {len(busy)} 个，mock 轨迹没跑起来")
    health = [r for r in busy if r.get("src") == "health"]
    if len(health) < 2:
        problems.append(f"贴引擎实时值的采样只有 {len(health)} 个（期望 >= 2，src=health）")
    for r in health:
        tps = as_float(r.get("tps"))
        if tps is None:
            problems.append("src=health 却给不出速率")
        elif not (LIVE_RATE * 0.6 <= tps <= LIVE_RATE * 1.6):
            problems.append(f"速率 {tps} 偏离引擎实时值 {LIVE_RATE}")
    spikes = [(r.get("tps"), r.get("src")) for r in rows
              if (as_float(r.get("tps")) or 0) > 60]
    if spikes:
        problems.append(f"出现假峰（> 60 tok/s）：{spikes[:3]}")
    if not any((as_float(r.get("prefill")) or 0) > 100 for r in prefill_rows):
        problems.append("prefill 扫描里没有出数（期望引擎实时 900 tok/s）")
    return problems


def mutate_to_old_behaviour() -> None:
    """把 health / gauge 两个 live 源短路掉 == 回到修复前只认计数器差值。"""
    original = open(TARGET).read()
    shutil.copy2(TARGET, TARGET + ".bak")
    mutated = original.replace(
        "        if let nativeRate, nativeBusy, nativeRate > 0.5, nativeRate.isFinite {",
        "        if false, let nativeRate, nativeBusy, nativeRate > 0.5, nativeRate.isFinite {",
    ).replace(
        "        if let gaugeRate, gaugeRate > 0.5, gaugeRate.isFinite {",
        "        if false, let gaugeRate, gaugeRate > 0.5, gaugeRate.isFinite {",
    )
    if mutated == original:
        raise SystemExit("mutate 失败：没匹配到 live 分支")
    open(TARGET, "w").write(mutated)


def restore() -> None:
    if os.path.exists(TARGET + ".bak"):
        shutil.move(TARGET + ".bak", TARGET)


def main() -> int:
    mock = subprocess.Popen([sys.executable, MOCK, "--port", str(PORT)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2.0)
        build()

        print("== 1. 修复版：边界发布的计数器 + live 速率 ==")
        rows = render("new_build_decoding")
        pre = render("new_build_prefill", samples=4, interval=0.6)
        for r in rows:
            print(f"   src={r.get('src'):<9} tps={r.get('tps'):>6} live={r.get('live'):>5} "
                  f"gauge={r.get('gauge'):>4} busy={r.get('busy')}")
        fixed_problems = check_fixed(rows, pre)
        print("   结果:", "PASS" if not fixed_problems else f"FAIL {fixed_problems}")

        print("\n== 2. 判别力：把 live 源短路，退回到只认计数器差值 ==")
        mutate_to_old_behaviour()
        build()
        bug_rows = render("new_build_decoding")
        bug_pre = render("new_build_prefill", samples=4, interval=0.6)
        for r in bug_rows:
            print(f"   src={r.get('src'):<9} tps={r.get('tps'):>6} live={r.get('live'):>5} "
                  f"gauge={r.get('gauge'):>4} busy={r.get('busy')}")
        bug_problems = check_fixed(bug_rows, bug_pre)
        print("   结果:", "FAIL（正确——它复现了 bug）" if bug_problems else "PASS（判别力不足！）")

        print("\n== 3. 还原并复验 ==")
        restore()
        build()
        again = check_fixed(render("new_build_decoding"), render("new_build_prefill", samples=4))
        print("   结果:", "PASS" if not again else f"FAIL {again}")

        ok = not fixed_problems and bool(bug_problems) and not again
        print("\n" + ("✅ 判别力成立：修复版绿、bug 版红、还原后再绿" if ok else "❌ 检查未通过"))
        return 0 if ok else 1
    finally:
        mock.send_signal(signal.SIGTERM)
        try:
            mock.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock.kill()
        restore()


if __name__ == "__main__":
    sys.exit(main())
