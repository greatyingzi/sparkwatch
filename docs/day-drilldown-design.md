# 历史柱状图：点击看某天详情 + 柱上显示用量（设计）

2026-11-10 · 针对反馈：“token 历史和能耗历史界面，点击柱状图无法查看那天，柱上也不显示使用量。”

## 1. 现状与缺口

两张历史柱状图共用 DailyBars（Sources/SparkWatchApp/MachinePanels.swift）：

| 使用方 | 数据 | 缺口 |
|---|---|---|
| Token 统计页「按天」 | TokenLedger.dailyCompletion(14)，UTC 日 | 无点击钻取；柱上无数值；「那天」是 UTC 日，与用户时区错位 |
| 能耗页「最近 24 小时」 | EnergyLedger.hourlyWatts(24) | 无点击；只有 .help() 原生悬停，无数值显示；连「按天」的图都没有 |

数据层事实：TokenLedger 按 series×模型×**UTC 小时桶**存了 prompt/completion/cached 全量增量（保留 35 天）；EnergyLedger 按**UTC 分钟桶**存 wh/覆盖/token（保留 31 天）。明细都在，**缺的只是查询 API 与交互**。

另一个口径问题：账本按 UTC 日分桶（跨机对账需要），但用户说「那天」指本地日（UTC+8）。**存储保持 UTC，查询侧重分组到本地日**，「今天/某天」全链路一个口径。

## 2. 设计原则

1. **诚实性**（本仓库一贯规矩）：hasData == false / nil =「没有任何记录」，不是「用量为零」；引擎关机一天和真没流量必须是两种画法（无记录画小竖条）。
2. **存储 UTC / 展示本地**：查询侧换算时区，零迁移、不影响对账。
3. **单遍聚合**：daily()/dayDetail() 每个刷新 tick 都会跑，禁止逐小时全字典排序。
4. **两图共用一个组件**：点击/悬停/数值只实现一次，杜绝两张图漂移。
5. **选中即面板，不弹窗**：详情内联在图下方展开，保留上下文；✕ 或再点一次取消。

## 3. 数据层契约

见 Sources/SparkWatchCore/DayQueries.swift（契约文件，签名冻结）：

- TokenLedger.daily(days:now:timeZone:) -> [DailyEntry]：本地日分量账（prompt/completion/cached/hasData）。
- TokenLedger.dayDetail(day:timeZone:) -> TokenDayDetail?：某日三分量合计 + 按模型表（复用 ModelRow）+ 本地 0 点起逐小时 completion（23/24/25 格，DST 正确）+ series 数。
- EnergyLedger.daily(...) / dayDetail(...)：本地日 kWh/覆盖率/均值瓦/峰值瓦 + 逐小时均值瓦。
- EnergyLedger.minuteWatts(hours:now:)：逐分钟瓦数（小时柱下钻备用）。
- EnergyLedger.seedBucket(...)：测试/演示播种缝。
- TokenLedger.totals/byModel 增加默认参数 timeZone，「今天」区间改为**本地零点**起（与按天图的「今天」柱一致；周/14/30 天仍是滚动窗口）。

## 4. UI 交互设计

    Token 统计页
    ├── 大数字 + 区间选择器（今天/7/14/30/全部，「今天」= 本地零点起）
    ├── Panel 区间按模型表
    └── Panel 按天（本地日 × 14）
        ├── DailyBars：id=日期串、柱顶常驻 compactTokens 数值、点击选中
        └── [选中日] TokenDayDetailPanel
            ├── 头：2026-11-09 周日 · UTC+8 · ✕
            ├── SegBar 当日构成（生成/缓存命中/实际计算 prefill）
            ├── 24 小时 completion 迷你柱（无记录小时画小竖条）
            ├── TokenModelTable 当日按模型（与区间表共用组件）
            └── 脚注：N 条 series 记账 · 账本按 UTC 小时桶存储、此处按本地日聚合
            └── 空态：「11 月 9 日没有记录：那天引擎可能没在跑」

    能耗页
    ├── Panel 最近 24 小时：悬停浮出「84 W」chip（修「不显示使用量」）
    ├── Panel 按天（31 天，新增）：柱顶 kWh 数值、点击选中
    │   └── [选中日] EnergyDayDetailPanel
    │       ├── kWh / 平均 W / 峰值 W / 覆盖率 四格
    │       ├── 24 小时瓦数迷你柱（无覆盖小时画小竖条）
    │       └── 脚注：估算值非功率计 · 覆盖 xx%（缺口时段无读数）
    └── statPanel 31 天 / 效率 / GPU 轨占比

DailyBars 组件增强：Bar.id: String（稳定身份）、valueText（调用方格式化）、showValues（常驻柱顶数值，头部留空防裁切）、悬停数值 chip、selection: Binding<String?>?（点击选中，选中柱全不透明+描边）。

## 5. 验收清单

- [ ] swift build --disable-sandbox 全绿；测试用本机完整命令（CLT 的 Swift Testing 为残缺 framework，须禁 cross-import overlay）：
  swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  （基线 282 项全绿。）
- [ ] --preview-main --page tokens --demo-devices 2：柱上有数值；--select-day 后详情面板出现，表格数字与当日合计一致。
- [ ] 能耗页同上；覆盖率低的日子画小竖条且详情标注覆盖。
- [ ] UTC 时区下行为与旧 dailyCompletion 一致（回归）。
- [ ] 布局 900–1600pt 宽不溢出、数字不折行。

## 6. 双飞轮分工

| | 飞轮 A（数据层） | 飞轮 B（UI 层） |
|---|---|---|
| 文件 | SparkWatchCore/DayQueries.swift、TokenLedger.swift、Tests/.../DayQueryTests.swift | MachinePanels.swift、FleetPages.swift、新 DayDetail.swift、AppModel.swift、main.swift(--select-day)、demo 播种 |
| 交付 | 契约实现 + 全绿测试 | 组件/面板/接线 + 4 张 preview 截图自查 |

集成与总验收由主会话完成（全量构建+测试+截图）。
