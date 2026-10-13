#!/usr/bin/env bash
# Package SparkWatch.app into a drag-to-install DMG.
#
#   Scripts/make-dmg.sh [app-path] [output-dmg]
#
# The image holds the app plus an /Applications symlink, which is the layout
# people expect: open the DMG, drag the app across. It also carries a note
# explaining the first-launch approval, because an ad-hoc signed app is stopped
# by Gatekeeper and "it does nothing when I double-click" reads as a broken
# download.
#
# The version comes from the app bundle that was actually built, not from an
# argument: whoever runs this gets an image whose name matches what is inside it.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"

APP="${1:-$ROOT/dist/SparkWatch.app}"
[ -d "$APP" ] || { echo "make-dmg: $APP not found (run Scripts/build-app.sh first)" >&2; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
OUT="${2:-$ROOT/dist/SparkWatch-$VERSION.dmg}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明 - How to install.txt" <<'NOTE'
SparkWatch — 安装 / install
===========================

1. 把 SparkWatch.app 拖到右边的 Applications 文件夹。
   Drag SparkWatch.app onto the Applications folder next to it.

2. 第一次打开需要放行一次（app 是 ad-hoc 签名，没有 Apple 开发者证书，
   Gatekeeper 会拦住它）：
   The first launch needs one manual approval (the app has no Developer ID):

   方式一（推荐，终端一行）：
       xattr -dr com.apple.quarantine /Applications/SparkWatch.app
       open /Applications/SparkWatch.app

   方式二（图形界面）：在 Finder 里右键点 SparkWatch.app → 打开 → 在弹框里再点"打开"。
   如果 macOS 只说"无法打开"，去 系统设置 → 隐私与安全性 → 找到 SparkWatch 的提示 → 点"仍要打开"。

   注意 `-r` 不能省：隔离属性也挂在 app 内部的二进制上，非递归的删除不生效。

3. 启动后它在菜单栏里（按设计没有 Dock 图标）。首次打开会自己弹出设置窗口：
   点"添加机器"，填 SSH 主机与用户名，点"保存并应用"。

   被监控的机器上不需要装任何东西，只需要能用 SSH 密钥登录：
       ssh-copy-id 你的用户名@主机

4. 之后双击即可启动，也会出现在启动台里。

为什么需要第 2 步：本 app 用 ad-hoc 签名（自签），没有 Apple 的开发者证书 + 公证，
所以从网络上下载的副本会带隔离属性。按上面放行一次即可，功能完全不受影响。
本机自己构建安装的副本没有隔离属性，不受影响。
NOTE

rm -f "$OUT"
/usr/bin/hdiutil create \
  -volname "SparkWatch" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT" >/dev/null

/usr/bin/hdiutil verify "$OUT" >/dev/null

# Verify by mounting and reading back, not by trusting the create exit code: an
# image that verifies structurally can still be missing a file someone renamed.
MOUNT="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$MOUNT"' EXIT
/usr/bin/hdiutil attach "$OUT" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null

fail=0
[ -d "$MOUNT/SparkWatch.app" ] || { echo "  ✗ SparkWatch.app missing from the image" >&2; fail=1; }
[ -x "$MOUNT/SparkWatch.app/Contents/MacOS/SparkWatch" ] || { echo "  ✗ main executable missing or not executable" >&2; fail=1; }
[ -L "$MOUNT/Applications" ] || { echo "  ✗ Applications symlink missing" >&2; fail=1; }
[ -f "$MOUNT/安装说明 - How to install.txt" ] || { echo "  ✗ install note missing" >&2; fail=1; }
INNER="$(plutil -extract CFBundleShortVersionString raw -o - "$MOUNT/SparkWatch.app/Contents/Info.plist" 2>/dev/null || echo "?")"
[ "$INNER" = "$VERSION" ] || { echo "  ✗ version inside the image is $INNER, expected $VERSION" >&2; fail=1; }

/usr/bin/hdiutil detach "$MOUNT" >/dev/null

if [ "$fail" != "0" ]; then
    echo "make-dmg: read-back check failed, $OUT is not fit to publish" >&2
    exit 1
fi

echo "built $OUT ($(/usr/bin/stat -f%z "$OUT") bytes) — app $VERSION, dirs and note verified by mount"
