import Foundation
import SwiftUI

// 作战日报弹窗模型（WPF DailyReportDialogViewModel 同构）：按自然日/周/月/年/全部
// 查看作战记录，日文件是唯一事实源，周/月/年由现场聚合。
// 游戏日一律以「规范锚点」（UTC 当日 00:00，见 HGCalendar.startOfGameDay）参与
// 比较、翻页与文件名，展示文本经格式化器输出。

@MainActor
final class DailyReportViewModel: ObservableObject {
    enum Dimension: String, CaseIterable, Identifiable {
        case day, week, month, year, all

        var id: String { rawValue }

        /// 当前维度可以翻页与选取日期（全部记录维度没有可翻的时段）。
        var isPageable: Bool { self != .all }
    }

    // MARK: - 展示行/格子模型

    struct StatItem: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    struct RowItem: Identifiable {
        let id = UUID()
        let stage: String
        let timeText: String
        let metaText: String
        let drops: [String: Int]
        let times: Int
        let sanity: Int
    }

    struct MaterialItem: Identifiable {
        let id: String
        let name: String
        let sources: [String: Int]
        var isSelected: Bool
    }

    struct ChartBar: Identifiable {
        let id: Int
        /// 0...1 相对高度。
        let ratio: Double
        let toolTip: String
        let tick: String
        let isMajor: Bool
        let valueText: String
    }

    struct OverlayLine {
        /// 已按 axisMax 归一化的点值（0...1+），nil 表示该桶之后不再绘制（时段未过完）。
        let points: [Double?]
        let isVisible: Bool
    }

    struct HeatCell: Identifiable {
        let id: Int
        /// nil=占位格或未来日期。
        let date: Date?
        /// 0...4 热度档位。
        let level: Int
        let toolTip: String?
    }

    /// 单件理智排名行与轴上限数学（实现在 DailyReportMath.swift，轻量测试集可编译）。
    typealias RankRow = DailyReportMath.RankRow

    struct HeatMonthLabel: Identifiable {
        let id: Int
        let column: Int
        let label: String
    }

    // MARK: - 状态

    @Published var dimension: Dimension = .day {
        didSet {
            guard oldValue != dimension else { return }
            anchor = min(anchor, today)
            refreshAll()
        }
    }

    /// 当前查看时段的锚点（游戏日规范锚点）。
    @Published private(set) var anchor: Date

    @Published private(set) var periodLabel = ""

    @Published private(set) var canGoNext = true

    @Published private(set) var stats: [StatItem] = []

    @Published private(set) var rows: [RowItem] = []

    @Published var isMaterialView = false {
        didSet {
            guard oldValue != isMaterialView else { return }
            // 选中物品只在按材料视图有入口可以取消，回到按关卡视图时图表回到理智消耗。
            if !isMaterialView, selectedItemId != nil {
                selectItem(nil, highlightStage: nil)
            }
        }
    }

    @Published private(set) var materials: [MaterialItem] = []

    @Published private(set) var selectedItemId: String?

    @Published private(set) var chartTitle = ""

    @Published private(set) var chartBars: [ChartBar] = []

    @Published private(set) var medicineLine: OverlayLine?

    @Published private(set) var stoneLine: OverlayLine?

    @Published private(set) var overlayAxisMaxText = ""

    var hasOverlay: Bool { medicineLine?.isVisible == true || stoneLine?.isVisible == true }

    @Published var isRankMode = false

    @Published private(set) var rankRows: [RankRow] = []

    @Published private(set) var rankHistoryBestText = ""

    var hasRankHistoryBest: Bool { !rankHistoryBestText.isEmpty }

    @Published private(set) var rankScopeText = ""

    @Published private(set) var heatCells: [HeatCell] = []

    @Published private(set) var heatColumns = 53

    @Published private(set) var heatMonthLabels: [HeatMonthLabel] = []

    var isYearView: Bool { dimension == .year }

    @Published var isHeatmapMode = true

    /// 图表卡片折叠（@AppStorage 同键：设置跨会话保持）。
    @AppStorage("MAADailyReportChartCollapsed") var isChartCollapsed = false

    /// 浮层跳转时临时展开图表（本次打开内有效），不覆盖用户持久化的折叠选择。
    private var chartExpandedOnce = false

    var isChartDisplayed: Bool { !(isChartCollapsed && !chartExpandedOnce) }

    func toggleChartCollapsed() {
        chartExpandedOnce = false
        isChartCollapsed.toggle()
    }

    // MARK: - 保留档位

    /// 保留档位（@AppStorage 同键）。已有记录超出新档位时先经视图确认，确认后写全局配置并立即裁剪。
    @AppStorage("MAADailyReportRetention") private var retentionRaw = DailyReportRetention.unlimited.rawValue

    var selectedRetention: DailyReportRetention {
        get { DailyReportRetention(rawValue: retentionRaw) ?? .unlimited }
    }

