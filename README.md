# SparkWatch

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](#build-from-source)
[![Release](https://img.shields.io/github/v/release/greatyingzi/sparkwatch)](https://github.com/greatyingzi/sparkwatch/releases/latest)
[![CI](https://github.com/greatyingzi/sparkwatch/actions/workflows/ci.yml/badge.svg)](https://github.com/greatyingzi/sparkwatch/actions/workflows/ci.yml)

**English** | [中文](README.zh-CN.md)

A macOS menu-bar monitor for a small cluster of NVIDIA DGX Spark (GB10) boxes:
what the hardware is doing **and** what the models on it are doing, in one line.

```
DGX 2/2 · 00 95% 45° ▶28/s · 01 0% 54°
```

Click it for the full per-node readout: GPU utilisation / temperature / power,
**aggregate CPU utilisation and the hottest thermal zone**, unified memory, page
cache, PSI memory pressure, disk, running containers, and the model being served
with its decode speed. **Nothing is installed on the monitored boxes** — no
agent, no exporter, no container stack.

## Preview

The popover — one compact card per node, health and the running task on top,
everything deeper one click away:

![The SparkWatch popover: a compact card per node showing health, temperature,
power, unified memory and the serving model with its decode speed, above
buttons for the detail window, the inference source and shutdown](docs/screenshots/popover.png)

The main window — fleet totals first, then a panel per machine and its history:

![The SparkWatch main window: fleet decode rate, unified memory in use and
engine state, followed by per-machine panels with GPU utilisation and history
graphs](docs/screenshots/main-window.png)

Both screenshots are a live run against two GB10 boxes.

## Features

**One line, always visible.** Node names or dots, GPU utilisation, live decode
rate, and a warning flag that only appears when something is actually wrong —
four presets, and a custom one. Colour carries state, so even `● ●` stays
useful. See [Status bar](#status-bar).

**Two boxes as one task.** A tensor-parallel deployment is read off the process
tables, not guessed from ports: the popover shows one banner per task, and each
card states its own role (`rank 0 · API` / `rank 1 · headless worker`). An idle
leftover engine on the worker's old port is not mistaken for the serving model.
See [Multi-machine tasks](#multi-machine-tasks).

**Inference, not just hardware.** vLLM, SGLang, llama.cpp, TGI, LM Studio,
Ollama and anything OpenAI-compatible, detected from the endpoint — decode rate,
queue, KV pressure, speculative acceptance, latency percentiles, token and
energy ledgers. See [Inference engines](#supported-inference-engines).

**Honest numbers.** A rate is a counter difference, never an average or an
extrapolation; it appears within ~2 s of a request starting and greys out with
its age when it stops rather than lying in green. Power is shown as *measured GPU
rail* and *estimated whole machine*, labelled as such, with the raw sample kept
one hover away. Health rules are graded against the platform's own declared
limits instead of fixed numbers that age badly. See
[Decode speed](#decode-speed-measurement-and-presentation),
[Power](#power-what-is-measured-and-what-is-estimated) and
[Health rules](#health-rules).

**Progressive disclosure.** A fixed-height card in the popover for what fits
(never scrolls, never overlaps), a resizable main window for what needs time —
history curves, energy, token ledger, event feed. See
[Interface](#interface-three-tiers-and-why).

**Verifiable without a machine.** `--preview` renders the UI offscreen from live
data or from a synthetic fleet (`--demo-devices 12`), and a headless probe
reconciles the dashboard against independently read values. See
[Verification](#verification-without-a-machine-in-front-of-you).

## Install

### Homebrew

```bash
brew install --cask greatyingzi/tap/sparkwatch
```

One tap holds every app of mine, so this is the only tap to add. `brew upgrade
--cask sparkwatch` updates it; `brew uninstall --cask --zap sparkwatch` removes the
app and its settings. The first launch still needs the one approval described
below — Homebrew 7 removed its `--no-quarantine` flag and hands the quarantine
attribute to the installed app, so the cask prints the same instruction.

### Download the DMG

Grab **`SparkWatch-0.3.0.dmg`** from
[Releases](https://github.com/greatyingzi/sparkwatch/releases/latest), open it, and
drag **SparkWatch** onto the Applications folder next to it.

The app is ad-hoc signed — no Apple Developer ID, because a paid developer account
is the only way to get one — so a copy that came off the network is quarantined and
Gatekeeper stops it. It looks like "nothing happens when I double-click". One
command fixes it:

```bash
xattr -dr com.apple.quarantine /Applications/SparkWatch.app
```

The recursive `-r` matters: the quarantine bit is on the inner executable too, so a
non-recursive removal appears to do nothing. In the GUI: right-click the app →
**Open** → **Open** again; if macOS only offers "Done", go to
**System Settings → Privacy & Security** and click **Open Anyway**. The release
page and a note inside the DMG both spell this out.

Verify the download against the SHA256SUMS file in the same release.

### Installer script (builds from source)

```bash
git clone https://github.com/greatyingzi/sparkwatch.git
cd sparkwatch
./Scripts/install.sh              # build → /Applications → clear quarantine → register → launch
./Scripts/install.sh --uninstall  # remove app + login item (add --purge to drop config too)
```

### Build from source

Requires macOS 14+ and the Swift 6 toolchain (Xcode command line tools are
enough). No external dependencies.

```bash
swift test                                   # 214 unit tests
./Scripts/build-app.sh                       # dist/SparkWatch.app, ad-hoc signed
open dist/SparkWatch.app
```

Run the acceptance probe once and both implementations are cross-checked — the
dashboard against values read independently over SSH:

```bash
DGX_PW_00=… DGX_PW_01=… swift run sparkwatch-probe -- --seconds 20
```

Building from source takes about a minute, and needs no dependencies beyond
the Swift toolchain.

### What the installer gives you

| | |
| --- | --- |
| **Launchpad / Spotlight** | `SparkWatch` appears with its own icon (⌘-space → "SparkWatch"). It is a menu-bar app, so it has **no Dock icon by design** — the notch is in the menu bar |
| **Start / stop** | Launch it like any app; quit with ⌘Q or 状态栏菜单 → 退出; **暂停监控 / 恢复监控** from the popover button, the right-click menu, or 设置 → 通用 |
| **Launch at login** | 状态栏菜单 → 开机自动启动, or 设置 → 通用 (LaunchAgent in `~/Library/LaunchAgents`) |
| **Icon** | Generated by `Scripts/make-icon.py` (all macOS sizes → `.icns`), regenerated automatically when the script changes |
| **Config / data** | `~/Library/Application Support/SparkWatch/` — settings.json + sessions.json (0600) |
| **About** | 状态栏菜单 → 关于 SparkWatch (version, channels, config path) |

The installer deliberately deletes the repo build output afterwards: with two
identical bundles registered, `open SparkWatch` can hand you the stale one.
Rebuild a dev copy any time with `./Scripts/build-app.sh`.

### First launch

The app starts on the SSH channel and offers **登录 <node>…** in the menu. Sign in
with the box's system account (the same credentials as the DGX Dashboard web UI).
The password is never stored; the 14-day token is.

## Usage

### Add a machine

1. **SSH key login** to the box (`ssh-copy-id user@host`) — that is the only hard
   requirement; SparkWatch never installs anything on the monitored machine.
2. Launch SparkWatch. On first run (no config yet) the settings window opens by
   itself; any time after that it is **状态栏菜单 → 设置…** (or right-click →
   设置…, or launch with `--settings`).
3. **添加机器**, then fill in name / SSH host / user.
4. Press **扫描**: it runs a port scan *on the box* (8000, 18300, 8080, 30000,
   11434, 1234, 5000, …) and lists anything that answers like an inference
   server, with its engine and model. Click a result to use it.
5. Press **体检**: three checks — SSH reachable, DGX Dashboard reachable and
   login works, inference endpoint understood. The password is used for the
   check and the login only; it is never written anywhere.
6. **保存并应用**.

A non-DGX Linux box works too: skip the dashboard (no password needed) and it
runs on the SSH channel — hardware from `nvidia-smi` + `/proc/meminfo`, plus the
inference row if you set an endpoint. Only the GB10/Spark-specific health rules
(unified memory, PSI pressure) need either DGX OS or plain Linux `nvidia-smi`.

Command-line equivalents (useful before touching the UI, and for scripting):

```bash
swift run sparkwatch-probe --scan spark-b                 # find endpoints
swift run sparkwatch-probe --engine http://box:8000            # test one endpoint
swift run sparkwatch-probe --check spark-00 --password …       # full node check
```

### Status bar

Four presets, switchable in 设置 → 状态栏 (with a live preview of the real readout):

| Preset | Looks like | Use |
| --- | --- | --- |
| 精简 (default) | `00 01 ▶32/s` | node names + live decode rate; speed only appears while tokens are flowing |
| 详细 | `00 93% 63° ▶28/s 01 0% 43°` | utilisation + temperature per node |
| 极简 | `● ●` | coloured dots only (one per node) |
| 自定义 | — | pick any combination of: 节点名 / GPU 利用率 / 温度 / 内存占用 / 实时速度 / 在线数 |

Colour carries the state, so even the shortest preset stays informative: green =
healthy, orange = degraded (or on the SSH fallback), red dot = unhealthy, red ✕ =
not answering, and a `⚠` appears only when something is actually wrong. The
readout never includes a number that is not being measured — an engine without
counters does not get a fake speed column.

### The main window

⌘D opens it from the status-bar menu (or the popover's 主窗口 button). A 248 pt
sidebar indexes the fleet and its pages — 概览 / 能耗 / Token 统计 / 活动 / 基准测试 —
plus one page per machine; ⌘K opens a command palette (jump to a page or a
machine, pause, refresh, cycle the theme). What lives on which page, and the
measured capacity of each surface, is in
[Interface](#interface-three-tiers-and-why).

### Configuration file (optional)

Everything above writes `~/Library/Application Support/SparkWatch/settings.json`.
Editing it by hand is supported — decoding is deliberately tolerant, so a file
written by an older build (or missing fields) never fails wholesale:

```json
{
  "sampleIntervalSeconds": 2,
  "slowProbeIntervalSeconds": 60,
  "nodes": [
    { "id": "…A0", "name": "spark-00", "sshHost": "spark-a", "sshUser": "operator",
      "dashboardLocalPort": 19100, "inferenceMetricsURL": "http://100.64.0.10:18300",
      "enabled": true }
  ]
}
```

Sessions live next to it in `sessions.json` (mode 0600). The password is never
stored; only the 14-day dashboard token is.

Deliberately **not** the Keychain: an item's ACL is bound to the exact binary
that created it, so an ad-hoc signed build — which changes identity on every
rebuild — gets an authorisation prompt on every access. For a token that only
grants read access to a box we already have passwordless SSH to, that is a lot of
prompting for very little. A 0600 file under Application Support holds it instead.

## Support

SparkWatch is a spare-time project. It is free, has no telemetry, no account and
no paid tier: every feature in this document is in the build you just cloned, and
nothing here is held back or gated behind a licence key. If your box is offline
or behind an air gap, it stays offline — the app talks to your machines and
nowhere else.

What it costs to run is real, though: an Apple Developer certificate so builds
are signed and notarised rather than "right-click, open anyway" (a paid account
is the only way to do that), and the hardware it is developed against. If you
want to put money towards that, the channel is **[Ko-fi](https://ko-fi.com/yingzi62662)** —
it passes payments straight to PayPal, holds nothing itself, and takes no cut of
a tip.

Nothing is unlocked by it: no priority, no extra features, no attribution
requirement. The build you cloned is the build a supporter gets.

What genuinely helps more than money:

- **A bug report with the specific behaviour** — which engine, which readout,
  what it said versus what you expected. Nearly everything in
  [Traps](#traps-worth-knowing) came from one of those. Reports go in
  [issues](https://github.com/greatyingzi/sparkwatch/issues/new/choose).
- **A run against hardware I do not have.** SGLang, TGI, ROCm, a non-DGX Linux
  box: the adapters are written from protocol facts and endpoint captures, so a
  real machine is the difference between "parses the payload" and "supported".
- **A star**, if it saved you a shell command — it is how the next person finds
  it.

# Technical

The short version is above. Everything below is how it works and why, in roughly
the order you would ask about it.

## Why this exists

The published options each fall short in a different way:

| Project | What it does | What it misses here |
| --- | --- | --- |
| [amer8/pulsebar](https://github.com/amer8/pulsebar) | official DGX Dashboard API, RAM + GPU in the menu bar | single box, `_in_mb` only → memory blank on a box streaming `_in_kib`, no inference |
| [AdrianBinDC/DGXPulse](https://github.com/AdrianBinDC/DGXPulse) | same channel, NVIDIA Sync aware, Keychain | single box, no inference |
| [btoro/SparkTPS](https://github.com/btoro/SparkTPS) | vLLM/SGLang throughput, history, idle alerts | inference only, no hardware |
| [leplik/dgx-spark-bar](https://github.com/leplik/dgx-spark-bar) | best GB10 domain logic (unified memory, PSI, low-power wedge) | needs a system agent installed on each box, hardware only |
| [sambitcreate/sparkbar-mac-dgx](https://github.com/sambitcreate/sparkbar-mac-dgx) | multi-node + inference + unified memory | requires the sparkDash Docker stack on some host |

SparkWatch is the combination: **two boxes at once, official-dashboard hardware,
vLLM/SGLang inference, and nothing installed on the boxes.**

## Data channels

1. **Official DGX Dashboard API** — per node, through our own SSH forward
   (`ssh -N -L 127.0.0.1:<port>:localhost:11000`), `POST /api/login` → a 14-day
   RS256 JWT → `GET /api/v1/gpu_telemetry/stream` (SSE, ~1 Hz). Undocumented and
   internal, but it is the only source that reports the GB10 unified memory pool
   correctly.
2. **Inference** — `GET /metrics` on the vLLM/SGLang endpoint, straight over the
   tailnet. Counters are cumulative and are summed across label sets
   (`engine`, `finished_reason`, `is_streaming`) before diffing into tok/s.
   Falls back to fetching the box's own loopback over SSH if the direct request
   is blocked.
3. **Slow SSH probe** (default 60 s) — `/proc/meminfo`, `/proc/pressure/memory`,
   `df`, `docker ps`, raw `nvidia-smi`. Everything the dashboard omits, plus a
   second opinion used for reconciliation.

Degradation is explicit and visible: `[dash]` → `[ssh]` → down. A node that
loses the dashboard channel keeps working from SSH rather than going dark.

## GB10 specifics baked in

* `nvidia-smi` reports `memory.used/total = [N/A]` on unified memory, so memory
  never comes from it; the fallback path reads `/proc/meminfo` instead.
* `/proc/meminfo`'s "kB" is really **KiB**. Proven byte-exact on a Spark:
  `127598548 × 1024 == 130660913152 == free -b` total. Treating it as 1000
  manufactures a phantom 2.3 % disagreement with the dashboard.
* The dashboard's field names are unit-dependent **per host** (verified on two
  machines running the byte-identical binary, `md5 292142e5…`): one streams
  `memory_total_in_kib`, the other `memory_total_in_mb`. Both are parsed and
  normalized to bytes; an absent field hides the row instead of printing 0.
* `power_limit_in_w`, `gpu_memory_in_use_in_mb` and `cpu_memory_in_use_in_mb`
  are constant 0 on GB10 (even with a 104 GB vLLM resident) and are not modelled.
* Health rules use field-reported thresholds (see `Sources/SparkWatchCore/Health.swift`),
  including the documented "busy GPU drawing ~14 W" wedge that makes a Spark run
  at a quarter speed while every metric still looks green.

## Supported inference engines

Detected automatically from the endpoint — no engine setting needed. "Tested"
means verified against a live server; the payload shapes are in the unit tests.

| Engine | How it is detected | What the card shows | Verified |
| --- | --- | --- | --- |
| **vLLM** | `/metrics` with `vllm:` families | tokens, running/waiting, KV%, tok/s, model, request counts | ✅ spark-a :18300 |
| **SGLang** | `/metrics` with `sglang:` families | same family as vLLM, plus native throughput | ⚠️ family names only (no live SGLang here) |
| **llama.cpp** / llama-server | `/metrics` with `llamacpp:` + `/v1/models` `meta` | tokens, processing/deferred, native tok/s, spec-decode acceptance, quant, context, params | ✅ llama-server 0.4.1 (Qwen2.5-0.5B) |
| **LM Studio** | `/api/v0/models` | model, loaded state, quant, arch, context; **no counters** | ✅ server on :1234 |
| **Ollama** | `/api/ps` | loaded model, VRAM, quant, params; **no counters** | ✅ spark-b :11434 |
| **TGI** | `/metrics` with `tgi_` families | tokens, batch size, queue | ❌ names only — no live TGI to test against |
| any **OpenAI-compatible** | `/v1/models` | model name + reachability | ✅ via the llama.cpp path |

When an engine cannot report speed, the card says so ("该引擎不提供速率/请求计数")
instead of showing an empty readout.

Traps that this matrix exists to document:

* **LM Studio answers `GET /metrics` with HTTP 200 and an error body.** The
  status code proves nothing; the body is validated (`looksLikeMetrics`).
* **llama.cpp answers 501 without `--metrics`.** Start it with `--metrics` if you
  want token counters; otherwise the card falls back to model facts only.
* **vLLM answers 404 on `/`** while serving fine, so reachability means "any
  HTTP answer", not 2xx.
* **Ollama and LM Studio are loopback-only by default.** SparkWatch reaches them
  through the SSH channel (curl on the box) without exposing anything — see
  `SshCurlTransport`. Pointing the URL at the box's tailnet address works too if
  you bind the server to it.
* **No counters exist for Ollama/LM Studio.** Their APIs simply do not report
  tokens served; the app shows the model and VRAM rather than inventing numbers.

## Health rules

Thresholds are taken from `joeynyc/spark-doctor` (MIT) — field-reported DGX Spark
behaviour rather than desk guesses — but the severities are re-graded where
unified memory makes the original reading misleading.

| level | fires when |
| --- | --- |
| **异常** (critical, ⚠) | node unreachable (both channels down) · GPU ≥ 90 °C · ACPI zone within **6 °C of the platform's declared limit** (104 °C here) · **zone within 12 °C of the limit and still climbing** (≥0.5 °C/min over a 5-minute window) · memory PSI `full avg10` > 0.25 · MemAvailable < 2 GB · MemAvailable < 8 GB **with** PSI > 0.25 · GPU busy ≥ 80 % **while drawing ≤ 25 W and the SM clock has collapsed to ≤ 800 MHz** for 3 consecutive samples (the documented low-power wedge) · **a power-delivery or 5 W driver signature matched** |
| **注意** (warning) | GPU 85–90 °C · ACPI zone within 12 °C of the limit · **zone within 22 °C and climbing** · thermal-limiting signature (not a defect: lock/airflow) · PSI 0.10–0.25 · MemAvailable 8–16 GB · MemAvailable < 8 GB with PSI ≤ 0.25 (a resident model parking the floor — normal) · swap used > 8 GB · 1–2 low-draw samples · slow-channel error |
| **正常** | none of the above |

The ⚠ in the menu bar is a separate flag: only the conditions a green dashboard
hides (unreachable, thermal, memory-pressure stalls, the low-power wedge) raise
it. A box that is loaded and doing its job must not sit in permanent alarm.

The low-power-wedge rule also had to be tightened. `utilization.gpu` reports
that a kernel was resident, not that work is being done: on a tensor-parallel
pair a rank waiting on its peer link reads 90 %+ while drawing ~20 W, and the
box idles at 2411 MHz. The result was a standing ⚠ on a healthy pair — measured
live at 96 % / 23 W **while decoding at 27-65 tok/s**. The wedge has a different
signature: *collapsed clocks*, which spark-doctor's own rule names as the
confidence signal. So the clock is now required rather than a hint, and an
unknown clock never escalates (an alarm nobody can act on is worse than a wedge
nobody spotted). Verified under load: 95 % / 42 W / 2411 MHz stayed 注意 with
zero wedge alarms. This also exposed a real data-path bug — the dashboard stream
replaces the whole GPU sample once a second and was wiping the SSH-only clock
field, so the rule had silently never seen a clock at all.

The ACPI-zone rule was rewritten after it produced a standing ⚠ on this pair:
the zones live at 78–91 °C under sustained inference and the platform declares
**104 °C** as the limit for them (read from the zone's own trip point), so a
hard-coded 90 °C line made a healthy machine look critical all day — the fastest
way to teach someone to ignore the icon. The GPU rail keeps absolute 85/90
because GB10 exposes nothing to be relative to: `temperature.gpu.tlimit` returns
`4` and all shutdown/slowdown limits are `N/A`.

Two deliberate deviations from spark-doctor's numbers: `MemAvailable < 8 GB` is
**注意**, not 异常, because on unified memory a resident model parks the figure at
7–8 GB on a 121 GiB box while PSI stays 0.00 — nothing is actually waiting on
memory, and PSI is what escalates it (below 2 GB stays 异常 regardless, since
OOM is imminent). The separate `MemAvailable/MemTotal < 15 %` rule was dropped:
it fires at the same moment as the absolute one on every plausible machine size,
so it only ever echoed the same condition onto a second line.

## Decode speed: measurement and presentation

The rate is a **counter delta**: the engine's `completion_tokens_total` is read on
every probe (2 s while the box is working, 6 s when it is quiet), and tok/s is the growth divided by the elapsed time. Nothing is
averaged and nothing is extrapolated — a probe whose counter did not move produces
no rate at all.

That leaves a presentation question the app got wrong: between the last token and
the next probe, and for a while after a request ends, the most recent
measurement is still the most recent *fact* — but showing it in the same bright
green as a live rate claims "this is happening now", which is false. The fix is
three states, decided by the age of the measurement (and, when the engine reports
it, by whether anything is still running):

| state | when | how |
| --- | --- | --- |
| **live** | measured ≤ 12 s ago | green `▶47/s` |
| **stopped** | older than that, up to 2 min | grey `▶47/s · 已停 32秒` — the number is still true, the claim is not |
| **hidden** | older than 2 min, or never measured | the row says 已停止 (or 空闲 if nothing ever ran) |

The menu bar only ever speaks in the present tense: a stale rate never reaches it.

Two bugs surfaced while implementing this, both worth naming:

- `TokenRateTracker.age()` (added here) initially measured against the timestamp
  of the *last probe* rather than the *last counter growth*. Since the probe
  refreshes that timestamp every cycle, the age was always ~0 and nothing could
  ever be classified as stale — the rate stayed bright indefinitely. This is the
  mechanism behind "推理停止了但速度没降下来".
- An engine that reports `running == 0` is authoritative: the moment a request
  ends, the number goes grey rather than waiting out the freshness window.

Verified end to end on a real (slow) request: `hidden → live(▶3/s, menu bar shows
▶3/s) → stopped(11 s…96 s, menu bar silent) → hidden`. All three states are
unit-tested, including the tracker's last-rate-and-age behaviour.

### Showing fast, hiding slow: the display is deliberately asymmetric

A rate is only useful if it arrives while the work is still happening, and only
readable if it does not blink. Those two requirements pull in opposite
directions, so the two ends are tuned separately.

**Appearance is bounded by the probe, not by a fixed clock.** The cadence
follows the cheapest signal available — the 1 Hz GPU utilisation and power from
the dashboard stream, plus the engine's own in-flight report:

| state | cadence | why |
| --- | --- | --- |
| working (util ≥ 15 %, or ≥ 25 W, or engine reports in-flight) | **2 s** | the first rate after a request starts must land almost immediately; a fixed 5 s cadence was the latency people felt |
| quiet | **6 s** | each probe costs an SSH round trip on a loopback-only engine, and an idle counter has nothing new to say |

The loop wakes every 400 ms so the cadence is actually honoured — a 2 s cadence
behind a 2 s sleep drifts to 4 s.

**The first reading of a request is checked for dilution.** A rate is a delta
between probes, so an interval that began before the work did is part idle time:
a request starting 1 s into a 6 s idle interval reads a fifth of its true speed
and then jumps. Rather than show a wrong number fast, that first reading is
dropped (the probe still re-baselines the counter) and the next one — a couple of
seconds later, wholly inside the busy period — is accurate.

**Disappearance has hysteresis.** News of work arrives as fast as the probe
allows; the end of work waits:

| | |
| --- | --- |
| measured ≤ 12 s ago | live — a couple of missed probes do not grey anything |
| engine says nothing is running, ≥ 6 s after the last measurement | grey — the dwell stops a gap between two requests from flashing |
| no measurement for 120 s | gone |

A failed probe no longer erases the number either: it keeps the last measurement
with its age, so a hiccup greys it (and it expires normally) instead of dropping
straight to "已停止".

### Why the first number can read low, and why that is not a display fault

Measured on a real request (trace of every probe, timestamps relative to the
request starting):

| | before | after |
| --- | --- | --- |
| first value shown | +1.1 s — **7.5 tok/s**, diluted by 5 s of preceding idle | +2.0 s — 14.1 tok/s, honest for its window |
| true sustained rate | +5.7 s | +4.6 s |

Two defects produced the old sequence, both the same shape — *a refresher eating
the information a check depends on*:

- the interval guard was evaluated **after** the tracker's `update()`, which
  refreshes the "last probe" timestamp, so the gap always measured ~0 and no
  diluted reading was ever rejected;
- `TokenRateTracker.age()` (earlier) measured against that same refreshed
  timestamp, so nothing could ever be classified as stale.

With the guard fixed, a reading whose interval straddles idle time is dropped and
the collector probes again 0.3 s later to establish a clean baseline — that is
the +1.1 s → +2.0 s improvement in *when something appears*.

The remaining 2 s before the rate reaches its true value is the engine, not the
display: the first window after a request starts contains the tail of prefill and
the drafter's warm-up, and only ~24 tokens were actually produced in it. That low
figure is true of that window. (The engine's own `decode_seconds_total` was
parsed to avoid exactly this, then **deliberately not used**: this engine flushes
it in batches, so a 2 s window can see 4.4 s of "decode time" — it read 17.9 tok/s
for work running at 52. A counter whose flush granularity is coarser than the
sample window is worse than wall time, not better.)

## Power: what is measured and what is estimated

On the power numbers, also honestly: **two values, only one of them measured.**

- **GPU 功耗 — measured.** NVML's `power.draw`, which on GB10 covers the GPU rail
  of the SoC and nothing else (verified on the box: `GPU Memory Power Readings`
  and `Module Power Readings` are `N/A`, all power limits are `N/A`, there is no
  RAPL, no hwmon power sensor, no USB-C PD telemetry, and no BMC/IPMI device —
  `ipmitool` is installed but `/dev/ipmi0` does not exist). The official DGX
  Dashboard streams the same single number (`power_draw_in_w`, identical to
  `nvidia-smi`), so there is no better on-box source. An independent NVIDIA-forum
  audit of GB10 energy telemetry reached the same conclusion from the other side:
  DCGM's CPU/SysIO/Module power fields are recognised but return `0.000`, the six
  I2C buses are empty (no INA current monitors on the board), and loading all 8
  CPU cores for 15 s moves the GPU energy counter by exactly zero — the Grace CPU
  rail is simply not instrumented.

- **整机≈功耗 — estimated, and labelled as such.** One formula, read by the
  cards, the menu bar, the fleet pages and the energy ledger (kWh, Wh per output
  token, cost) alike:

  `wall = clamp(1.61 × GPU rail + 95 × CPU load fraction, 20 W, 200 W)`

  The CPU load fraction is utilisation × (current ÷ maximum clock) — dynamic power
  tracks clock, and GB10 runs two clusters (3.9 GHz + 2.808 GHz) whose `cpufreq`
  is readable. Neither bound is arbitrary: 20 W is the idle floor on current
  firmware (after the ConnectX-7 hot-plug fix) and 200 W is the measured ceiling —
  240 W is only the USB-C adapter's rating, which a wall meter never reaches.

  The coefficients come from a constrained fit over published wall-meter anchors
  (2026 firmware), not from two points:

  | state | GPU rail | CPU load | wall |
  | --- | --- | --- | --- |
  | idle (headless, fixed firmware) | 11 W | ~3 % | 22–25 W |
  | MoE decode, steady | 15 W | ~20 % | ~45 W |
  | LLM inference, typical | 35.7 W | ~30 % | 60–90 W |
  | 2-node TP pair (Shelly) | 47.7 W | ~40 % | 117 W |
  | CPU saturated (20 cores) | 12 W | 100 % | 120–130 W |
  | GPU saturated (Vulkan) | 87 W | ~20 % | ~170 W |

  Worst-case residual over those anchors is 10.9 W (RMS 7.8 W) — that is the
  ceiling of a software-only estimate, because the anchors come from different
  machines and firmware. All three coefficients (GPU slope, CPU full-load watts,
  floor/cap) live in 设置 → 功耗, and a one-off calibration against a metering plug
  is a drop-in replacement for the defaults; the plug is not needed at runtime.

  Two honesty rules: **low confidence is stated** (CPU reading missing → 20 %
  prior, GPU rail outside the anchored range, CPU-heavy corner), and hovering the
  number shows the arithmetic (`≈1.61 × 35.1W + 95 × 10% = 66W`). The ledger and
  the card consume the same reading — previously there were two formulas
  (`12 + 2.20×GPU` and `GPU + CPU(65 W TDP) + 23`) that could disagree by 62 W,
  and only one of them was editable.

On the CPU numbers, honestly: GB10 exposes **no CPU package temperature sensor**.
The card therefore shows the hottest ACPI thermal zone (`/sys/class/thermal`) and
labels it 最热区 rather than pretending it is a CPU package reading. CPU
*utilisation* is real: two `/proc/stat` reads one second apart inside the same
SSH call, since the probe is stateless. (For reference, the box's other thermal
sources are the NVMe SSD at ~41-44 °C and the ConnectX-7 ASIC at ~48 °C.)

### A windowed mean, because the raw number is unreadable

On a tensor-parallel pair the raw `power.draw` swings violently — not a fault,
just each rank alternating a compute burst with a wait on its peer link.
Measured on this pair under load (50 samples, ~1.3 s apart):

| | spark-00 | spark-01 |
| --- | --- | --- |
| raw range | 50.7–84.6 W | 43.3–84.8 W |
| adjacent-sample jump (avg / max) | 9.4 W / 33.8 W | 10.4 W / 37.8 W |

So the displayed figure is a **trailing mean over a window**, and the window is
expressed in seconds because that is the only unit that means anything here: the
oscillation period is ~2–4 s, and a window shorter than one period just resonates
with it.

| window | residual jump (avg) |
| --- | --- |
| ~4 s | 4.07 W — resonates with the cycle, little help |
| ~6.5 s | 2.52 W |
| **~10 s (default 8 s setting)** | **1.71 W** |
| ~13 s | 1.06 W — flattest, but visibly laggy |

Default: **8 s** (设置 → 功耗 → 显示平滑, 0 = raw). Verified live through the app's
own data path: displayed jumps 1.70 W / 1.79 W against raw jumps of 13.78 W /
15.00 W — an 88 % reduction, at the cost of roughly half a window of lag when a
request starts or stops.

Two rules keep it honest. The **raw sample is kept** (`powerInstantW`) and shown
in the card's tooltip — "8 秒窗口平均 67.3 W（瞬时 84.0 W）" — because a smoothed
number nobody can check against the instant it came from is just a nicer-looking
lie. And the mean feeds every consumer, including the low-power-wedge rule, where
"sustained" is exactly what a mean measures; the whole-machine estimate inherits
it for free.

## 2-second thermal telemetry, failure signatures, and off-box forensics

This layer exists because of one concrete failure shape: under sustained load this
box **hard power-offs** — measured SM clock falling 2450 → 1475 within ~150 s, the
ACPI zone peaking at 96 °C, then power cut (journald stops mid-line, pstore empty,
no watchdog). The same zone declares a 104.8 °C trip point, so an *absolute*
"warn within 6 °C of the ceiling" line can never fire before the machine is
already off; and healthy boxes live at 78–91 °C under sustained inference, so
lowering the line lights a permanent ⚠ on a good machine.

Three pieces therefore ship together:

1. **A 2-second thermal stream.** One standing SSH session runs a read-only loop on
   the box (nothing installed, nothing written, the process dies with the
   connection) and emits one line every 2 s: hottest `acpitz` + its trip point,
   `nvidia-smi` power/utilisation/temperature/SM clock/throttle bits, `/proc/stat`
   and `cpufreq`. Not a faster poll: a fresh `ssh` costs **1.27 s** on this tailnet
   (measured, 5 calls = 6.37 s), while a standing stream costs zero round trips and
   ~30 bytes per sample. And it must be shipped off-box, because the box's own log
   dies with the power — **this Mac is the only surviving recorder**.
   The `acpitz` versus `nvidia-smi` gap is real and large (measured 88.9 °C zone vs
   79 °C smi; the last sample before a documented cutoff was 92.2 °C zone vs 84 °C
   smi), so heat can only be judged on the zone column.
2. **Trend-based thermal alerting.** A least-squares slope over a 5-minute window
   (needs ≥90 s of data): within 22 °C of the ceiling *and still climbing* → 注意;
   within 12 °C *and climbing* → 异常. The absolute thresholds stay, but stop being
   the only evidence.
3. **Power-off forensics.** When the boot id changes (or uptime goes backwards),
   read the previous boot's journal (`journalctl -b -1`) and answer with evidence:
   a clean shutdown marker → normal; a pstore dump → kernel crash; panic/lockup lines
   → watchdog; a log that simply stops without any marker → **suspected hard
   power-off or hard kill** (indistinguishable in the log, hence "suspected");
   unreadable/rotated → undetermined. pstore needs root, so "could not read" is
   reported as missing evidence and never as "clean".

Three things measurement taught: a full `journalctl -b -1` scan costs **21 s** on
this box (762 k lines), so only tail-bounded `-n` queries are used (~2 s); `tr`
eats the trailing newline, so the next `echo` lands on the same line and silently
merges two sections (the PCIe counters were swallowed by `cpufreq` until
`--print-status` started printing per-section line counts); and a read-only probe
must distinguish "did not see it" from "the box does not have it", or a verdict
turns optimistic for free.

### Four failure signatures, four different actions

| signature | evidence | action |
| --- | --- | --- |
| low-power wedge | util ≥ 80 %, power ≤ 25 W, SM clock ≤ 800 MHz, 3 samples in a row | power-drain and reboot |
| power-delivery defect | GPU rail pinned at 27–30 W at util ≈ 0 **and** `insufficient power on the PCIe slot` after the first 3 minutes | RMA |
| thermal limiting (not a defect) | thermal-slowdown bit set, util ≥ 40 %, power ≥ 55 W | clock lock / airflow / stand it upright |
| 5 W driver bug | power ≤ 8 W at util ≈ 0 with a clean kernel log, **and driver < 580** | upgrade to 580.x |

The "after the first 3 minutes" gate is load-bearing: **every** healthy Spark in
this fleet logs four of those PCIe power lines during boot (one per ConnectX-7
function, same second) and then runs for weeks. A rule keyed on the raw dmesg line
would send healthy hardware to RMA, so the boot burst is counted separately and
never used as evidence.

### Clock-lock state (inferred, never read back)

`nvidia-smi` does not report a lock (`Applications`/`Max Clocks` stay 2418/3003),
so the state is inferred from load-time samples: a 2200 MHz lock shows a flat
2164–2184 MHz band (±40 MHz), an unlocked box boosts to 2400+. Anything in between,
or a thermally throttled box, is reported as unknown rather than guessed. The point
is that a lock **does not survive a reboot** — "I locked it last week" is a belief
that can be falsified.

## Multi-machine tasks

A distributed deployment is not two servers — it is one task with roles. The app
reads the topology off the boxes' process tables (slow channel, read-only) rather
than guessing from ports:

| what it reads | why |
| --- | --- |
| `--nnodes`, `--node-rank` | is this one task spread over N machines, and which rank is this box |
| `--headless` | this rank serves **no HTTP at all** — anything answering on its old port belongs to some other, usually idle, engine |
| `--tensor-parallel-size` | TP2 means the model is split across both boxes; each holds half |
| `--master-addr`/`--master-port` | the rendezvous address — what actually ties two processes into one task |
| `--served-model-name`, snapshot path | what the task is serving (the snapshot hash is stripped so the key survives a re-deploy) |
| `VLLM::Worker_TP<n>` (process title) | the local worker rank, corroborating `--node-rank` |

The popover then shows one banner per task above the per-machine cards:

```
GLM-5.3-Flash-EXL3   TP2 · 2 机   EXL3   830K ctx
00 rank 0 · API      01 rank 1 · headless worker      一次请求同时压两台
```

and each card states its own role (`rank 0 · API` / `rank 1 · headless worker`).

Verified against a live pair (`vllm serve ... --nnodes 2 --tensor-parallel-size 2
--quantization exl3 --max-model-len 850000`): both cards now report
`GLM-5.3-Flash-EXL3` — previously rank 1 showed *ollama*, because an idle Ollama
was still listening on its old port and a per-node probe had no way to know the
box had stopped being an Ollama server and become a TP worker. The endpoint is
now derived from the API rank's own `--port` (`http://spark-a:8888`), a
headless rank's stale URL is cleared, and both GPUs were observed stepping to
95–96 % on a single request — which is what "parallel across devices" means.

Consequences worth knowing: only the API rank can report tokens/s, so the menu
bar speed is not double counted; a headless rank's inference row is filled from
the topology (it is running exactly the task's model) instead of from a probe
that cannot succeed; and two independent single-box replicas of the same model
are deliberately **not** merged — without a rendezvous address there is nothing
tying them together, and merging them would invent a task that does not exist.

### The deployment banner's one live slot

The banner answers "what is happening right now" in a single slot with a
priority ladder — decode rate, then prefill, then in-flight count — because only
one of those is ever the answer, and at 400 pt the banner could not hold three.

Two things had to be fixed in it:

- **Ask every node, not the first one.** The ladder originally read
  `nodes.first.inference`, and a headless worker has no rate of its own (it
  serves no HTTP). When the worker came first in the snapshot array, a deployment
  decoding at 63 tok/s announced 处理中 ×2. A deployment-wide number has to be
  gathered across the deployment.
- **Label the gap instead of mis-filling it.** The rate is a counter delta, so
  the first samples after a launch have none — and that window used to fall
  through to 处理中 ×N, which reads as "no speed here, ever". When the engine
  reports that it is decoding (`/health` streams) but no rate exists yet, the
  banner now says **▶ 测量中…**. Verified over a launch: 6 samples of 测量中, then
  the real ▶63/s / ▶60/s / ▶50/s as the counter deltas landed.

A worker also no longer invents an in-flight count it cannot know: it used to
report `running = 1` (meaning "this rank is up"), which the menu bar read as a
request in flight — a permanent ×1 on an idle deployment.

## Choosing which inference service to show

A port scan cannot know intent. On this very pair, rank 1 is a **headless TP
worker** that answers no HTTP at all, while a months-old **idle Ollama** sits on
`127.0.0.1:11434` — to a scan both look like "an inference service", and picking
the wrong one reports a stranger's numbers as if they were what the box serves.

So the scan proposes and the user decides. Every machine's card (detail window)
and every machine's row (设置 → 监控的机器) carries a **来源** picker:

| choice | behaviour |
| --- | --- |
| 自动 (default) | topology first — a TP rank shows the task's model and its rank; otherwise the most confident scan hit |
| `:8888 · vllm · GLM-5.3-Flash-EXL3` | pinned: probe exactly this, and if it fails say so instead of drifting to another service |
| `:11434 · ollama · 仅本机` | the stale leftover is offered too — pinned, it shows *its* real state (here: no model loaded) |
| 不显示 | this machine's inference row is hidden and nothing is probed |

Candidates come from the box's own process table joined with its listening
sockets (`InferenceCandidates`, unit-tested): a port alone cannot say whether it
is vLLM or a leftover Ollama, and a process alone cannot say which port it
answers on. Two rules matter — a headless rank's `--port` is **not** offered (it
serves nothing there, so it would be a dead option), and a listener on a known
port with no explaining process **is** offered (that is what a containerised
service looks like). `127.0.0.1`-bound services are labelled 仅本机 and pinned
through the SSH channel, which runs the request on the box itself.

Pinned or hidden rows are explicit instructions: the cluster layer steps back and
does not rewrite them. The choice lives in `inferenceSource` in the config file
(`{"auto":{}}`, `{"pinned":{"_0":"http://…"}}`, `{"hidden":{}}`), so a config file
handed to someone else carries the decision with it.

## Interface: three tiers, and why

An information-dense monitor has one structural problem: whatever you put in the
first surface has to fit, and when it does not, the OS squeezes it — which is
exactly how text ends up overlapping. The fix is not smaller fonts, it is
**progressive disclosure** with an explicit capacity rule per tier, plus one surface
that has no capacity limit at all.

```
L0  menu bar      one line: dots/names + utilisation + tokens/s + ⚠   (always visible)
L1  popover       compact cards for what fits + one overflow row      (never scrolls)
L2  main window   sidebar + fleet pages + per-machine detail          (resizes, scrolls)
```

L2 is new. Before it, "everything" lived in a detail window that could only lay
machines out side by side; there was nowhere for anything that needs *time* (a
history curve, 24 h of energy, a token ledger, an event feed). The main window is
that place: a 248 pt sidebar indexing the fleet and the fleet-level pages, and a
card per machine on the overview.

**L1 popover — only what fits.** Each machine gets a fixed-shape card: identity +
health, an 88 pt **ring** for GPU utilisation, temperature / GPU power / fitted
whole-machine watts / hottest thermal zone beside it, the unified-memory
**breakdown**, a one-line `statline` of engine counters, and an action row
(详情 / 来源 / 关机). The field set is constant and every value is single-line, so
the height is known rather than hoped for: **302 pt per card**, and the popover
computes how many fit from the real screen (`NSScreen.visibleFrame`, not a constant).

Measured capacity and heights (renderer output, not arithmetic):

| available height | cards | rendered height | fits? |
| --- | --- | --- | --- |
| 780 (1440×900) | 2 | 758 pt | yes, 22 pt spare |
| 780 + a third machine | 2 + overflow row | 778 pt | yes, 2 pt spare |
| 1360 (2560×1440) | 3 | 1087 pt | yes |

Two things this table forced, both found by measuring rather than reasoning:
the overflow row had to become a single text line (a bordered/padded version pushed
the 3-machine popover to 792 pt, past its budget), and the card height is fixed at
302 pt because a card that grew with its data is what made text overlap in the first
place.

**L2 main window — everything.** ⌘K opens a command palette (jump to a page or a
machine, pause, refresh, cycle the theme). Pages: 概览 (fleet KPIs + a card per
machine), 能耗, Token 统计, 活动, 基准测试, plus a per-machine page. ⌘D from the
status-bar menu, and the popover's 主窗口 button.

### Column layout in the compare window

The *compare* window (status-bar menu → 并排对比窗口) is still the side-by-side
grid it always was: equal-width, centred columns, bounded at 560 pt, scrolling when
a fleet does not fit. It exists to compare N machines at one instant; the main
window exists to navigate them over time. Two windows, two jobs.

### Column layout: 1 / 2 / N machines

Columns are **equal width**, **centred as a group**, and **bounded** — in that
order of what people notice. Left-aligned columns with all the slack on the
right are what make a window feel "off", and equal widths are what make two
machines comparable at all.

| machines | window 1180 pt wide | what you get |
| --- | --- | --- |
| 1 | 1 column × 760 pt, centred | a lone machine gets a wider card (nothing has to line up beside it), still capped so text does not stretch |
| 2 | 2 × 560 pt, centred | fills the width; 560 is the cap, so a wide window adds symmetric margins instead of absurd line lengths |
| 5 | 2 columns visible, 3 scroll | as many equal columns as fit at ≥ 380 pt; the footer says "另有 3 台在右侧，横向滚动查看" |
| 12 | 2 visible, 10 scroll | same rule — the fleet accumulates in a scroll, never by shrinking cards |

The numbers come from `LayoutPolicy.detailLayout` (core, unit-tested), not from
the view: the view measures its own width and asks for a layout. Verified by
offscreen render at 1/2/5/12 machines — measured margins 0 px / 6 px off centre
for 1 and 2 columns — and by screenshotting the real window (1180×682, x = 130 on
a 1440 pt display, i.e. exactly centred).

**Verifying N without owning N.** `--demo-devices N` injects a synthetic fleet
covering every state the UI can be in (healthy, loaded, warning, critical,
unreachable, connecting, headless TP rank, no endpoint), and
`--preview`/`--preview-detail` render it offscreen:

```bash
SparkWatch --preview /tmp/pop12.png --demo-devices 12      # popover, 12 machines
SparkWatch --preview-detail /tmp/d8.png --demo-devices 8   # detail window, 8 machines
```

Rendered heights on a 1440×900 display, against an available 780 pt:

| machines | popover height | shown | overflow |
| --- | --- | --- | --- |
| 1 | 250 pt | 1 (full width) | — |
| 2 | 310 pt | 2 | — |
| 5 | 628 pt | 5 | — |
| 12 | 664 pt | 8 | +4 in the overflow row |

Layout checks are mechanical, not eyeballed: the renders are OCR'd and word
boxes are compared for **cross-line collisions** (boxes on different text lines
that intersect). Same-line box overlap is ignored — OCR splits CJK glyphs into
loose neighbouring boxes, and treating that as a defect produces nothing but
false alarms. All of the above render with zero cross-line collisions and no
clipped content.

## Themes, rings and colour

Four themes: `跟随系统` (default — follows the Mac's light/dark), `白色`,
`浅色`, `深色`, `纯黑 OLED`. Tokens and hex values come from the verified
reference projects (White `#F3F4F6/#FFFFFF`, Light `#DCE0E7/#FFFFFF`, Dark
`#0A0C0F/#12151A`, OLED `#000000/#0B0C0E`, amber accent `#E8A21C`/`#F0B03A`).
Under an explicit theme the popover and windows **paint their own background**
instead of using the system material — measured: the material follows the Mac's
appearance, which produced a half-themed surface ("dark card, light title bar").
Only `跟随系统` uses the native material.

A **ring** replaced the long bar as the per-machine headline metric:

- Geometry: full-circle track + foreground arc, `round` caps, starting at 12
  o'clock clockwise, `dashoffset = C×(1−v/100)`, centre text at `size×0.32`. It
  deliberately does **not** use a 270° open arc — that throws away a quarter of
  the arc's resolution, and "going all the way round" has no meaning anyway.
- Three sizes: popover 88/8, detail 140/11, two quantities side by side 88/8.
- **One number per ring**; anything else goes outside it — two numbers fighting
  over one ring is worse than two bars.
- Measured: for the same two machines, the ring layout came to 700 pt against
  734 pt for the old bar layout. A ring is not just prettier: it folds "label +
  bar + value" into one square.

**The colour rule: colour appears only when a rule fires**, never as a 0–100
gradient over the value.

| metric | colour |
| --- | --- |
| GPU utilisation | always the accent (amber) — utilisation is a *magnitude*, not a state; only a throttle or temperature rule escalates it |
| GPU temperature | <85 °C grey, 85–90 amber, ≥90 red (aligned with the health rules themselves) |
| Unified memory | <85 % blue, 85–90 % amber, ≥90 % red (the health rules add absolute-headroom and PSI criteria on top) |
| KV occupancy | <50 % green, 50–80 % amber, ≥80 % red |
| Throttle / kernel events | danger colour outright |

Painting 95 % utilisation red would put a false alarm on every machine doing its
job — a trap we hit on temperature first, and utilisation is exactly the same
shape.

## Per-machine detail: panels, not one big card

A card has to answer "what is it doing" within one screen, which is why the
popover is only 302 pt. A window has room for the next question — **why** — and
that means giving each subsystem its own panel so that things measured in the
same unit sit next to each other (two percentages side by side, two temperatures
side by side):

```
GPU（ring 140 + 温度/功耗/SM 时钟/降频 + 显存进程 top5）
统一内存（分账条 + 可用/页缓存/PSI/swap）
CPU（利用率/最热区/距上限 + 负载/运行时长）
LLM 服务（模型 + 解码/prefill + 指标瓦片 + 基准入口）
存储（用量条 + 实时 r/w） · 网络（各接口 rx/tx + 协商速率）
Tailnet（地址/路径/密钥） · 负载与内核事件（容器 + Xid/OOM/显存分配失败）
```

Two rules inherited from the popover are what make it read like an instrument
rather than a report:

1. **A tile the engine does not report is not rendered.** A permanently `--`
   tile translates "this engine has no such capability" into "this value is
   zero", and the second is what we refuse.
2. **Every metric uses its own threshold family**; temperature is never coloured
   on the utilisation scale.

## Engine latency percentiles

`TTFT mean / TTFT p95 / E2E p95 / ITL p95` come straight from the engine's own
Prometheus histograms, and the app **returns nothing rather than guessing** in
three situations:

- the engine does not export that histogram at all (TensorFold exports no ITL, so
  the tile disappears);
- the buckets do not agree with `_count` (a half-finished scrape — the reference
  implementation refuses to produce a number here too);
- the target falls in the `+Inf` bucket, i.e. outside the exported bounds. On
  this pair the request-latency p95 lands in that tail (so it returns nothing)
  while TTFT p95 lands cleanly at ≈31 s.

The relationship between the mean and p95 is itself information: this machine has
TTFT mean 36.6 s against p95 30.3 s — **the mean is above the p95**, which says a
few very long prefills are dragging the mean up. Reading the mean alone would
lead to the wrong conclusion.

## GPU history and the ledgers behind it

**The curve must translate, never "breathe".** The reported symptom — "every
refresh, every curve changes" — had three causes, all of them the same mistake of
sliding along with `now`, and none of them a visual problem:

| where | was | consequence |
| --- | --- | --- |
| `GpuHistory.binned` | `start = now - window` | bucket edges slid with every refresh → every bucket re-averaged |
| window / bucket width | `min(requested, available span × 1.1)` | the data grew a little every 2 s → the whole chart rescaled |
| ledger persistence | `lastSave = now` followed by `save()` checking `now - lastSave >= 30` | **never persisted** (only events and quit wrote) |

All three are fixed the same way: **pin the boundaries to absolute time, and let
the user's chosen range be the only thing that decides the width.**

- Bucket edges are anchored to a multiple of the bucket width
  (`ceil(now / width) × width`): byte-identical results within a bucket period,
  and crossing an edge shifts the entire curve **left by exactly one slot**.
- The bucket width follows only the requested span (30 min → 20 s, 1 h → 40 s,
  8 h → 320 s), and the window rounds up to whole buckets, so the geometry
  changes only when a bucket fills. This logic lives in `GpuChartScale` in Core as
  pure functions — buried in the view it could not be tested.
- Persistence is `save()`'s job alone; callers may not touch `lastSave`. Measured:
  zero writes in 75 s before the fix, 99 new points in 160 s after it (1–2 s
  apart, as designed).

**How it was verified** (screenshots are not evidence here: the curve is
self-similar, so shifting one slot and re-averaging look identical):

```bash
SparkWatch --print-chart --seconds 6 > a.txt   # dumps the 90 bucket values, not a picture
sleep 4
SparkWatch --print-chart --seconds 6 > b.txt
```

On the real pair, within a bucket period only the newest 1–3 slots grow (they are
being filled) and crossing an edge shifts everything one slot left — exactly the
intended behaviour. A regression test drives the clock at the 2 s refresh cadence
and asserts "identical within a period, shifted one slot on a crossing"; removing
the anchoring line turns it red immediately (every bucket moves one sample,
59.5 → 60.5).

**Two more fixes that came out of the same work:**

- `binned` used to filter the entire history once per bucket — 90 buckets × 8 h ≈
  1.7 M comparisons and 90 allocations, **on the main thread** (`sample` caught it
  on the main thread). A single accumulating pass took `%CPU` from 16.6 to 5.5.
- Command-line and preview instances now **read the ledger but never write it**:
  they used to load the shared file and write their own few seconds of history
  back, which flattened the real machine's persisted history down to a scatter of
  points.

**Bucket width follows the window; the bucket count does not.** A 30-minute window
cut into a fixed 200 buckets gives 9 s per cell, and this machine's utilisation is
effectively binary (95 % or 0 %, flipping every few seconds), so a 9 s mean is a
coin toss drawn as a sawtooth. At **~20 s per cell (90 buckets)** the same mean
becomes the *duty cycle* over that span — which is the question a 30-minute view
should answer. Narrower windows get finer buckets, so the shape always means
something instead of just getting noisier.

Three more rules:

- **The x axis scales to the actual history.** A fixed 30-minute window is
  honest, but for the first half hour two thirds of the canvas is empty and it
  looks broken. When there is less data than the requested window, it draws the
  real span and labels the title with "history starts X minutes ago".
- **Gaps stay gaps.** The ring buffer has a 1.5 s sampling floor, so an interval
  nobody observed is a hole, not a straight line.
- **Utilisation is drawn as a min–max envelope plus a mean line** (temperature and
  power behind it, thinner). The envelope shows the swing inside a bucket, the
  mean line shows where it sits; neither is smoothed.

One division of labour: **the sparkline on a card only answers "is it climbing
right now" (~1 minute), the curve answers history (30 minutes and up)**, and a
machine page draws only the curve — no two graphs of the same thing on one
screen.

### The ledgers behind the window pages

Four pure-logic ledgers, all **derived from samples already taken**, adding no
traffic to the machines:

| ledger | rule | kept |
| --- | --- | --- |
| `GpuHistory` | one point series per node, merged by **minGap time slot** (latest value in a slot wins) — *not* "replace the last point if it is too close", which leaves the curve with a single point forever | 8 hours |
| `EnergyLedger` | minute buckets integrating `Wh += W × Δt / 3_600_000`; watts = measured GPU rail + estimated CPU + 23 W peripheral floor, capped at 240 W; intervals >10 s are not integrated | 31 days |
| `TokenLedger` | per (node, port, model) differences of cumulative counters; a counter going backwards, jumping, or changing engine **re-baselines without recording**; cached ≤ prompt | 35 days |
| `EventLog` | only **state changes** (up/down, throttle on/off, health item appearing/clearing, kernel-count rises, model switch, shutdown, benchmark finished); de-duplicated per key for 5 s | 2000 entries |

Why "does not record" appears so often: an engine restart zeroes the counters, and
treating the difference as traffic invents a negative flow or an enormous spike.
The interface would rather be missing a number than have a wrong one.

## Probe interval and what the slow probe reads

设置 → 采集 exposes hardware sampling (1–10 s) and the slow probe (5–300 s);
before that it meant editing JSON by hand. The inference probe deliberately
**does not** follow that interval — it is 2 s while the box is working and 6 s when
quiet, because an idle counter has nothing new to say and every probe costs an SSH
round trip.

Hardware sampling stays at 2 s and the slow probe at 60 s by default, and the slow
probe carries everything the dashboard does not:

| added | source | note |
| --- | --- | --- |
| Disk read/write throughput | two `/sys/block/<dev>/stat` reads, 1 s apart inside one SSH call | fields 4 and 8 are the sector counts; taking the wrong field reads the merge counter forever (hit once, caught by a fixture test) |
| Network rx/tx | two `/proc/net/dev` reads + `/sys/class/net/*/speed` | physical interfaces only; counting virtual ones double-books the same traffic |
| Top-5 GPU-memory processes | `nvidia-smi --query-compute-apps` | under unified memory, the only source that answers "who is using the pool" |
| Unified memory accounting (GPU / system / free) | sum of compute-apps + MemAvailable | e.g. 71 % model + 17 % system + 12 % free (of the pool) |
| Throttle reasons + SM clock/limit + power limit | `clocks_throttle_reasons.*` and friends | driver versions spell them differently (`Active` / `0x…` / integer / `[N/A]`) — all four are parsed |
| Kernel event counts | Xid, OOM-kill, `NV_ERR_NO_MEMORY` from `dmesg`/`journalctl -k` | **rises only**, held for an hour; the "since boot" absolute count is not an alert |
| Tailnet state | the node's own `tailscale status --json` | the node speaks for itself; it is not inferred from this Mac's peer list |

On the boxes this was built against, the two nodes reach each other through a
relay rather than directly, and both take their default route over WiFi. Both had
accumulated dozens of boot-time OOM-kills and `NV_ERR_NO_MEMORY` events — one of
which had killed the inference server itself. That is exactly the history a
"current values" panel cannot show.

## Graceful shutdown

Exactly one thing changes state on a remote machine: a **graceful shutdown**.
Three conditions must hold at once —

1. **Capability probe**: the target has systemd **and** passwordless sudo
   (true on both boxes here; if not, the action is disabled and says why —
   otherwise sudo sits on a password prompt nobody can answer);
2. **Type `poweroff` by hand**: a mis-click is an action, typing is not;
3. **An explicit checkbox**, because the consequence is invisible from the
   outside — DGX Spark has **no wake-on-LAN** (every physical NIC reports
   `wakeup = disabled`), so a machine shut down from here has to be powered on by
   hand.

The confirmation sheet also lists **what is running right now** (inference
requests and KV, containers, processes holding GPU memory), so the decision is
made from the current state rather than an impression.

## Verification without a machine in front of you

### Command-line inspection

```bash
./dist/SparkWatch.app/Contents/MacOS/SparkWatch --preview out.png --seconds 25
./dist/SparkWatch.app/Contents/MacOS/SparkWatch --preview-main out.png --page energy --seconds 60
./dist/SparkWatch.app/Contents/MacOS/SparkWatch --preview-main out.png --page tokens --demo-devices 5
```

- `--preview` / `--preview-main` / `--preview-detail` / `--preview-settings`:
  offscreen render, no GUI session needed
- `--page overview|machine|energy|tokens|activity|benchmarks`: pick a main-window page
- `--theme white|light|dark|oled|system`: render all four themes to compare
- `--available-height 780`: pretend the screen is 780 pt tall, to verify the
  popover's capacity rule
- `--seconds N`: force a real sampling window (energy and history integrate over
  time, so a sub-second render can only be zero)
- `--preview` prints "capacity=N shown=M of K" plus the real rendered height;
  `--preview-main` prints the slow channel's raw facts (memory accounting,
  throughput, throttling, kernel counts, tailnet path)

### Reconciliation: dashboard versus independently read values

The headless probe reads both implementations and exits non-zero if anything
drifts beyond tolerance:

```bash
DGX_PW_00=… DGX_PW_01=… swift run sparkwatch-probe -- --seconds 20
```

```
══ 对账结果 ══
  ok   0.000% (容差 0.050%)  [dash] dash 130.66GB vs meminfo 130.66GB
  ok   0.000 (容差 2.000)  dash 42°C vs nvidia-smi 42°C
PASS · 20 项检查全部在容差内
```

### The decode benchmark, against a server with a known answer

The benchmark is the only feature that **sends work to a machine**, and a fleet
engine is usually carrying real traffic — so it ships with its own mock:

```bash
python3 Scripts/mock-openai-sse.py --port 18123 --tokens 100 --interval 0.02   # a server with a known answer
SparkWatch --bench http://127.0.0.1:18123 --concurrency 1,2,4 --max-tokens 100
```

Measured (client side versus the server's own report):

| concurrency | client total throughput | client per-stream mean | server's own report | first token |
| --- | --- | --- | --- | --- |
| 1 | 41.4 tok/s | 42.8 | 41.3–42.6 | 54 ms |
| 2 | 81.6 | 42.4 | 42.1 | 56 ms |
| 4 | 164.5 | 43.1 | 41.9–42.6 | 69 ms |

**The point is that the client's number agrees with what the server actually
did** — not with the 50 tok/s the mock was asked for (each chunk costs it ~3 ms, so
the server's own 41.3 is the truth). The benchmark does not flatter itself, and
concurrency scales close to linearly.

## Traps worth knowing

* **Orphaned tunnels.** An abandoned `ssh -L` keeps the port bound: the next
  process's forward dies on `ExitOnForwardFailure` while the port still answers —
  everything looks healthy and nobody owns it. Tunnels now write a pidfile and
  the next start reclaims it.
* **Node IDs must be stable.** They key the stored sessions; regenerating a UUID
  per launch silently logs every node out.
* **App Transport Security** refuses plain-HTTP tailnet endpoints with
  `NSURLErrorDomain -1022`; the bundle declares an ATS exception.
* **System proxies** (FlClash) route `100.x` into the proxy while `curl` keeps
  working. All requests use a session with proxies disabled.
* **SSE framing** is byte-level: a stream can stop delivering without closing, so
  silence — not an error — is the only signal. An idle watchdog reconnects.
* **Sign-in before the tunnel is up** looks exactly like bad credentials; login
  waits for the dashboard to answer first.

### One instance only (two status items)

A menu-bar app running twice means **two status items**, each rendering the whole
readout — the same line twice, which looks like two devices fighting for space and
doubles the width. The root cause was not layout:

```
11280  ppid=1  com.yingzi.sparkwatch                       ← started by the LaunchAgent
11283  ppid=1  application.com.yingzi.sparkwatch.220739…   ← started again by `open`
```

`install.sh` ran `launchctl load` (whose `RunAtLoad` starts the app immediately)
and then `open`; the second copy starts under LaunchServices' job label, and macOS
does not consider them the same app instance. Both ends need fixing:

1. **At install time**: after `launchctl load`, check whether the process is
   already running; if so skip `open` (and count instances, warning if >1).
2. **In the app itself** (at the top of `applicationDidFinishLaunching`): if
   another instance of the same bundle with a **lower PID** exists, quit. It lives
   there because only that covers every path (login item, `open`, double-click in
   Finder); "lowest PID wins" means two simultaneous launches cannot talk each
   other out of quitting — exactly one survives.

## Source layout

```
Sources/SparkWatchCore/     data layer: tunnels, dashboard API, Prometheus, SSH,
                            health rules, ledgers (GPU history / energy / tokens /
                            events), cluster topology, layout capacity policy
Sources/SparkWatchApp/      the menu-bar app: popover (compact tier), main window
                            and pages, compare window, settings, charts, DemoData
Sources/SparkWatchProbe/    headless acceptance + reconciliation probe
Tests/SparkWatchCoreTests/  214 tests, written against real captures from both boxes
Scripts/build-app.sh        release build → .app bundle → ad-hoc sign
Scripts/install.sh          install / uninstall / login item
Scripts/mock-*.py           mock engines (OpenAI SSE, TensorFold) with known answers
```

MIT licensed. See `THIRD_PARTY_NOTICES.md` for the code and thresholds borrowed
from other projects.
