#!/usr/bin/env bash
# 判别力检查: 把这次修复的三处逐条"撤回"成 bug 版, 断言必须变红。
# 用 .bak 复制/还原, 不动 git 工作区(仓库里还有未提交的修复)。
set -uo pipefail
cd ~/work/sparkwatch

CRED="Sources/SparkWatchCore/Credentials.swift"
TUN="Sources/SparkWatchCore/Tunnel.swift"
BAR="Sources/SparkWatchCore/StatusBarText.swift"

mutate() { # file from to test-args
  local file="$1" from="$2" to="$3"; shift 3
  cp -p "$file" "$file.bak"
  python3 - "$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
assert s.count(a) == 1, f"anchor not unique: {a!r} in {p}"
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
  local out
  out=$(swift test "$@" 2>&1 | tail -3)
  if grep -q "passed after" <<<"$out" && ! grep -q "✘\|failed" <<<"$out"; then
    echo "✗ 未捕获(测试没判别力): $file :: $*"
  else
    echo "✓ 变红(测试有判别力): $file :: $(grep -o '✘ Test run.*' <<<"$out" | head -1)"
  fi
  mv "$file.bak" "$file"
}

# 1) 退回到"只判 token 非 nil"——正是这次死循环的退出条件
mutate "$CRED" \
  'CredentialGate.isUsable(state, now: now)' \
  'state.token != nil' \
  --filter CredentialGateTests

# 2) pid 记录只要求"端口在应答"(丢掉"进程还活着"这一半)
mutate "$TUN" \
  'processAlive && portOpen' \
  'portOpen' \
  --filter TunnelForwardTests

# 3) 状态栏不再把"需登录"当成异常
mutate "$BAR" \
  'return snapshot.health.causes.contains(.needsLogin)' \
  'return false' \
  --filter NeedsLoginSurfaceTests

echo "--- 还原后全量回归 ---"
swift test 2>&1 | grep -E "Test run with" | tail -2