    /// 待确认的档位变更（视图据此弹确认框）；nil=无待确认。
    struct RetentionConfirmation: Identifiable {
        let id = UUID()
        let proposed: DailyReportRetention
        let prunableDays: [Date]
        let message: String
    }

    @Published private(set) var retentionConfirmation: RetentionConfirmation?

    /// 档位变更入口：无超期记录直接应用，否则挂起待视图确认（WPF ConfirmRetention 同构）。
    func changeRetention(to value: DailyReportRetention) {
        guard value != selectedRetention else { return }
        let prunable = DailyReportStore.listPrunableDays(
            value, today: today, calendar: calendar, directory: DailyReportCollector.directory)
        // 不限制档位返回 nil（无超期），其余为升序超期日列表。
        if prunable == nil || prunable?.isEmpty == true {
            applyRetention(value)
            return
        }

        guard let prunable, let first = prunable.first, let last = prunable.last else { return }
        let message = String(
            format: String(localized: "切换后将删除 %@ 至 %@ 共 %lld 天的作战记录，此操作无法撤销。\n是否继续？"),
            Self.dayText(first), Self.dayText(last), prunable.count)
        retentionConfirmation = RetentionConfirmation(proposed: value, prunableDays: prunable, message: message)
    }

    func confirmRetention() {
        guard let confirmation = retentionConfirmation else { return }
        retentionConfirmation = nil
        applyRetention(confirmation.proposed)
        loadHistory()
        refreshAll()
    }

    func cancelRetention() {
        retentionConfirmation = nil
    }

    private func applyRetention(_ value: DailyReportRetention) {
        retentionRaw = value.rawValue
        DailyReportCollector.pruneNow(
            retention: value, channel: DailyReportCollector.currentChannel, directory: DailyReportCollector.directory)
    }

    // MARK: - 环境

    private var calendar: HGCalendar { DailyReportCollector.currentChannel.calendar }

    /// 游戏日标签的比较/算术用 UTC 日历（锚点即 UTC 当日 00:00）。
    private let utcCalendar = Calendar(identifier: .gregorian)

    var today: Date {
        calendar.startOfGameDay(for: Date.now)
    }

    /// DatePicker 产出本地日历当日时刻，统一换算为游戏日锚点再跳转。
    func calendarAnchor(fromLocal date: Date) -> Date {
        calendar.startOfGameDay(for: date)
    }

    // MARK: - 内部聚合状态

    private var sessions: [(day: Date, session: CombatSession)] = []

    /// 全部历史记录按关卡分组的逐条记录（场次与掉落），排名时按物品现算累计量；
    /// 保留逐条记录而非只存合计：误差按记录间的实际波动估算，未掉落该物品的记录也是样本。
    private var history: [String: (sanity: Int, sessions: [CombatSession])] = [:]

    /// 最早一条记录所在的游戏日，没有记录时为 nil。
    private var historyStart: Date?

    init() {
        // 计算属性 calendar 在全量初始化前不可访问，此处直接取频道日历。
        anchor = DailyReportCollector.currentChannel.calendar.startOfGameDay(for: Date.now)
        loadHistory()
        refreshAll()
    }

    /// 窗口每次打开时复位跨次状态（WPF ResetWindowLifetimeState 同构）。
    func resetWindowLifetimeState() {
        chartExpandedOnce = false
        loadHistory()
        refreshAll()
    }

    // MARK: - 翻页与跳转

    func goPrevious() {
        anchor = min(shiftAnchor(-1), today)
        refreshAll()
    }

    func goNext() {
        anchor = min(shiftAnchor(1), today)
        refreshAll()
    }

    func goToday() {
        anchor = today
        refreshAll()
    }

    private func shiftAnchor(_ direction: Int) -> Date {
        switch dimension {
        case .week:
            return utcCalendar.date(byAdding: .day, value: 7 * direction, to: anchor) ?? anchor
        case .month:
            return utcCalendar.date(byAdding: .month, value: direction, to: startOfMonth(anchor)) ?? anchor
        case .year:
            return utcCalendar.date(byAdding: .year, value: direction, to: startOfYear(anchor)) ?? anchor
        case .day, .all:
            return utcCalendar.date(byAdding: .day, value: direction, to: anchor) ?? anchor
        }
    }

    /// 日历选取完成后跳转到所选日期（游戏日锚点）所在时段。
    func jumpTo(_ gameDay: Date) {
        anchor = min(gameDay, today)
        refreshAll()
    }

    // MARK: - 物品选取与排名跳转

    /// 物品点击：切换柱状图展示的物品，点击已选中的物品取消选中、回到理智消耗。
    func toggleMaterial(_ itemId: String) {
        selectItem(selectedItemId == itemId ? nil : itemId, highlightStage: nil)
    }

