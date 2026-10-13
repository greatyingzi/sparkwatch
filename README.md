# SparkWatch

A macOS menu-bar monitor for a small cluster of NVIDIA DGX Spark (GB10) boxes:
what the hardware is doing **and** what the models on it are doing, in one line.

Built because every existing option does half the job — see "Why this exists".

```
DGX 2/2 · 00 95% 45° ▶28/s · 01 0% 54°
```

Click it for the full per-node readout: GPU utilisation / temperature / power,
**aggregate CPU utilisation and the hottest thermal zone**, unified memory, page
cache, PSI memory pressure, disk, running containers, and the model being served
with its decode speed.

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

- **整机≈功耗 — estimated, and labelled as such.** Solved from two wall-meter
  anchors of a single Spark, `wall = 12 W + 2.20 × gpu`:

  | state | GPU rail | wall | source |
  | --- | --- | --- | --- |
  | idle, no model | 11.8 W | 38 W | Kill-a-Watt (community) |
  | generating | 47.7 W | 117 W | Shelly, two-node pair = 234 W / 2 |

  Both anchors are reproduced by the shipped defaults, and the app prints `≈`
  (and shows `--` when the GPU rail itself is unknown, rather than inventing a
  number). Expect ±20 %: it keys on the GPU rail alone, so a CPU-bound box with an
  idle GPU will read low. Both coefficients are editable in 设置 → 功耗 — correct
  them there once you put a metering plug in front of the machine.

  For scale, community wall measurements of one Spark: idle 25–45 W, single
  inference burst 125–170 W, CPU-only full load 120–130 W, two-node uncapped
  ~330 W vs ~234 W clock-capped at 1400 MHz. (The clock cap is worth knowing: it
  costs ~3 % decode speed and saves ~90–100 W across a pair.)

On the CPU numbers, honestly: GB10 exposes **no CPU package temperature sensor**.
The card therefore shows the hottest ACPI thermal zone (`/sys/class/thermal`) and
labels it 最热区 rather than pretending it is a CPU package reading. CPU
*utilisation* is real: two `/proc/stat` reads one second apart inside the same
SSH call, since the probe is stateless. (For reference, the box's other thermal
sources are the NVMe SSD at ~41-44 °C and the ConnectX-7 ASIC at ~48 °C.)

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

## Build and run

```bash
swift test                          # 16 unit tests
swift run sparkwatch-probe -- --seconds 20   # headless acceptance + reconciliation
./Scripts/build-app.sh              # dist/SparkWatch.app, ad-hoc signed
open dist/SparkWatch.app
```

First launch: the app starts on the SSH channel and offers **登录 <node>…** in the
menu. Sign in with the box's system account (the same credentials as the DGX
Dashboard web UI). The password is never stored; the 14-day token is.

Inspect the UI without a GUI session (or feed it to a design review):

```bash
./dist/SparkWatch.app/Contents/MacOS/SparkWatch --preview /tmp/ui.png --seconds 25
```

It renders the popover offscreen with live data. A transient popover closes
before `screencapture` can catch it, so this is the reliable way to look at it.

Optional but recommended — run the acceptance probe once so both implementations
are cross-checked:

```bash
DGX_PW_00=… DGX_PW_01=… swift run sparkwatch-probe -- --seconds 20
```

It reconciles the dashboard against independently read values and exits non-zero
if anything drifts beyond tolerance:

```
══ 对账结果 ══
  ok   0.000% (容差 0.050%)  [dash] dash 130.66GB vs meminfo 130.66GB
  ok   0.000 (容差 2.000)  dash 42°C vs nvidia-smi 42°C
PASS · 20 项检查全部在容差内
```

## Install

```bash
./Scripts/install.sh              # build → /Applications → clear quarantine → register → launch
./Scripts/install.sh --uninstall  # remove app + login item (add --purge to drop config too)
```

What that gives you, as a normal Mac app rather than a script in a repo:

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

## Multi-machine tasks (并行推理)

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

## Showing fast, hiding slow: the display is deliberately asymmetric

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

## Decode speed: how it is measured, and what "stopped" looks like

The rate is a **counter delta**: the engine's `completion_tokens_total` is read on
every probe (~5 s), and tok/s is the growth divided by the elapsed time. Nothing is
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

## The deployment banner's one live slot

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

## Power display: a windowed mean, because the raw number is unreadable

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

## Health rules (and why they are graded the way they are)

