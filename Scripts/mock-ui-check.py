#!/usr/bin/env python3
"""
状态栏 UI 验证：mock 数据变化时，菜单栏真正画成了什么样。

为什么要这个：`mock-scenarios.py` 验的是**文本**（Core 函数算出来的），
但主人关心的是**状态栏那个 NSStatusItem 自己**——色点颜色对不对、数字有没有换、
切状态时有没有刷新。文本对了不等于屏幕上对了。

做法（顺序照 `macos-menubar-ui-quality` 的规矩）：
  1. app 自己 dump（`SPARKWATCH_DEBUG`）——它写的就是 `statusItem.button.attributedTitle`
     的同一个字符串，是数值的权威来源（OCR 不验数字）。
  2. `screencapture -R` 抓菜单栏右侧那块 → 像素量测：每个色点的实际色相 + OCR 读结构。
  3. 两者对照：dump 说的 vs 屏幕上真画的。

用法:
  python3 scripts/mock-ui-check.py                 # 全部场景
  python3 scripts/mock-ui-check.py idle decoding engine_fatal
"""
import json, os, re, subprocess, sys, time, urllib.request
from pathlib import Path

MOCK = "http://127.0.0.1:18123"
APP = "/Applications/SparkWatch.app/Contents/MacOS/SparkWatch"
DUMP = "/tmp/sw-ui-dump.log"
SHOT = Path("/tmp/sw-menubar.png")
CROP = Path("/tmp/sw-menubar-crop.png")

# 场景 -> 期望(名字, 菜单栏里必须出现/不许出现的东西)
EXPECT = {
    "idle":            dict(absent=["⇡", "⚠", "✕"], present=["●"], no_fresh_rate=True),
    "decoding":        dict(present=["●", "▶", "/s"], absent=["⚠", "✕"]),
    "decoding_slow":   dict(present=["●", "▶", "/s"]),
    "prefill":         dict(present=["●", "⇡"], absent=["▶", "⚠"]),
    "prefill_and_dec": dict(present=["●", "▶", "/s"], absent=["⇡"]),
    "engine_fatal":    dict(present=["⚠"], absent=["▶", "/s"]),
    "stalled":         dict(present=["●"], absent=["⚠", "✕", "/s"]),
    "metrics_lag":     dict(present=["●"], no_fresh_rate=True, absent=["⚠"], settle=30),
    "no_metrics":      dict(present=["●"], no_fresh_rate=True, absent=["⚠"]),
    "all_500":         dict(present=["●"], no_fresh_rate=True),
    "vllm_style":      dict(present=["●"]),
    "ollama_style":    dict(present=["●"]),
}


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


def strip_power(text):
    """只有"会自己变的量"允许 AX 与 dump 不一致：
    - 功耗 ≈NNW 来自真硬件，每拍都在变；
    - 读数的年龄 ·NNs/·Nm 每拍 +1，两次读之间必然会跳一下。
    其余（色点、速率、名字、原因词）必须逐字一致。"""
    text = re.sub(r"\s*≈\d+W", "", text or "")
    return re.sub(r"·\d+s|·\d+m", "·AGED", text)


def set_scenario(name):
    with urllib.request.urlopen(f"{MOCK}/__scenario?name={name}", timeout=5) as r:
        return json.load(r)


def dump_tail(n=4):
    """整份 dump 里最后一条"状态栏那行"（格式：ISO 时间戳 \\t 状态栏文本）。
    早先只读最后 4 行 → 那行在块顶，永远读不到（'?' 假失败）。"""
    p = Path(DUMP)
    if not p.exists():
        return None
    for line in reversed(p.read_text(errors="replace").splitlines()):
        if line[:2].isdigit() and "\t" in line:
            return line.split("\t", 1)[1]
    return None


def capture_statusbar():
    """用 AX 读回状态项的真实位置和标题，按它的框精确裁图。
    这样连"菜单栏里到底是不是这个 app 在显示"都是独立来源证的
    （`osascript … menu bar item 1`），不靠猜坐标。"""
    script = ('tell application "System Events" to tell process "SparkWatch" to get '
              '{title, position, size} of menu bar item 1 of menu bar 1')
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()
    m = re.match(r"^(.*?), (\d+), (\d+), (\d+), (\d+)$", out)
    if not m:
        return None, None
    title, x, y, w, h = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))
    rect = f"{max(0, x - 6)},{y},{w + 12},{h}"
    subprocess.run(["screencapture", "-x", "-R", rect, str(CROP)])
    return CROP, title