    /// 从按关卡视图的掉率浮层跳转：切到按材料视图、选中该物品并显示关卡排名，高亮来源关卡。
    func showRanking(itemId: String, stage: String) {
        isMaterialView = true
        chartExpandedOnce = true
        selectItem(itemId, highlightStage: stage)
        isRankMode = true
    }

    private func selectItem(_ itemId: String?, highlightStage: String?) {
        selectedItemId = itemId
        self.highlightStage = highlightStage
        materials = materials.map { MaterialItem(id: $0.id, name: $0.name, sources: $0.sources, isSelected: $0.id == itemId) }
        if !canRank {
            isRankMode = false
        }

        refreshChart()
    }

    private var highlightStage: String?

    /// 当前选中的物品可以做关卡排名（仅养成材料），决定「趋势 / 关卡排名」切换是否出现。
    var canRank: Bool {
        guard let selectedItemId else { return false }
        return Self.isRankable(selectedItemId)
    }

    /// 物品是否参与单件理智排名：仅 item_index 中归类为 MATERIAL 的养成材料。
    private static func isRankable(_ itemId: String) -> Bool {
        FightConfiguration.dropItems.first { $0.id == itemId }?.item.classifyType == "MATERIAL"
    }

    /// 物品展示名（物品表未加载或查不到时原样返回）。
    static func itemName(_ itemId: String) -> String {
        FightConfiguration.dropItems.first { $0.id == itemId }?.item.name ?? itemId
    }

    /// 物品排序键（WPF 用 item_index 的 SortId，缺省排最后）。
    static func itemSortId(_ itemId: String) -> Int {
        FightConfiguration.dropItems.first { $0.id == itemId }?.item.sortId ?? .max
    }

    // MARK: - 聚合主流程

    /// 按当前维度与锚点重算时段范围、聚合记录、物品汇总、柱状图与统计。
    func refreshAll() {
        let (from, to) = range()
        periodLabel = buildPeriodLabel(from: from, to: to)
        canGoNext = to < today

        sessions = DailyReportStore.loadRange(from: from, to: to, calendar: calendar, directory: DailyReportCollector.directory)
            .flatMap { day, data in data.sessions.map { (day, $0) } }
        let sessionList = sessions.map(\.session)

        if dimension == .day {
            rows = sessionList
                .sorted { $0.startTime < $1.startTime }
                .map { Self.buildRow($0) }
        } else {
            var grouped: [String: [CombatSession]] = [:]
            for session in sessionList {
                grouped[session.stage, default: []].append(session)
            }

            rows = grouped
                .sorted { lhs, rhs in
                    let lhsSanity = lhs.value.reduce(0) { $0 + $1.sanity }
                    let rhsSanity = rhs.value.reduce(0) { $0 + $1.sanity }
                    if lhsSanity != rhsSanity {
                        return lhsSanity > rhsSanity
                    }

                    return lhs.key < rhs.key
                }
                .map { Self.buildRow($0.key, $0.value) }
        }

        let itemCatalog = Dictionary(uniqueKeysWithValues: FightConfiguration.dropItems.map { ($0.id, $0.item) })
        var materialSources: [String: [String: Int]] = [:]
        for (day, session) in sessions {
            for (itemId, count) in session.drops {
                materialSources[itemId, default: [:]][session.stage, default: 0] += count
            }
        }

        materials = materialSources
            .map { MaterialItem(id: $0.key, name: Self.itemName($0.key), sources: $0.value, isSelected: $0.key == selectedItemId) }
            .sorted {
                let lhsSort = itemCatalog[$0.id]?.sortId ?? .max
                let rhsSort = itemCatalog[$1.id]?.sortId ?? .max
                if lhsSort != rhsSort {
                    return lhsSort < rhsSort
                }

                return $0.id < $1.id
            }

        let groupedCount = RankRow.grouped(sessionList.reduce(0) { $0 + $1.times })
        stats = [
            StatItem(label: String(localized: "场次"), value: groupedCount),
            StatItem(label: String(localized: "理智消耗"), value: RankRow.grouped(sessionList.reduce(0) { $0 + $1.sanity })),
            StatItem(
                label: String(localized: "药剂"),
                value: RankRow.grouped(sessionList.reduce(0) { $0 + $1.medicinesUsed + $1.expiringMedicinesUsed })),
            StatItem(label: String(localized: "源石"), value: RankRow.grouped(sessionList.reduce(0) { $0 + $1.stonesUsed })),
            StatItem(label: String(localized: "掉落种类"), value: RankRow.grouped(materials.count)),
        ]

        refreshChart()
    }

