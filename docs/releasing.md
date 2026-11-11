# 发版与版本号纪律

2026-11-11 定（主人要求：tag 不能随意打，一次迭代烧一个版本号不对）。

## 规矩

1. **迭代期不动版本号**：日常修改、部署公司机验证，一律不碰
   `Scripts/build-app.sh` 的 `VERSION` 默认值、不打 tag。
   开发版安装包用环境变量戳记区分：`VERSION="0.3.10-dev.<短sha>" ./Scripts/build-app.sh`
   （build-app.sh 本就支持 VERSION 覆盖；`-dev.` 后缀让真机上能认出这是开发版）。
2. **发版 = 一对动作**：一个 `Version: X` 提交（改默认 VERSION）+ 一个
   注解 tag `vX`，两者一起 push。**不为了发版之外的任何事打 tag。**
3. **tag 触发自动发布**：`.github/workflows/release.yml` 监听 `v*` tag ——
   push tag 即在 macOS runner 上构建+全量测试+打 DMG+发 GitHub Release
   （附 DMG 与 SHA256SUMS）。首次失败可用 workflow_dispatch
   （`inputs.tag`）重跑同版，不必删 tag。
4. **brew tap 同步**：Release 资产就绪后，用
   `Scripts/update-tap.sh <版本>`（或等效流程）下载该版 DMG、算 sha256、
   更新 `greatyingzi/homebrew-tap` 的 `Casks/sparkwatch.rb` 并推送。
5. 预发布版（如 `0.4.0-rc1`）打 tag 后 Release 自动标 prerelease
   （release.yml 按 `-` 判断）。

## 一次发版的完整动作

```bash
cd ~/work/sparkwatch
git pull --ff-only            # 同步远端
# …确认全绿：swift build && swift test…
sed -i '' 's/VERSION="${VERSION:-0.3.10}"/VERSION="${VERSION:-0.3.11}"/' Scripts/build-app.sh
git add Scripts/build-app.sh && git commit -m "Version: 0.3.11"
git tag -a v0.3.11 -m "SparkWatch 0.3.11" && git push origin main v0.3.11
# CI 自动出 Release 后：
Scripts/update-tap.sh 0.3.11   # 或按 docs/releasing.md 手动更新 tap
```

## 历史备注

0.3.3–0.3.9 是 2026-11-10/11 两天的快速迭代版本号（只进了
build-app.sh 默认值，未打 tag、未发 Release）——历史如实保留；
自 0.3.10 起按本纪律执行。
