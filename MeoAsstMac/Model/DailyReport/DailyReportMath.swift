import Foundation

// 作战日报纯数学面（自 ViewModel 抽出，供轻量 swiftc 测试集编译）：
// 单件理智排名行（t 分布/泊松误差估计）、nice 轴上限、数字格式化。
// 语义源：WPF DailyReportRankRowViewModel / DailyReportFormat / NiceAxisMax。

enum DailyReportMath {
    /// 单件理智排名中的一个关卡：某种物品在该关卡平均每获得一个消耗的理智。
    struct RankRow: Identifiable {
        let id = UUID()
        let stage: String
        let count: Int
        /// 单件平均理智消耗。
        let sanityPerItem: Double
        let relativeError: Double
        let valueText: String
        let errorText: String
        /// 悬停提示（本地化文案由 ViewModel 注入，数学面不依赖本地化）。
        var toolTip: String
        var isReliable: Bool
        var isHighlighted: Bool
        /// 横条实心部分 0...1（画到置信区间比例下界）。
        var barLower: Double
        /// 误差带上界 0...1。
        var barUpper: Double

        /// 掉落数低于此值时单件理智分母过小、比值偏斜，无论误差多小都淡化显示。
        static let minReliableCount = 10
        /// 95% 置信区间相对半宽超过此值时淡化显示。
        static let maxReliableError = 0.3
        /// 记录数不少于此值时按记录间的实际波动估算误差，否则退回泊松近似。
        static let minRecordsForVariance = 5

        /// 双侧 95% 的 t 分布临界值，下标为自由度（1 ~ 30）；自由度更大时取正态分布的 1.96。
        static let tCritical: [Double] = [
            Double.nan, 12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
            2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
            2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
        ]

        /// 某种物品在某关卡的逐条记录累计量：记录数、场次 t、掉落数 c 及 Σt²、Σc²、Σc·t，
        /// 足以算出掉率 r = Σc / Σt 与记录间偏差平方和 Σ(c − r·t)²。
        struct DropStats {
            var records = 0
            var times = 0.0
            var count = 0.0
            var timesSquared = 0.0
            var countSquared = 0.0
            var countTimes = 0.0

            /// 累加一条记录（未掉落该物品的记录 count=0，同样计入）。
            mutating func add(times: Int, count: Int) {
                records += 1
                self.times += Double(times)
                self.count += Double(count)
                timesSquared += Double(times) * Double(times)
                countSquared += Double(count) * Double(count)
                countTimes += Double(count) * Double(times)
            }
        }

        /// 估算单件理智 95% 置信区间的相对半宽（与掉率的相对误差相同）。
        /// 记录足够时把每条记录当作一个样本，按记录间的实际偏差估算掉率方差：
        /// 不假设记录内各场独立，连战的保底平滑、每场多掉、固定掉落等都体现在实际偏差里，
        /// 系数按 t 分布取。记录不足时退回泊松近似，样本数取掉落数与场次的较小者，
        /// 避免每场大量掉落（如龙门币）被当作大量独立样本而显示虚假的精确。
        static func estimateRelativeError(_ s: DropStats) -> Double {
            if s.records >= Self.minRecordsForVariance && s.times > 0 {
                let rate = s.count / s.times
                // Σ(c − r·t)² 展开为 Σc² − 2r·Σc·t + r²·Σt²；按 k/(k−1) 修正自由度
                let deviation = max(0, s.countSquared - (2 * rate * s.countTimes) + (rate * rate * s.timesSquared))
                let k = s.records
                let rateStdError = (deviation * Double(k) / Double(k - 1)).squareRoot() / s.times
                let df = k - 1
                let t = df < tCritical.count ? tCritical[df] : 1.96
                return t * rateStdError / rate
            }

            return 1.96 / (max(1, min(s.count, s.times)).squareRoot())
        }

        init(stage: String, stats: DropStats, sanity: Int, toolTip: String = "") {
            self.stage = stage
            self.count = Int(stats.count)
            // WPF SanityPerItem = sanity / stats.Count：C# int/double 提升为双精度除法。
            self.sanityPerItem = stats.count > 0 ? Double(sanity) / stats.count : 0
            self.relativeError = Self.estimateRelativeError(stats)
            self.isReliable = count >= Self.minReliableCount && relativeError <= Self.maxReliableError
            self.valueText = Self.rateText(sanityPerItem)
            self.errorText = relativeError < 0.0001
                ? "<" + Self.percentText(0.0001)
                : "±" + Self.percentText(relativeError)
            self.toolTip = toolTip
            self.isHighlighted = false
            self.barLower = 0
            self.barUpper = 0
        }

        /// 横条比例：基准单件理智与本关之比，越划算越长。
        var barRatio: Double { baseline / sanityPerItem }

        /// 置信区间上界对应的横条比例倍数（单件理智取区间下限）；误差不小于 100% 时区间下限为 0，倍数为正无穷。
        var upperBoundFactor: Double { relativeError < 1 ? 1 / (1 - relativeError) : .infinity }

        var baseline = 1.0
        var scale = 1.0

        /// 设置横条坐标，排名生成后、显示前调用一次。
        mutating func setBarScale(baseline: Double, scale: Double) {
            self.baseline = baseline
            self.scale = max(1, scale)
            // 实心部分画到置信区间的比例下界（单件理智取区间上限），误差带从下界画到上界。
            barLower = min(max(barRatio / (1 + relativeError) / self.scale, 0.01), 1)
            barUpper = min(max(barRatio * upperBoundFactor / self.scale, barLower), 1)
        }

        /// 按数量级保留约三位有效数字（WPF DailyReportFormat.Rate 同构）。
        static func rateText(_ value: Double) -> String {
            let absValue = Swift.abs(value)
            if absValue >= 100 {
                return grouped(Int(value.rounded()))
            }

            if absValue >= 10 {
                return String(format: "%.1f", value)
            }

            if absValue >= 1 || absValue == 0 {
                return String(format: "%.2f", value)
            }

            let decimals = min(max(2 - Int(floor(log10(absValue))), 2), 6)
            return String(format: "%.\(decimals)f", value)
        }

        static func percentText(_ value: Double) -> String {
            String(format: "%.2f%%", value * 100)
        }

        static func grouped(_ value: Int) -> String {
            // WPF "N0" 同构：千位分组整数。
            value.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
        }
    }

    /// 折线右轴上限取不小于最大值的 1/2/5×10ⁿ 整数，刻度好读；最大值本身落在整数时即为上限，点贴顶而不是悬在半空。
    static func niceAxisMax(_ maxValue: Int) -> Int {
        guard maxValue > 1 else { return 1 }

        var magnitude = 1
        while magnitude * 10 < maxValue {
            magnitude *= 10
        }

        for step in [1, 2, 5, 10] {
            if step * magnitude >= maxValue {
                return step * magnitude
            }
        }

        return 10 * magnitude
    }
}