def pixels(path):
    """返回裁图里所有"彩色点"的色相分类 —— 用 PIL 找非灰/非白的像素团。"""
    try:
        from PIL import Image
    except ImportError:
        return None, "PIL 缺失"
    im = Image.open(path).convert("RGB")
    px = im.load()
    w, h = im.size
    found = {}
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            mx, mn = max(r, g, b), min(r, g, b)
            sat = mx - mn
            if mx < 70:            # 太暗：菜单栏底色
                continue
            if sat < 40:           # 近灰/白：文字
                continue
            if g > r + 30 and g > b + 30:
                kind = "绿"
            elif r > 150 and g > 120 and b < 110 and abs(r - g) < 70:
                kind = "黄"
            elif r > g + 40 and r > b + 40:
                kind = "红"
            elif b > r + 30 and b > g + 20:
                kind = "蓝"
            else:
                continue
            key = (kind, x // 12)   # 每 12px 归一堆，避免同一个点被数成几百个
            found[key] = found.get(key, 0) + 1
    counts = {}
    for (kind, _), n in found.items():
        if n >= 2:
            counts[kind] = counts.get(kind, 0) + 1
    return counts, None


def ocr_text(path):
    """tesseract 的 stderr 不保证是 UTF-8（实测会崩在 decode 上），所以按字节收再容错解码。"""
    try:
        r = subprocess.run(["tesseract", str(path), "-", "--psm", "7"],
                           capture_output=True, timeout=30)
        return " ".join(r.stdout.decode("utf-8", errors="replace").split())
    except FileNotFoundError:
        return "(无 tesseract)"
    except subprocess.TimeoutExpired:
        return "(OCR 超时)"


def main():
    names = sys.argv[1:] or list(EXPECT)
    # 两个实例 = 两个数据来源混在一起：AX 只读得到一个，dump 是另一个写的
    # （2026-10-03 实测踩到：AX 报真机的 64/s，dump 报 mock 的 19/s，整张表全红假失败）
    running = subprocess.run(["pgrep", "-x", "SparkWatch"], capture_output=True, text=True)
    count = len(running.stdout.split())
    if count != 1:
        print(f"✗ 现在有 {count} 个 SparkWatch 实例 —— 只能留一个（跑 mock 的那个）再测。")
        return 2
    if not ensure_mock(os.path.dirname(os.path.abspath(__file__))):
        return 2
    Path(DUMP).write_text("")                      # 每轮从干净 dump 开始
    failures = 0
    for name in names:
        set_scenario(name)
        # 计数源"冻结"的场景要多等一会儿：切场景的瞬间 mock 会有一个几十 token
        # 的台阶（真机上对应引擎重启/换模型），app 如实报成一个短促的读数。
        # 等它老下来再断言，测的才是"冻结的计数器不会一直亮绿"。
        time.sleep(EXPECT.get(name, {}).get("settle", 13))
        tail = dump_tail()
        dumped = tail or "?"
        crop, ax_title = capture_statusbar()
        hue, err = (pixels(crop) if crop else (None, "没抓到状态项"))
        text = ocr_text(crop) if crop else "(无截图)"
        bar = ax_title or dumped                   # AX 是屏幕上的真值
        exp = EXPECT.get(name, {})
        problems = []
        if ax_title and dumped != "?" and strip_power(ax_title) != strip_power(dumped):
            problems.append(f"AX 读回 {ax_title!r} 与 app 自报 {dumped!r} 不一致")
        for token in exp.get("present", []):
            if token not in (bar or ""):
                problems.append(f"菜单栏缺 {token!r}")
        for token in exp.get("absent", []):
            if token in (bar or ""):
                problems.append(f"菜单栏不该有 {token!r}")
        # 计数源不动时，可以留着上一场的灰色读数（带年龄），但不许出现"新鲜的绿数字"
        # —— 那正是真机上让主人以为是实时速度的假象。
        if exp.get("no_fresh_rate") and bar and "▶" in bar and "·" not in bar:
            problems.append(f"计数源没动却出现新鲜速率读数: {bar!r}")
        # 屏幕上的色点必须跟 dump 的语义一致: engine_fatal 要红/黄, 正常要有绿
        if hue:
            if name == "engine_fatal" and not ({"红", "黄"} & set(hue)):
                problems.append(f"引擎崩了但状态栏没有红/黄点: {hue}")
            if name == "decoding" and "绿" not in hue:
                problems.append(f"正常解码应有绿点, 实测 {hue}")
        failures += bool(problems)
        mark = "✗" if problems else "✓"
        print(f"{mark} {name:16s} 栏[AX]={bar!r}")
        print(f"   栏[app自报]={dumped!r}")
        print(f"   栏[屏幕OCR]={text!r}   色点={hue} {('PIL: ' + err) if err else ''}")
        for p in problems:
            print(f"   ✗ {p}")
    print(f"\n=== {len(names)} 个场景，{failures} 个不符合预期 ===")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