Thresholds are taken from `joeynyc/spark-doctor` (MIT) — field-reported DGX Spark
behaviour rather than desk guesses — but the severities are re-graded where
unified memory makes the original reading misleading.

| level | fires when |
| --- | --- |
| **异常** (critical, ⚠) | node unreachable (both channels down) · GPU ≥ 90 °C · ACPI zone within **6 °C of the platform's declared limit** (104 °C here) · memory PSI `full avg10` > 0.25 · MemAvailable < 2 GB · MemAvailable < 8 GB **with** PSI > 0.25 · GPU busy ≥ 80 % **while drawing ≤ 25 W and the SM clock has collapsed to ≤ 800 MHz** for 3 consecutive samples (the documented low-power wedge) |
| **注意** (warning) | GPU 85–90 °C · ACPI zone within 12 °C of the limit · PSI 0.10–0.25 · MemAvailable 8–16 GB · MemAvailable < 8 GB with PSI ≤ 0.25 (a resident model parking the floor — normal) · swap used > 8 GB · 1–2 low-draw samples · slow-channel error |
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

## Status bar

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

## 主题、环形表与配色（照参考项目的语言，值逐位相同）

四套主题：`跟随系统`（默认，随 Mac 的浅/深色走）、`白色`、`浅色`、`深色`、`纯黑 OLED`。
令牌与 hex 取自已核对的参考项目（White `#F3F4F6/#FFFFFF`、Light `#DCE0E7/#FFFFFF`、
Dark `#0A0C0F/#12151A`、OLED `#000000/#0B0C0E`，琥珀强调色 `#E8A21C`/`#F0B03A`）。
显式主题下 popover 与窗口**自己刷底色**，不用系统 material —— 实测过 material 会跟着
Mac 的浅深色走，于是出现「深色卡片 + 浅色标题栏」的半截主题；`跟随系统`才用原生 material。

**环形表**（`Ring`）替代了长条作为每机主指标：

- 几何：底轨整圆 + 前景弧、`round` 端点、12 点起顺时针、`dashoffset = C×(1−v/100)`，
  环心字号 = `size×0.32`。**不做** 270° 开口弧（白扔 1/4 弧长分辨率，且「转满一圈」
  本身没有语义）。
- 尺寸三档：popover 88/8、详情 140/11、并排两个量时 88/8。
- **一个环只放一个数**，其余的量放环外 —— 两个数抢一个环比两条长条更差。
- 实测：同样 2 台机器，环形布局 700 pt、长条布局 734 pt（旧实现）。环不只是好看，
  它把「标签 + 条 + 数值」三个角色折进同一个方块。

**配色铁律**：颜色只在**规则触发**时出现，不套 0–100 色阶。

| 指标 | 色阶 |
| --- | --- |
| GPU 利用率 | 一直是强调色（琥珀）——利用率是**量级**不是状态；只有降频或温度规则触发才升级 |
| GPU 温度 | <85 °C 灰、85–90 黄、≥90 红（对齐 Health 规则本身） |
| 统一内存 | <85% 蓝、85–90% 黄、≥90% 红（健康规则另有绝对余量与 PSI 判据） |
| KV 占用 | <50% 绿、50–80% 黄、≥80% 红 |
| 降频/内核事件 | 直接危险色 |

把 95% 利用率画成红色，等于给每一台正常干活的机器挂一个假警报 —— 这是我们自己在
温度上踩过的坑，利用率同理。

## 每机详情页：分面板，而不是一张大卡

一张卡要在一屏里回答「它在干什么」，所以 popover 只有 302 pt。窗口有地方回答下一个问题——**为什么**——
那需要把部件分到各自的面板里，让相同单位的东西彼此相邻（两个百分数并排、两个温度并排）：

```
GPU（环 140 + 温度/功耗/SM 时钟/降频 + 显存进程 top5）
统一内存（分账条 + 可用/页缓存/PSI/swap）
CPU（利用率/最热区/距上限 + 负载/运行时长）
LLM 服务（模型 + 解码/prefill + 指标瓦片 + 基准入口）
存储（用量条 + 实时 r/w） · 网络（各接口 rx/tx + 协商速率）
Tailnet（地址/路径/密钥） · 负载与内核事件（容器 + Xid/OOM/显存分配失败）
```

两条从 popover 继承的规矩，是它读起来像仪表而不是像报表的原因：

1. **引擎没报的瓦片不渲染**。一个恒显 `--` 的瓦片会把「这台引擎没有这个能力」翻译成「这个值是零」，
   而我们拒绝的正是后者。
