import Foundation

/// 图表绘制的**展示层**平滑：居中加权滑动平均，断口感知。
///
/// 为什么展示层要平滑而账本不许平滑：桶值本身是诚实的（每格 = 该格真采样），
/// 但 200 根折线段直连出来是「锯齿栅栏」，看的是噪声不是形状。这里只动
/// **画出来的那根线**——原始桶值仍在图例峰值与悬停解释里，谁也不被替掉。
/// 规矩与 PowerSmoothing 一脉相承：平滑值必须可核对，不可核对的平滑 = 好看一点的谎。
///
/// 为什么必须断口感知：nil 桶是「没观测到」（引擎没跑/SSH 断），平均一旦
/// 跨过 nil，就是把「不知道」画成了「测量值之间平滑过渡」——那正是断口规矩
/// 要禁止的桥接。所以每个窗口只取**同一段连续非 nil** 的桶。
public enum ChartSmoothing {
    /// 居中加权滑动平均（权重大小 = radius+1−|偏移|，中心权最重）。
    /// 返回与输入等长的数组：nil 位置仍 nil；窗口内遇到 nil 只跳过该桶，
    /// 不跨段；端点窗口自动收缩。radius <= 0 时原样返回。
    public static func movingAverage(_ values: [Double?], radius: Int) -> [Double?] {
        guard radius > 0, !values.isEmpty else { return values }
        var out = [Double?](repeating: nil, count: values.count)
        for index in values.indices {
            guard values[index] != nil else { continue }
            var weighted = 0.0
            var weights = 0.0
            for offset in -radius...radius {
                let position = index + offset
                guard values.indices.contains(position), let value = values[position] else { continue }
                let weight = Double(radius + 1 - abs(offset))
                weighted += value * weight
                weights += weight
            }
            guard weights > 0 else { continue }
            out[index] = weighted / weights
        }
        return out
    }
}
