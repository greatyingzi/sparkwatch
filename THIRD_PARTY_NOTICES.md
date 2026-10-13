# Third-party notices

SparkWatch is MIT licensed, but it deliberately borrows from people who worked
this problem out first. What came from where:

## Code incorporated

### amer8/pulsebar — MIT, © 2026 Amer Alimanović
https://github.com/amer8/pulsebar

The overall approach to the official DGX Dashboard channel (sign in to the local
dashboard, consume the GPU telemetry stream, show RAM + GPU in a menu-bar item)
informed this project's dashboard client. No files were copied verbatim; the API
shape it depends on is the same, and its single-host / `_in_mb`-only limits are
what SparkWatch exists to fix.

### AdrianBinDC/DGXPulse — MIT, © 2026 Adrian Bolinger
https://github.com/AdrianBinDC/DGXPulse

Adapted:
* `Sources/SparkWatchCore/DashboardClient.swift` — SSE byte-level framing
  (CR/LF handling, `event:`/`data:` fields, comment lines) and the stream idle
  watchdog, from `DGXPulse/Services/DashboardSSEMetricsSource.swift`.
* `Sources/SparkWatchCore/Tunnel.swift` — `ReconnectBackoff` and
  `TokenRedactor`, from `DGXPulse/Support/ReconnectBackoff.swift`.
* The session pattern (token stored once, password never stored, username
  separate) follows `DGXPulse/Services/KeychainSessionStore.swift` — with the
  store swapped from the Keychain to an owner-only file, because an ad-hoc
  signed build cannot satisfy a Keychain ACL without prompting on every access.

### btoro/SparkTPS — MIT, © 2026 SparkTPS contributors
https://github.com/btoro/SparkTPS

Adapted: `Sources/SparkWatchCore/Prometheus.swift` is derived from
`SparkTPSCore/PrometheusParser.swift` — the vLLM/SGLang metric surface, summing
values across label sets, and the `model_name` label extraction. Trimmed to what
a menu bar needs, mapped onto this project's `InferenceSample`, and extended with
an explicit counter-delta rate tracker.

## Thresholds and domain rules

### joeynyc/spark-doctor — MIT, © 2026
https://github.com/joeynyc/spark-doctor

`Sources/SparkWatchCore/Health.swift` implements thresholds taken from
spark-doctor's rules, which are drawn from reported DGX Spark field behaviour:

* `rules/memory.py` — MemAvailable < 8 GB critical / < 16 GB warning,
  MemAvailable/MemTotal < 0.15 warning, PSI memory `full avg10` > 0.25 critical /
  > 0.10 warning, swap used > 8 GB warning.
* `rules/power.py` — util ≥ 80 % while power ≤ 25 W as a possible low-power
  state, sustained (≥ 3 samples) escalating to critical; SM clock ≤ 800 MHz
  raising confidence.
* `rules/thermal.py` — max temperature ≥ 85 °C warning, ≥ 90 °C critical.

### leplik/dgx-spark-bar — concepts only, no code
https://github.com/leplik/dgx-spark-bar

Its documented reasoning shaped this project's GB10 handling: show unified memory
as shared with the GPU rather than as fake VRAM, read "it did not fit" from PSI
memory pressure rather than a framebuffer, and treat a busy GPU drawing ~14 W as
a wedge worth surfacing. That project ships under a non-standard licence, so
**no code was taken from it** — only the design conclusions, which are not
copyrightable.

## Referenced, not incorporated

NVIDIA's DGX Dashboard (`/opt/nvidia/dgx-dashboard-service/dashboard-service`)
was inspected locally to determine the undocumented API contract
(`/api/login`, `/api/v1/gpu_telemetry/stream`, `/api/v1/hostname`). No NVIDIA
code, assets, or documentation text is included here.