2. **每个指标用自己的阈值族**，温度永远不套利用率的色阶。

## 引擎延迟分位（引擎自己导出的直方图）

`TTFT 均值 / TTFT p95 / E2E p95 / ITL p95` 直接来自引擎的 Prometheus 直方图，**在三个说不上来的地方返回空而不是猜**：

- 引擎根本没导出这条直方图（TensorFold 不导出 ITL → 瓦片消失）；
- 桶与 `_count` 对不上（半截抓取，参考实现同样拒绝出数）；
- 目标落在 `+Inf` 桶里 —— 导出的边界框不住它。实测这对机器上 request-latency 的 p95 就落在尾巴里（返回空），
  而 TTFT p95 干净地落在 ≈31 秒。

均值与 p95 的关系本身就是信息：这台机器 TTFT 均值 36.6 s 而 p95 30.3 s —— **均值高于 p95**，
说明少数超长 prefill 把均值拽上去了，只看均值会得出错误结论。

## decode 基准：怎么在没有真机的情况下验算

基准是整个 app 里唯一**向机器发任务**的功能，而机队引擎通常在跑真实流量。所以它有两件配套：

```bash
python3 Scripts/mock-openai-sse.py --port 18123 --tokens 100 --interval 0.02   # 已知答案的服务器
SparkWatch --bench http://127.0.0.1:18123 --concurrency 1,2,4 --max-tokens 100
```

实测（客户端 vs 服务端自报）：

| 并发 | 客户端合计吞吐 | 客户端单流均值 | 服务端自报单流 | 首 token |
| --- | --- | --- | --- | --- |
| 1 | 41.4 tok/s | 42.8 | 41.3–42.6 | 54 ms |
| 2 | 81.6 | 42.4 | 42.1 | 56 ms |
| 4 | 164.5 | 43.1 | 41.9–42.6 | 69 ms |

**关键是客户端报的数与「服务器实际做到的」对得上**（不是我设的 50 tok/s：mock 每块多花 ~3 ms，
服务端自报 41.3 才是真值）。基准测量没注水，并发也近线性扩展。

## 采集频率可以在界面里改

设置 → 采集：硬件采样（1–10 秒）、慢探针（5–300 秒）。以前只能手改 JSON。
推理探测**不跟**这个间隔：忙 2 秒、闲 6 秒 —— 闲时计数器不动，探了也是白探。

## 菜单栏只能有一个实例（踩过的坑）

菜单栏应用跑两份 = **两个状态栏项**，而每一项都渲染整条读数 —— 于是同一行显示两遍，
看起来像"桌面上有两个设备在各自占位"，宽度翻倍。实测根因不在布局：

```
11280  ppid=1  com.yingzi.sparkwatch                       ← LaunchAgent 启动
11283  ppid=1  application.com.yingzi.sparkwatch.220739…   ← open 又启动了一个
```

`install.sh` 先 `launchctl load`（`RunAtLoad` 会立刻拉起 app）再 `open`，第二个副本以
LaunchServices 的 job 标签起来，macOS 不认为它们是同一个"应用实例"。

两处都修，缺一不可：

1. **装的时候**：`launchctl load` 之后检查进程是否已在跑，在跑就跳过 `open`（并统计实例数，>1 直接告警）。
2. **应用自己**（`applicationDidFinishLaunching` 开头）：发现**有更低 PID 的同 bundle 实例**就自己退出。
   放在这里是因为只有它能覆盖所有路径（开机项、`open`、Finder 里双击）；判据用"低 PID 胜"，这样两份
   同时启动也不可能互相说服对方退出 —— 恰好活一个。

## GPU 历史曲线（机器页）

**曲线必须平移，不能"呼吸"。** 用户报的「每次刷新，所有曲线都在变」有三个来源，全部是
"跟着 `now` 连续滑动"造成的；三处都不是视觉问题：

| 位置 | 原来 | 后果 |
| --- | --- | --- |
| `GpuHistory.binned` | `start = now - window` | 桶边界随刷新滑动 → 每个桶重新平均 |
| 窗口/桶宽 | `min(请求, 可用跨度 × 1.1)` | 数据每 2 秒长一点 → 整图重新缩放 |
| 账本落盘 | `lastSave = now` 后又让 `save()` 检查 `now - lastSave >= 30` | **永远不落盘**（只有事件/退出才写） |

三处的修法是同一条：**把边界钉在绝对时间上，且只由用户选的那一档决定。**

