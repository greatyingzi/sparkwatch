import Foundation

/// 图表几何：**把「窗口 / 桶数 / 是否缩放」变成纯函数**。
///
/// 放在 Core 而不是留在视图里，是因为它必须可测。这三个量只要跟着数据连续漂，
/// 整张图就会在每次刷新时重新缩放 —— 用户报的「每次刷新，所有曲线都在变，而不是平移」
/// 有两个来源：桶边界跟着 `now` 滑动（见 `GpuHistory.binned` 的锚定注释），以及这里的
/// 窗口/桶宽跟着数据漂。提到 Core 之后，「同一桶周期内几何不变、跨边界只变一格」被测试钉住。
public enum GpuChartScale {
    /// 请求跨度固定切成这么多桶（30 min → 20 s/桶）。
    ///
    /// 桶表示的是**区间**，不是几个样本：这台机器的利用率在秒级上基本是二值的
    /// （95% 或 0%），桶太细会把占空比画成锯齿。
    public static let bucketTarget = 90

    /// 桶宽只由**请求跨度**决定，与数据无关 —— 这是「固定住」的关键。
    public static func bucketSeconds(requested: TimeInterval) -> Double {
        requested / Double(bucketTarget)
    }

    /// 解析出实际绘制的几何。
    ///
    /// - `window`: 实际绘制跨度 = 请求跨度，或按**整桶**向上取整后的可用跨度（谁小取谁）。
    /// - `buckets`: 永远是整数，保证 `window / buckets` 精确等于 `bucketSeconds`。
    /// - `zoomed`: 因为数据不够而收窄了窗口（界面据此标注「历史起点 N 分钟前」）。
    public static func resolve(
        requested: TimeInterval,
        available: TimeInterval
    ) -> (window: TimeInterval, buckets: Int, zoomed: Bool, bucketSeconds: Double) {
        let quantum = bucketSeconds(requested: requested)
        guard available > 0, quantum > 0 else {
            return (requested, bucketTarget, false, quantum)
        }
        // 按整桶向上取整：窗口只在「又攒满一个桶」时变一次，而不是每个样本都变。
        let floor = 6 * quantum
        let filled = (available / quantum).rounded(.up) * quantum
        let window = min(requested, max(filled, floor))
        let buckets = max(6, Int((window / quantum).rounded()))
        return (window, buckets, window < requested * 0.95, quantum)
    }
}