    private func refreshChart() {
        let (from, to) = range()

        // 日维度按小时分桶（游戏日从 04:00 起），周/月维度按天，年维度按月，全部记录维度按跨度自适应。
        let allBuckets: [AllBucket]? = dimension == .all ? buildAllBuckets(from: from, to: to) : nil
        let bucketCount: Int
        switch dimension {
        case .day: bucketCount = 24
        case .year: bucketCount = 12
        case .all: bucketCount = allBuckets?.count ?? 1
        case .week, .month:
            bucketCount = (utcCalendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1
        }

        func bucketOf(day: Date, session: CombatSession) -> Int {
            switch dimension {
            case .day: calendar.gameDayHour(for: session.startTime)
            case .year: (utcCalendar.dateComponents([.month], from: day).month ?? 1) - 1
            case .all:
                allBuckets?.lastIndex(where: { $0.from <= day }) ?? 0
            case .week, .month:
                utcCalendar.dateComponents([.day], from: from, to: day).day ?? 0
            }
        }

        var values = [Int](repeating: 0, count: bucketCount)
        var medicines = [Int](repeating: 0, count: bucketCount)
        var stones = [Int](repeating: 0, count: bucketCount)
        for (day, session) in sessions {
            let bucket = bucketOf(day: day, session: session)
            guard bucket >= 0, bucket < bucketCount else { continue }
            medicines[bucket] += session.medicinesUsed + session.expiringMedicinesUsed
            stones[bucket] += session.stonesUsed
            values[bucket] += selectedItemId == nil ? session.sanity : session.drops[selectedItemId ?? "", default: 0]
        }

        // 药剂与源石只在显示理智消耗时叠加，两条线共用右轴；全为 0 的那条不画。
        let overlayMax = max(medicines.max() ?? 0, stones.max() ?? 0)
        let showOverlay = selectedItemId == nil && overlayMax > 0
        let axisMax = DailyReportMath.niceAxisMax(overlayMax)

        // 时段尚未过完时（本周、本月、本年），今日之后的桶没有数据而非为 0，折线只画到今日。
        let elapsed: Int
        switch dimension {
        case .day, .all:
            elapsed = bucketCount
        case .year:
            if to < today {
                elapsed = bucketCount
            } else if (utcCalendar.dateComponents([.year], from: from).year ?? 0) == (utcCalendar.dateComponents([.year], from: today).year ?? 0) {
                elapsed = (utcCalendar.dateComponents([.month], from: today).month ?? 1)
            } else {
                elapsed = 0
            }
        case .week, .month:
            elapsed = min(max((utcCalendar.dateComponents([.day], from: from, to: today).day ?? 0) + 1, 0), bucketCount)
        }

        func line(_ values: [Int]) -> OverlayLine? {
            guard showOverlay else { return nil }
            let points = values.enumerated().map { index, value in
                index < elapsed && axisMax > 0 ? Double(value) / Double(axisMax) : nil
            }
            return OverlayLine(points: points, isVisible: values.contains { $0 > 0 })
        }

        medicineLine = line(medicines)
        stoneLine = line(stones)
        overlayAxisMaxText = showOverlay ? RankRow.grouped(axisMax) : ""

        let maxValue = values.max() ?? 0
        chartBars = values.enumerated().map { index, value in
            // 首行「桶标签  数值」，显示理智消耗且有叠加时第二行为药剂/源石（WPF BarToolTip 同构）。
            var tip = bucketLabel(index, from: from, allBuckets: allBuckets) + "  " + RankRow.grouped(value)
            if showOverlay {
                tip += "\n" + String(
                    format: String(localized: "药剂 %@ · 源石 %@"),
                    RankRow.grouped(medicines[index]), RankRow.grouped(stones[index]))
            }

            return ChartBar(
                id: index,
                ratio: maxValue == 0 ? 0 : Double(value) / Double(maxValue),
                toolTip: tip,
                tick: tickLabel(index, from: from, allBuckets: allBuckets),
                isMajor: allBuckets?[safe: index]?.isMajor ?? false,
                valueText: value == 0 || showOverlay ? "" : RankRow.grouped(value))
        }

        chartTitle = selectedItemId.map { Self.itemName($0) } ?? String(localized: "理智消耗")

        rankRows = selectedItemId == nil ? [] : buildRanking(selectedItemId!)
        for index in rankRows.indices {
            rankRows[index].isHighlighted = rankRows[index].stage == highlightStage
        }

        rankHistoryBestText = selectedItemId == nil ? "" : buildHistoryBestText(selectedItemId!, rows: rankRows)
        rankScopeText = selectedItemId == nil ? "" : buildRankScopeText()

        if dimension == .year {
            refreshHeatmap(from: from, to: to)
        } else {
            heatCells = []
            heatMonthLabels = []
            heatColumns = 53
        }
    }

    // MARK: - 时段范围与标签

    /// (from, to) 游戏日锚点（含两端）。
    private func range() -> (Date, Date) {
        switch dimension {
        case .day:
            return (anchor, anchor)
        case .week:
            // 自然周（周一为始）。
            let weekday = utcCalendar.component(.weekday, from: anchor)
            let offsetFromMonday = (weekday + 6) % 7
            let monday = utcCalendar.date(byAdding: .day, value: -offsetFromMonday, to: anchor) ?? anchor
            let sunday = utcCalendar.date(byAdding: .day, value: 6, to: monday) ?? monday
            return (monday, sunday)
        case .month:
            let first = startOfMonth(anchor)
            let last = utcCalendar.date(byAdding: .day, value: -1, to: utcCalendar.date(byAdding: .month, value: 1, to: first) ?? first) ?? first
            return (first, last)
        case .year:
            return (startOfYear(anchor), endOfYear(anchor))
        case .all:
            return (historyStart ?? today, today)
        }
    }

    private func startOfMonth(_ date: Date) -> Date {
        var components = utcCalendar.dateComponents([.year, .month], from: date)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return utcCalendar.date(from: components) ?? date
    }

    private func startOfYear(_ date: Date) -> Date {
        var components = utcCalendar.dateComponents([.year], from: date)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return utcCalendar.date(from: components) ?? date
    }

    private func endOfYear(_ date: Date) -> Date {
        let nextYear = utcCalendar.date(byAdding: .year, value: 1, to: startOfYear(date)) ?? date
        return utcCalendar.date(byAdding: .day, value: -1, to: nextYear) ?? date
    }

    private func buildPeriodLabel(from: Date, to: Date) -> String {
        switch dimension {
        case .day:
            let weekdayIndex = (utcCalendar.component(.weekday, from: anchor) + 6) % 7
            let symbol = calendar.weekdaySymbol(at: weekdayIndex)
            return Self.dayText(anchor) + " " + symbol
        case .week:
            return Self.shortDayText(from) + " ~ " + Self.shortDayText(to)
        case .month:
            return Self.monthText(anchor)
        case .year:
            return Self.yearText(anchor)
        case .all:
            guard let historyStart else {
                return String(localized: "暂无作战记录")
            }

            return Self.dayText(historyStart) + " ~ " + Self.dayText(to)
        }
    }

    // MARK: - 柱状图分桶

    private struct AllBucket {
        let from: Date
        let tick: String
        let isMajor: Bool
        let toolTip: String
    }

    /// 全部记录维度的柱子上限：跨度不超过 30 个月按月分，不超过 30 个季度按季分，再长就把整个跨度均分为 30 段。
    private static let maxAllBuckets = 30

    /// 生成全部记录维度的分桶。刻度标月份或季度，每年第一个月或第一个季度改标年份并作为主刻度；
    /// 均分时只在跨年的段标年份。
    private func buildAllBuckets(from: Date, to: Date) -> [AllBucket] {
        var buckets: [AllBucket] = []
        let months = (utcCalendar.dateComponents([.month], from: startOfMonth(from), to: to).month ?? 0) + 1
        if months <= Self.maxAllBuckets {
            var month = startOfMonth(from)
            while month <= to {
                let monthNumber = utcCalendar.dateComponents([.month], from: month).month ?? 1
                let year = utcCalendar.dateComponents([.year], from: month).year ?? 0
                let isMajor = monthNumber == 1
                buckets.append(
                    AllBucket(
                        from: month,
                        tick: isMajor ? "\(year)" : "\(monthNumber)",
                        isMajor: isMajor,
                        toolTip: Self.monthText(month)))
                month = utcCalendar.date(byAdding: .month, value: 1, to: month) ?? month
            }

            return buckets
        }

        // 起点对齐到季度首月。
        var quarterStart = startOfMonth(from)
        let fromMonth = utcCalendar.dateComponents([.month], from: from).month ?? 1
        let backSteps = (fromMonth - 1) % 3
        quarterStart = utcCalendar.date(byAdding: .month, value: -backSteps, to: quarterStart) ?? quarterStart
        let quarters = ((utcCalendar.dateComponents([.month], from: quarterStart, to: to).month ?? 0) / 3) + 1
        if quarters <= Self.maxAllBuckets {
            var quarter = quarterStart
            while quarter <= to {
                let monthNumber = utcCalendar.dateComponents([.month], from: quarter).month ?? 1
                let year = utcCalendar.dateComponents([.year], from: quarter).year ?? 0
                let quarterNumber = (monthNumber - 1) / 3 + 1
                let isMajor = quarterNumber == 1
                buckets.append(
                    AllBucket(
                        from: quarter,
                        tick: isMajor ? "\(year)" : "Q\(quarterNumber)",
                        isMajor: isMajor,
                        toolTip: "\(year) Q\(quarterNumber)"))
                quarter = utcCalendar.date(byAdding: .month, value: 3, to: quarter) ?? quarter
            }

            return buckets
        }

        let days = (utcCalendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1
        for index in 0..<Self.maxAllBuckets {
            let start = utcCalendar.date(byAdding: .day, value: days * index / Self.maxAllBuckets, to: from) ?? from
            let crossesYear = index > 0
                && (utcCalendar.dateComponents([.year], from: start).year ?? 0)
                    != (utcCalendar.dateComponents([.year], from: buckets[buckets.count - 1].from).year ?? 0)
            let end = utcCalendar.date(byAdding: .day, value: days * (index + 1) / Self.maxAllBuckets - 1, to: from) ?? from
            buckets.append(
                AllBucket(
                    from: start,
                    tick: crossesYear ? "\(utcCalendar.dateComponents([.year], from: start).year ?? 0)" : "",
                    isMajor: crossesYear,
                    toolTip: Self.dayText(start) + " ~ " + Self.dayText(end)))
        }

        return buckets
    }

    private func bucketLabel(_ index: Int, from: Date, allBuckets: [AllBucket]?) -> String {
        switch dimension {
        case .day:
            return String(format: "%02d:00", (index + 4) % 24)
        case .year:
            var components = utcCalendar.dateComponents([.year], from: from)
            components.month = index + 1
            components.day = 1
            components.timeZone = TimeZone(secondsFromGMT: 0)
            let monthDate = utcCalendar.date(from: components) ?? from
            return Self.monthShortText(monthDate)
        case .all:
            return allBuckets?[safe: index]?.toolTip ?? ""
        case .week, .month:
            let day = utcCalendar.date(byAdding: .day, value: index, to: from) ?? from
            return Self.shortDayText(day) + " " + Self.weekdayShortText(day)
        }
    }

    private func tickLabel(_ index: Int, from: Date, allBuckets: [AllBucket]?) -> String {
        switch dimension {
        case .day:
            return "\((index + 4) % 24)"
        case .week:
            let day = utcCalendar.date(byAdding: .day, value: index, to: from) ?? from
            return Self.weekdayShortText(day)
        case .all:
            return allBuckets?[safe: index]?.tick ?? ""
        case .month, .year:
            return "\(index + 1)"
        }
    }


    // MARK: - 年度热力图

    /// 年度热力图：按当年非零值的四分位分 4 档，每列一周、周一在上，格子点击跳到当天日视图。
    private func refreshHeatmap(from: Date, to: Date) {
        var daily: [Date: Int] = [:]
        for (day, session) in sessions {
            let value = selectedItemId == nil ? session.sanity : session.drops[selectedItemId ?? "", default: 0]
            daily[day, default: 0] += value
        }

        // 按当年非零值的四分位分 4 档，单日极端值不会把其他格子的颜色都压淡。
        let sortedValues = daily.values.filter { $0 > 0 }.sorted()
        func quantile(_ q: Double) -> Int {
            guard !sortedValues.isEmpty else { return 0 }
            return sortedValues[Int((Double(sortedValues.count - 1)) * q)]
        }

        let cuts = [quantile(0.25), quantile(0.5), quantile(0.75)]
        func level(_ value: Int) -> Int {
            if value <= 0 { return 0 }
            if value <= cuts[0] { return 1 }
            if value <= cuts[1] { return 2 }
            if value <= cuts[2] { return 3 }
            return 4
        }

        // 先按时间顺序排成每列一周、周一在上，年初不足一周的部分用占位格补齐。
        let weekday = utcCalendar.component(.weekday, from: from)
        let lead = (weekday + 6) % 7
        var cells: [(date: Date?, level: Int, toolTip: String?)] = []
        for _ in 0..<lead {
            cells.append((nil, 0, nil))
        }

        var months: [HeatMonthLabel] = []
        var day = from
        while day <= to {
            let value = daily[day, default: 0]
            let tip = Self.dayText(day) + " " + Self.weekdayShortText(day) + "  "
                + (value > 0 ? RankRow.grouped(value) : String(localized: "未作战"))
            if (utcCalendar.dateComponents([.day], from: day).day ?? 0) == 1 {
                months.append(HeatMonthLabel(id: cells.count / 7, column: cells.count / 7, label: Self.monthShortText(day)))
            }

            if day > today {
                cells.append((nil, 0, nil))
            } else {
                cells.append((day, level(value), tip))
            }

            day = utcCalendar.date(byAdding: .day, value: 1, to: day) ?? day
        }

        // cells 按时间顺序（列优先）生成，网格按行填充，转置后每列才是一周。
        let columns = (cells.count + 6) / 7
        while cells.count < columns * 7 {
            cells.append((nil, 0, nil))
        }

        var transposed: [HeatCell] = []
        transposed.reserveCapacity(cells.count)
        for row in 0..<7 {
            for column in 0..<columns {
                let cell = cells[column * 7 + row]
                transposed.append(HeatCell(id: transposed.count, date: cell.date, level: cell.level, toolTip: cell.toolTip))
            }
        }

        heatColumns = columns
        heatCells = transposed
        heatMonthLabels = months
    }

    // MARK: - 记录行

    private static func buildRow(_ session: CombatSession) -> RowItem {
        let timeText = shortTimeText(session.startTime) + " – " + (session.endTime.map { shortTimeText($0) } ?? "?")
        return RowItem(
            stage: session.stage,
            timeText: timeText,
            metaText: buildMetaText(
                times: session.times, sanity: session.sanity,
                medicines: session.medicinesUsed + session.expiringMedicinesUsed,
                stones: session.stonesUsed,
                perBattle: averagePerBattle([session])),
            drops: session.drops,
            times: session.times,
            sanity: session.sanity)
    }

    private static func buildRow(_ stage: String, _ group: [CombatSession]) -> RowItem {
        let times = group.reduce(0) { $0 + $1.times }
        let sanity = group.reduce(0) { $0 + $1.sanity }
        var drops: [String: Int] = [:]
        for session in group {
            for (itemId, count) in session.drops {
                drops[itemId, default: 0] += count
            }
        }

        return RowItem(
            stage: stage,
            timeText: "",
            metaText: buildMetaText(
                times: times, sanity: sanity,
                medicines: group.reduce(0) { $0 + $1.medicinesUsed + $1.expiringMedicinesUsed },
                stones: group.reduce(0) { $0 + $1.stonesUsed },
                perBattle: averagePerBattle(group)),
            drops: drops,
            times: times,
            sanity: sanity)
    }

    private static func duration(_ session: CombatSession) -> TimeInterval {
        guard let endTime = session.endTime, endTime > session.startTime else { return 0 }
        return endTime.timeIntervalSince(session.startTime)
    }

    /// 每局代理作战的平均耗时；分母用局数（不含倍率折算），只统计有起止时刻且打过局的记录。
    private static func averagePerBattle(_ group: [CombatSession]) -> TimeInterval {
        let timed = group.filter { $0.rounds > 0 && duration($0) > 0 }
        let rounds = timed.reduce(0) { $0 + $1.rounds }
        guard rounds > 0 else { return 0 }
        return (timed.reduce(0.0) { $0 + duration($1) } / Double(rounds)).rounded()
    }

    /// 按数量选单数或复数文案：WPF Plural 以 .One 后缀键区分，Mac 用 xcstrings 的
    /// 复数 variations（键 %lld 场 / 药剂 %lld，en 配 one/other 两变体）。
    private static func pluralSessions(_ count: Int) -> String {
        count == 1
            ? String(format: String(localized: "%@ 场.One"), RankRow.grouped(count))
            : String(format: String(localized: "%@ 场"), RankRow.grouped(count))
    }

    private static func pluralMedicines(_ count: Int) -> String {
        count == 1
            ? String(format: String(localized: "药剂 %@.One"), RankRow.grouped(count))
            : String(format: String(localized: "药剂 %@"), RankRow.grouped(count))
    }

    private static func buildMetaText(times: Int, sanity: Int, medicines: Int, stones: Int, perBattle: TimeInterval) -> String {
        var parts: [String] = [
            pluralSessions(times),
            String(format: String(localized: "理智 %@"), RankRow.grouped(sanity)),
        ]
        if medicines > 0 {
            parts.append(pluralMedicines(medicines))
        }

        if stones > 0 {
            parts.append(String(format: String(localized: "源石 %@"), RankRow.grouped(stones)))
        }

        // 平均耗时含用药、碎石与界面跳转的等待，用于关卡间相对比较，不等于单局实际战斗时长。
        if perBattle > 0 {
            let minutes = Int(perBattle) / 60
            let seconds = Int(perBattle) % 60
            let durationText = String(format: "%d:%02d", minutes, seconds)
            parts.append(String(format: String(localized: "平均 %@/场"), durationText))
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - 历史（单件理智排名数据源）

    /// 读取全部历史记录并按关卡分组，供单件理智排名使用；窗口打开与裁剪记录后重读。
    func loadHistory() {
        let days = DailyReportStore.loadRange(from: Date.distantPast, to: Date.distantFuture, calendar: calendar, directory: DailyReportCollector.directory)
        historyStart = days.map(\.day).min()
        var grouped: [String: (sanity: Int, sessions: [CombatSession])] = [:]
        for (_, data) in days {
            for session in data.sessions where session.times > 0 {
                grouped[session.stage, default: (0, [])].sanity += session.sanity
                grouped[session.stage, default: (0, [])].sessions.append(session)
            }
        }

        history = grouped
    }

    private func historyRows(_ itemId: String) -> [RankRow] {
        history.compactMap { stage, group -> RankRow? in
            var stats = RankRow.DropStats()
            for session in group.sessions {
                stats.add(times: session.times, count: session.drops[itemId, default: 0])
            }

            guard stats.count > 0, group.sanity > 0 else { return nil }
            var row = RankRow(stage: stage, stats: stats, sanity: group.sanity)
            // Tip 键中英参数序不同（zh：掉落在后；en：掉落在前），模板用 %n$ 位置参数。
            row.toolTip = String(
                format: String(localized: "95%% 置信区间 %1$@ ~ %2$@ 理智/个\n%4$lld 场共掉落 %3$lld 个"),
                RankRow.rateText(row.sanityPerItem * max(0, 1 - row.relativeError)),
                RankRow.rateText(row.sanityPerItem * (1 + row.relativeError)),
                RankRow.grouped(row.count),
                RankRow.grouped(Int(stats.times)))
            return row
        }
    }

    /// 计算某种物品的单件理智排名：数据取全部历史记录（时段内样本太少，排名误差大到没有参考意义），
    /// 只列出当前时段刷过的关卡；可靠样本在前、按单件理智升序，样本不足的排到末尾。
    private func buildRanking(_ itemId: String) -> [RankRow] {
        // 只对养成材料排名；龙门币、家具零件等通用产出几乎每关都掉，按理智比较没有意义。
        guard Self.isRankable(itemId) else { return [] }

        let stages = Set(sessions.map { $0.session.stage })
        var rows = historyRows(itemId)
            .filter { stages.contains($0.stage) }
            .sorted {
                if $0.isReliable != $1.isReliable {
                    return $0.isReliable
                }

                return $0.sanityPerItem < $1.sanityPerItem
            }

        // 横条比例为最划算关卡的单件理智与本关之比，越费理智越短；满长取各行误差带上界的最大值，
        // 让误差带完整显示。基准与满长只看可靠样本：样本不足的偶然低值或超宽误差带会让其他横条
        // 整体变短，这些行超出满长的部分截断。
        let reliable = rows.filter(\.isReliable)
        let basis = reliable.isEmpty ? rows : reliable
        let best = basis.map(\.sanityPerItem).min() ?? 1
        let scale = basis.map { best / $0.sanityPerItem * $0.upperBoundFactor }
            .filter { $0.isFinite }
            .max() ?? 1
        for index in rows.indices {
            rows[index].setBarScale(baseline: best, scale: scale)
        }

        return rows
    }

    /// 排名卡片标题旁的口径说明：列出的关卡范围与数据来源。
    private func buildRankScopeText() -> String {
        guard let historyStart else { return "" }
        return String(format: String(localized: "仅列本时段刷过的关卡 · 数据取自 %@ 起的全部记录"), Self.dayText(historyStart))
    }

    /// 历史最优关卡提示：历史上单件理智最低的可靠关卡不在列表里（当前时段没刷过）时给出，否则为空。
    private func buildHistoryBestText(_ itemId: String, rows: [RankRow]) -> String {
        let best = historyRows(itemId).filter(\.isReliable).min { $0.sanityPerItem < $1.sanityPerItem }
        guard let best, !rows.contains(where: { $0.stage == best.stage }) else { return "" }

        return String(
            format: String(localized: "历史最优 %@：%@ 理智/个（误差 %@），本时段未刷"),
            best.stage, best.valueText, best.errorText)
    }

    /// 生成掉率浮层里的排名摘要：该物品在本关卡的名次、参与排名的关卡数与误差。
    func buildRankSummary(itemId: String, stage: String) -> String {
        let ranked = buildRanking(itemId)
        guard ranked.count >= 2, let index = ranked.firstIndex(where: { $0.stage == stage }) else {
            return ""
        }

        let row = ranked[index]
        let key: String.LocalizationValue = row.isReliable
            ? "关卡排名 %lld/%lld · 误差 %@"
            : "关卡排名 %lld/%lld · 误差 %@ · 样本少"
        return String(format: String(localized: key), index + 1, ranked.count, row.errorText)
    }

    // MARK: - 格式化

    static func dayText(_ date: Date) -> String {
        Self.utcFormatter(dateFormat: "yyyy-MM-dd").string(from: date)
    }

    static func shortDayText(_ date: Date) -> String {
        Self.utcFormatter(dateFormat: "MM-dd").string(from: date)
    }

    static func monthText(_ date: Date) -> String {
        Self.utcFormatter(dateFormat: "yyyy-MM").string(from: date)
    }

    static func yearText(_ date: Date) -> String {
        Self.utcFormatter(dateFormat: "yyyy").string(from: date)
    }

    static func monthShortText(_ date: Date) -> String {
        Self.utcFormatter(dateFormat: "MMM").string(from: date)
    }

    static func weekdayShortText(_ date: Date) -> String {
        Self.utcFormatter(dateFormat: "EEE").string(from: date)
    }

    static func shortTimeText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(.current))
    }

    /// 游戏日标签锚在 UTC 当日 00:00，格式化必须固定 UTC 时区，避免本地时区把标签漂到相邻日。
    private static func utcFormatter(dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = .current
        return formatter
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