- 桶边界锚到桶宽的整数倍（`ceil(now / width) × width`）：一个桶周期内结果逐字节相同，
  跨过边界时整条曲线**左移正好一格**。
- 桶宽只由请求跨度决定（30 min → 20 s，1 h → 40 s，8 h → 320 s），窗口按**整桶**向上取整，
  于是几何只在"又攒满一个桶"时变一次。这段逻辑抽到 Core 的 `GpuChartScale` 纯函数里，
  因为埋在视图里就没法测。
- 落盘交给 `save()` 一家管，调用方不许提前改 `lastSave`。实测修复前 75 秒零写入，修复后
  160 秒新增 99 个点（间隔 1–2 秒，与设计一致）。

**怎么验的**（截图不可靠：这条曲线自相似，平移一格和重新平均长得一样）：

```bash
SparkWatch --print-chart --seconds 6 > a.txt   # 转储 90 个桶的值，不是图片
sleep 4
SparkWatch --print-chart --seconds 6 > b.txt
```

真机输出：同一桶周期内只有最新那 1–3 格在长（正在填充），跨边界时整体左移一格 —— 正是要的行为。
另有回归测试按 2 秒的刷新节奏走时钟，断言"周期内逐元素相同、跨边界左移一格"；
把锚定那一行撤掉，它立刻变红（每个桶都挪了一个样本，59.5 → 60.5）。

**顺带修掉的两件**：

- `binned` 原本"每个桶都对整段历史 filter 一次"= 90 桶 × 8 小时 ≈ 170 万次比较加 90 次分配，
  而且跑在**主线程**上（`sample` 抓到它压在 main thread）。改单趟累积后 `%CPU` 由 16.6 降到 5.5。
- 命令行/预览实例**只读不写**账本：它们以前会加载共享文件、把自己那几秒的历史写回去，
  真机的持久化历史因此被冲得只剩零星几点。

**桶宽随窗口走，不固定桶数。** 30 分钟窗口若固定切 200 个桶，每格只有 9 秒；这台机器的利用率
实际是二值的（95% 或 0%，每几秒翻一次），9 秒桶的均值像抛硬币，画出来是锯齿。改成
**每格约 20 秒（90 桶）**后，同一个均值变成那一段的**占空比**——这才是 30 分钟视图该回答的问题。
窗口越窄桶越细，形状始终有意义而不是只是更吵。

另外三条：
- **x 轴按实际历史缩放**。固定 30 分钟窗口是诚实的，但刚启动的半小时里三分之二画布是空的，
  看着像坏了。数据不足请求窗口时按实际跨度画，并在标题上标「历史起点 X 分钟前」。
- **断口留空不连线**。环形缓冲有 1.5 秒采样下限，没观测到的时段是洞，不是直线。
- **利用率画 min–max 包络 + 均值线**（温度/功耗在后、更细）。包络用来表示桶内的摆动，
  均值线表示它落在哪；两者都不做平滑。

还有一条分工：**卡片上的 sparkline 只管「此刻是否在爬坡」（约 1 分钟），曲线管历史（30 分钟起）**，
机器页只画曲线，避免同一屏出现两张同义图。

## 时间序列账本（窗口层的数据来源）
四个纯逻辑账本，全部**只从已有采样派生**，不给机器增加任何流量：

| 账本 | 口径 | 保留 |
| --- | --- | --- |
| `GpuHistory` | 每个节点一条点序列，按 **minGap 时间槽**归并（同一槽取最新值）——不是「和上一个点比太近就替换」，后者会让曲线永远只剩一个点 | 8 小时 |
| `EnergyLedger` | 分钟桶积分 `Wh += W × Δt / 3_600_000`；瓦数 = GPU 轨实测 + CPU 估算 + 23 W 外设底，上限 240 W；间隔 >10 s 不积分 | 31 天 |
| `TokenLedger` | 按 (节点, 端口, 模型) 差分累计计数器；倒退/跳变/换引擎一律**只重新取基线不记账**；cached ≤ prompt | 35 天 |
| `EventLog` | 只记**状态变化**（上线/下线、降频与解除、健康项出现与清除、内核事件上升、模型切换、关机、基准完成）；同键 5 s 去重 | 2000 条 |

为什么这些都强调「不记账」：一次引擎重启会让计数器归零，把差值当成流量会凭空造出
一次负流量或一次巨大的假尖峰。界面宁可少一个数，也不能多一个错的。

## 动作面（唯一能改变远端状态的部分）

