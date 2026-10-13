#!/usr/bin/env bash
# Install SparkWatch as a normal app: build, copy into /Applications (or
# ~/Applications when /Applications is not writable), clear the quarantine bit,
# and register it with LaunchServices so Launchpad/Spotlight pick it up.
#
#   ./Scripts/install.sh              install / reinstall
#   ./Scripts/install.sh --uninstall  remove app + login item + (optionally) data
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SparkWatch"
BUNDLE_ID="com.yingzi.sparkwatch"
SOURCE_APP="$ROOT/dist/$APP_NAME.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

case "${1:-}" in
    --uninstall)
        echo "==> 停止运行中的实例"
        pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
        echo "==> 移除登录项"
        launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
        rm -f "$LAUNCH_AGENT"
        echo "==> 删除应用"
        rm -rf "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"
        if [ "${2:-}" = "--purge" ]; then
            echo "==> 删除配置与会话数据（--purge）"
            rm -rf "$HOME/Library/Application Support/$APP_NAME"
        else
            echo "    配置保留在 ~/Library/Application Support/$APP_NAME（加 --purge 一并删除）"
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
        echo "完成。"
        exit 0
        ;;
esac

echo "==> 构建"
"$ROOT/Scripts/build-app.sh" >/dev/null
[ -d "$SOURCE_APP" ] || { echo "构建产物不存在: $SOURCE_APP" >&2; exit 1; }

# /Applications if we can write there, otherwise the per-user folder (Launchpad
# indexes both).
if [ -w /Applications ]; then
    TARGET="/Applications/$APP_NAME.app"
else
    TARGET="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
fi

echo "==> 停止旧实例"
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> 安装到 $TARGET"
rm -rf "$TARGET"
cp -R "$SOURCE_APP" "$TARGET"

echo "==> 清除隔离属性（Ad-hoc 签名必做）"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo "==> 注册到 LaunchServices（启动台/Spotlight 可见）"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
# The build output is also an app bundle; leaving it registered makes Spotlight
# and Launchpad show two SparkWatch entries (and "open" may pick the wrong one).
"$LSREGISTER" -u "$SOURCE_APP" >/dev/null 2>&1 || true
touch "$ROOT/dist/.metadata_never_index" 2>/dev/null || true

# Drop the build copy: with two identical bundles around, LaunchServices can
# hand "open SparkWatch" the repo copy (a stale one) instead of the installed
# app. Rebuild with Scripts/build-app.sh when a dev copy is actually needed.
"$LSREGISTER" -u "$SOURCE_APP" >/dev/null 2>&1 || true
rm -rf "$SOURCE_APP"

# 开机自启可能还指着刚被删掉的 dev 副本：登录时 launchd 找不到可执行文件就静默
# 失败（`launchctl list` 里显示 "- 78 com.yingzi.sparkwatch"，78 = EX_CONFIG，
# 实测于 2026-10-03：菜单栏一直没起来，而 plist 明明在）。每次安装重指到安装位置。
if [ -f "$LAUNCH_AGENT" ]; then
    if /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $TARGET/Contents/MacOS/$APP_NAME" \
        "$LAUNCH_AGENT" 2>/dev/null; then
        launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
        launchctl load "$LAUNCH_AGENT" 2>/dev/null || true
        echo "==> 开机自启已重指到 $TARGET"
    fi
fi

echo "==> 启动"
# `launchctl load` above already starts it (RunAtLoad), so `open` here used to start
# a SECOND copy under a LaunchServices job label — two menu-bar items, each showing
# the full readout (measured 2026-10-10). Start it only if nothing is running.
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
    echo "    已由开机项启动，跳过 open"
else
    open "$TARGET"
fi
sleep 2
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
    echo "已启动 ✓  状态栏右侧应出现 SparkWatch 的读数"
else
    echo "启动失败：手动双击 $TARGET 并在「系统设置 → 隐私与安全性」放行" >&2
    exit 1
fi
INSTANCES=$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" | wc -l | tr -d ' ')
if [ "$INSTANCES" -gt 1 ]; then
    # 别急着报警：`pkill` 之后旧进程还在退出、`launchctl load` 刚拉起的副本也还在
    # 走自己的单实例守卫，这两者都会被"立刻数一遍"算进来。实测这样会误报
    # （2026-10-11 装完就报了"2 个实例"，实际 8 秒后只剩 1 个）。轮询到稳定再判。
    for _ in $(seq 1 10); do
        sleep 1
        INSTANCES=$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" | wc -l | tr -d ' ')
        [ "$INSTANCES" -le 1 ] && break
    done
fi
if [ "$INSTANCES" -gt 1 ]; then
    echo "⚠ 稳定后仍有 $INSTANCES 个实例（菜单栏会出现多条读数）：pkill -f $APP_NAME 后重新安装" >&2
fi

cat <<EOF

安装完成
  应用     $TARGET
  图标     启动台 / 聚焦搜索 "SparkWatch" 可见（无 Dock 图标是菜单栏应用的正常行为）
  配置     ~/Library/Application Support/$APP_NAME/
  开机自启 状态栏菜单 → 开机自动启动（或设置窗口 → 通用）
  卸载     ./Scripts/install.sh --uninstall [--purge]
EOF
