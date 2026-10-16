#!/bin/bash
# 恢复 SparkWatch "过期 token → 死循环自旋" 现场 (2026-10-16 事故)。
#
# 背景: sessions.json 里的 DGX Dashboard JWT 于 2026-10-14T05:06:01Z 过期,
#       但 Collector.hardwareLoop 的凭据守卫里 `if token != nil { break }` 会
#       因"非 nil 但已过期"立刻跳出, 整轮没有任何 await → 单核死循环,
#       NodeRuntime actor 被独占, 连不需要 token 的 SSH slowLoop 一起饿死。
#       同时 pidfile 被每轮失败的 ssh 重写, 孤儿隧道(10:47 起)占死
#       127.0.0.1:19100/19101, 重启也绑不上端口。
#
# 本脚本只做"现场恢复": 停 app → 备份并清掉过期 token → 杀 19100/19101 孤儿隧道 → 重启。
# 恢复后走 SSH 兜底通道(nvidia-smi + /proc/meminfo)立刻有硬件数据;
# 官方通道(实时速度/prefill/缓存)需要在设置窗重新登录 Dashboard 账号(密码从不落盘)。
#
# 回退法: 把 sessions.json.bak-<时间戳> 覆盖回 sessions.json, 再重启 app
#         (token 已过期, 回退只会让死循环复发; 仅用于取证对比)
# 注意: 不要碰其它 ssh 隧道(如 -L 127.0.0.1:9298:192.168.1.6:9200 的 hermes 星云隧道),
#       匹配串写死了 :1910x:localhost:11000。
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/SparkWatch"
SESSIONS="$SUPPORT/sessions.json"
APP="/Applications/SparkWatch.app"
BUNDLE_ID="com.yingzi.sparkwatch"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "== 1/5 备份 sessions.json"
cp -p "$SESSIONS" "$SESSIONS.bak-$STAMP"
echo "   $SESSIONS.bak-$STAMP"

echo "== 2/5 退出 SparkWatch"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 10); do
  pgrep -f "$APP/Contents/MacOS/SparkWatch" >/dev/null || break
  sleep 1
done
pkill -TERM -f "$APP/Contents/MacOS/SparkWatch" 2>/dev/null || true
sleep 2
pkill -KILL -f "$APP/Contents/MacOS/SparkWatch" 2>/dev/null || true
echo "   残留: $(pgrep -f "$APP/Contents/MacOS/SparkWatch" | wc -l | tr -d ' ') 个"

echo "== 3/5 清掉过期 token (空字典, 用户名等仍走 UserDefaults)"
python3 - "$SESSIONS" <<'PY'
import json, sys
p = sys.argv[1]
try:
    json.load(open(p))
except Exception:
    pass
json.dump({}, open(p, "w"), separators=(",", ":"))
PY
os_chmod() { chmod 600 "$SESSIONS"; }
os_chmod
cat "$SESSIONS"; echo

echo "== 4/5 杀 19100/19101 孤儿隧道 (只杀本 app 的 11000 转发)"
for port in 19100 19101; do
  pids=$(pgrep -f -- "-L 127.0.0.1:$port:localhost:11000" || true)
  if [ -n "$pids" ]; then
    echo "   $port -> $pids"
    kill -TERM $pids 2>/dev/null || true
  fi
done
sleep 1
for port in 19100 19101; do
  pids=$(pgrep -f -- "-L 127.0.0.1:$port:localhost:11000" || true)
  [ -n "$pids" ] && kill -KILL $pids 2>/dev/null || true
  rm -f "$SUPPORT/tunnel-$port.pid"
done
echo "   端口占用: $(lsof -n -P -i :19100 -i :19101 2>/dev/null | wc -l | tr -d ' ') 行"

echo "== 5/5 启动 app"
open -a "$APP"
sleep 6
ps -o pid,%cpu,etime,command -p "$(pgrep -f "$APP/Contents/MacOS/SparkWatch" | head -1)" || true
echo "done (官方通道请在设置窗重新登录 Dashboard 账号)"