只有一件事：**优雅关机**。三条件同时满足才放行 ——

1. **能力探测**：目标机有 systemd **且** 免密 sudo（实测两台都满足；没有就禁用并说明原因，
   否则 sudo 会挂在一个没人能回答的密码提示上）；
2. **手打 `poweroff`**：一次误点是一个动作，打字不是；
3. **显式勾选**：因为后果从外面看不出来 —— DGX Spark **没有网络唤醒**
   （每个物理网卡 `wakeup = disabled`），从这里关掉的机器必须到跟前手动开机。

确认页还会列出**此刻**在跑什么（推理请求数与 KV、容器、占显存的进程），让决定基于
当前状态而不是印象。

## 采集频率与新增字段

频率不变（硬件 2 s、慢探针 60 s、推理探测忙 2 s/闲 6 s），但慢探针里加了：

| 新增 | 来源 | 说明 |
| --- | --- | --- |
| 磁盘读/写吞吐 | 两次 `/sys/block/<dev>/stat` 差分（同一次 SSH 内 1 s） | 字段 4 与 8 是扇区数，取错会永远读到 merge 计数（踩过，靠 fixture 测试抓到） |
| 网络 rx/tx | 两次 `/proc/net/dev` 差分 + `/sys/class/net/*/speed` | 只算物理网卡，虚拟网卡会把同一份流量算两遍 |
| GPU 显存进程 top-5 | `nvidia-smi --query-compute-apps` | 统一内存下唯一能回答「谁占了池」的来源 |
| 统一内存 GPU/系统/空闲 分账 | compute-apps 求和 + MemAvailable | 例：模型 71 % + 系统 17 % + 空闲 12 %（以池为分母） |
| 降频原因 + SM 时钟/上限 + 功耗上限 | `clocks_throttle_reasons.*` 等 | 驱动版本拼写不同（`Active`/`0x…`/整数/`[N/A]`），四种都吃 |
| 内核事件计数 | `dmesg`/`journalctl -k` 的 Xid、OOM-kill、NV_ERR_NO_MEMORY | **只记上升**，并驻留 1 小时；「开机以来」的绝对数不是告警 |
| Tailnet 状态 | 节点自报 `tailscale status --json` | 由节点自己说，不从这台 Mac 的 peer 列表推断 |

On the boxes this was built against, the two nodes reach each other through a
relay rather than directly, and both take their default route over WiFi. Both had
accumulated dozens of boot-time OOM-kills and `NV_ERR_NO_MEMORY` events — one of
which had killed the inference server itself. That is exactly the history a
"current values" panel cannot show.

## 命令行验证通道

```bash
./dist/SparkWatch.app/Contents/MacOS/SparkWatch --preview out.png --seconds 25
./dist/SparkWatch.app/Contents/MacOS/SparkWatch --preview-main out.png --page energy --seconds 60
./dist/SparkWatch.app/Contents/MacOS/SparkWatch --preview-main out.png --page tokens --demo-devices 5
```

- `--preview` / `--preview-main` / `--preview-detail` / `--preview-settings`：离屏渲染，免 GUI 会话
- `--page overview|machine|energy|tokens|activity|benchmarks`：选主窗口页面
- `--theme white|light|dark|oled|system`：四套主题都能渲染出来对比
- `--available-height 780`：假装屏幕可用高度，用来验证 popover 容量规则
- `--seconds N`：强制一段真实采集窗口（能耗与历史是按时间积分的，秒级渲染只能是 0）
- `--preview` 会打印「容量=N 台 显示=M 共 K 台」与真实渲染高度；`--preview-main` 会打印
  慢通道的原始事实（分账/吞吐/降频/内核计数/tailnet 路径）

## Adding a machine

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

## Configuration file (optional)

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

## Traps worth knowing (all found the hard way)

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

## Layout

```
Sources/SparkWatchCore/     data layer: tunnels, dashboard API, Prometheus, SSH,
                            health rules, layout capacity policy
Sources/SparkWatchApp/      the menu-bar app: popover (compact tier),
                            DetailWindow (full tier), DemoData (synthetic fleets)
Sources/SparkWatchProbe/    headless acceptance + reconciliation probe
Tests/SparkWatchCoreTests/  53 tests, written against real captures from both boxes
Scripts/build-app.sh        release build → .app bundle → ad-hoc sign
```

MIT licensed. See `THIRD_PARTY_NOTICES.md` for the code and thresholds borrowed
from other projects.
