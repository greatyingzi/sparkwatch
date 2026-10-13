
## Install

Download **`SparkWatch-0.3.0.dmg`** below (the name follows the tag), open it, and drag
**SparkWatch** onto the Applications folder next to it. Verify the download against
`SHA256SUMS` if you like.

### The first launch needs one approval

The app is signed ad-hoc — no Apple Developer ID, because a paid developer account
is the only way to get one — so a copy that came off the network is quarantined and
Gatekeeper stops it. It looks like "nothing happens when I double-click". One
command fixes it:

```bash
xattr -dr com.apple.quarantine /Applications/SparkWatch.app
open /Applications/SparkWatch.app
```

The recursive `-r` matters: the quarantine bit is on the inner executable too, so a
non-recursive removal appears to do nothing.

In the GUI: right-click the app → **Open** → **Open** again. If macOS only offers
"Done", go to **System Settings → Privacy & Security**, find the SparkWatch notice
and click **Open Anyway**. After that it launches normally and appears in Launchpad.

### 中文

下载下面的 **`SparkWatch-0.3.0.dmg`**，打开后把 **SparkWatch** 拖进右边的 Applications。
app 是 ad-hoc 签名（没有 Apple 开发者证书），所以从网络下载的副本首次打开会被 Gatekeeper 拦，
表现为"双击没反应"。终端跑一次这条即可放行：

```bash
xattr -dr com.apple.quarantine /Applications/SparkWatch.app
```

`-r` 不能省（隔离属性也挂在内部二进制上）。图形界面等价做法：右键 app → 打开 → 再点"打开"；
若只给"完成"，去 系统设置 → 隐私与安全性 → 点"仍要打开"。

### Monitored machines stay untouched

Nothing is installed on the boxes SparkWatch reads — no agent, no exporter, no
container stack. All it needs is key-based SSH (`ssh-copy-id you@host`). On first
launch the settings window opens by itself: 添加机器 → fill in SSH host and user →
保存并应用.
