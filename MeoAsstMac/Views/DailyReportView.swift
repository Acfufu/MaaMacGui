//
//  DailyReportView.swift
//  MAA
//
//  作战日报（WPF DailyReportDialogView 同构）：日历/柱状图/热力图/单件理智排名。
//  WPF 的 WPFToolkit 图表面以原生 SwiftUI 重写；柱状图叠加线以独立比例绘制，
//  图例明示右轴上限（WPF 双轴语义的 macOS 对应面）。
//

import SwiftUI

struct DailyReportView: View {
    @StateObject private var model = DailyReportViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statsRow
            if model.isChartDisplayed {
                chartCard
            }
            recordCard
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 620)
        .alert(
            String(localized: "警告"),
            isPresented: Binding(
                get: { model.retentionConfirmation != nil },
                set: { if !$0 { model.cancelRetention() } }
            ),
            actions: {
                Button("继续", role: .destructive) { model.confirmRetention() }
                Button("取消", role: .cancel) { model.cancelRetention() }
            },
            message: {
                Text(model.retentionConfirmation?.message ?? "")
            }
        )
        .onAppear {
            model.resetWindowLifetimeState()
        }
    }

    // MARK: - 头部（维度/翻页/日期/保留档位）

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("作战日报")
                    .font(.title2.bold())
                Spacer()
                Picker("保留时间", selection: retentionBinding) {
                    ForEach(DailyReportRetention.allCases) { retention in
                        Text(retentionLabel(retention)).tag(retention)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .help("日报数据按游戏日保留，超期自动删除")
            }

            HStack {
                Picker("", selection: $model.dimension) {
                    Text("日").tag(DailyReportViewModel.Dimension.day)
                    Text("周").tag(DailyReportViewModel.Dimension.week)
                    Text("月").tag(DailyReportViewModel.Dimension.month)
                    Text("年").tag(DailyReportViewModel.Dimension.year)
                    Text("全部").tag(DailyReportViewModel.Dimension.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                if model.dimension.isPageable {
                    HStack(spacing: 4) {
                        Button {
                            model.goPrevious()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .help("上一时段")

                        Text(model.periodLabel)
                            .monospacedDigit()
                            .frame(minWidth: 150)

                        Button {
                            model.goNext()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!model.canGoNext)
                        .help("下一时段")

                        Button("今天") {
                            model.goToday()
                        }
                        .help("回到包含今日的时段")

                        DatePicker(
                            "选择日期",
                            selection: dateBinding,
                            in: ...model.today,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .help("选择日期")
                    }
                } else {
                    Text(model.periodLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 保留档位绑定：变更时走确认流程（有超期记录时视图弹确认框）。
    private var retentionBinding: Binding<DailyReportRetention> {
        Binding(
            get: { model.selectedRetention },
            set: { model.changeRetention(to: $0) })
    }

    /// 日期绑定：DatePicker 产出本地日历当日，需换算为游戏日锚点。
    private var dateBinding: Binding<Date> {
        Binding(
            get: { model.anchor },
            set: { model.jumpTo(model.calendarAnchor(fromLocal: $0)) })
    }

    private func retentionLabel(_ retention: DailyReportRetention) -> String {
        switch retention {
        case .day: "近 1 日"
        case .week: "近 1 周"
        case .month: "近 1 月"
        case .year: "近 1 年"
        case .unlimited: "不限制"
        }
    }

    // MARK: - 统计块

    private var statsRow: some View {
        HStack(spacing: 16) {
            ForEach(model.stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.value)
                        .font(.title3.bold())
                        .monospacedDigit()
                    Text(stat.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - 图表卡片

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.chartTitle)
                    .font(.headline)
                if model.isYearView {
                    Picker("", selection: $model.isHeatmapMode) {
                        Text("热力图").tag(true)
                        Text("柱状图").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                } else if model.canRank && model.isMaterialView {
                    Picker("", selection: $model.isRankMode) {
                        Text("趋势").tag(false)
                        Text("关卡排名").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Spacer()

                if model.hasOverlay && model.selectedItemId == nil {
                    overlayLegend
                }

                Button {
                    model.toggleChartCollapsed()
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .buttonStyle(.borderless)
                .help("折叠或展开图表")
            }

            if model.isRankMode, model.selectedItemId != nil {
                rankCard
            } else if model.isYearView && model.isHeatmapMode {
                heatmap
            } else {
                barChart
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var overlayLegend: some View {
        HStack(spacing: 12) {
            if model.medicineLine?.isVisible == true {
                Label("药剂", systemImage: "line.diagonal")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if model.stoneLine?.isVisible == true {
                Label("源石", systemImage: "line.diagonal")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            if !model.overlayAxisMaxText.isEmpty {
                Text("右轴上限 \(model.overlayAxisMaxText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 柱状图（含药剂/源石叠加线；WPF 双轴的 macOS 对应：叠加线独立归一，图例标注右轴上限）。
    private var barChart: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let count = max(model.chartBars.count, 1)
                let slot = geometry.size.width / CGFloat(count)
                let plotHeight = geometry.size.height - 18
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(model.chartBars) { bar in
                            VStack(spacing: 2) {
                                if !bar.valueText.isEmpty && bar.ratio > 0 {
                                    Text(bar.valueText)
                                        .font(.caption2)
                                        .monospacedDigit()
                                }

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(height: max(2, plotHeight * bar.ratio))
                            }
                            .frame(width: slot * 0.72, height: plotHeight, alignment: .bottom)
                            .frame(width: slot)
                            .help(bar.toolTip)
                        }
                    }

                    overlayLines(width: geometry.size.width, height: plotHeight)
                }
                .frame(height: plotHeight, alignment: .bottom)
            }
            .frame(height: 220)

            HStack(spacing: 0) {
                ForEach(model.chartBars) { bar in
                    Text(bar.tick)
                        .font(.caption2)
                        .foregroundStyle(bar.isMajor ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 药剂/源石叠加折线（独立右轴比例；nil 点之后不再绘制）。
    private func overlayLines(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            overlayPath(model.medicineLine, width: width, height: height)
                .stroke(Color.orange, lineWidth: 1.5)
            overlayPath(model.stoneLine, width: width, height: height)
                .stroke(Color.purple, lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    private func overlayPath(_ line: DailyReportViewModel.OverlayLine?, width: CGFloat, height: CGFloat) -> Path {
        guard let line, line.isVisible else { return Path() }
        let count = max(line.points.count, 1)
        let slot = width / CGFloat(count)
        var path = Path()
        var started = false
        for (index, point) in line.points.enumerated() {
            guard let point else {
                started = false
                continue
            }

            let x = slot * (CGFloat(index) + 0.5)
            let y = height * (1 - min(CGFloat(point), 1))
            if started {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            }
        }

        return path
    }

    /// 年度热力图：每列一周、周一在上，四分位四档色；点击格子跳到当天日视图。
    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        ForEach(model.heatMonthLabels) { label in
                            Text(label.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .offset(x: CGFloat(label.column) * 18)
                        }
                    }
                    .frame(width: CGFloat(model.heatColumns) * 18, height: 14, alignment: .topLeading)

                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(18), spacing: 2), count: 7), spacing: 2) {
                        ForEach(model.heatCells) { cell in
                            Group {
                                if let date = cell.date {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(heatColor(cell.level))
                                        .onTapGesture {
                                            model.jumpTo(date)
                                            model.dimension = .day
                                        }
                                        .help(cell.toolTip ?? "")
                                } else {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.clear)
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                    }
                }
            }
        }
    }

    private func heatColor(_ level: Int) -> Color {
        switch level {
        case 0: Color.accentColor.opacity(0.12)
        case 1: Color.accentColor.opacity(0.3)
        case 2: Color.accentColor.opacity(0.55)
        case 3: Color.accentColor.opacity(0.8)
        default: Color.accentColor
        }
    }

    // MARK: - 关卡排名卡片

    private var rankCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("单件理智")
                    .font(.subheadline.bold())
                Text(model.rankScopeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !model.rankHistoryBestText.isEmpty {
                Text(model.rankHistoryBestText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.rankRows) { row in
                HStack(spacing: 8) {
                    Text(row.stage)
                        .font(.callout.monospaced())
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // 误差带：从比例下界画到上界。
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(row.isReliable ? 0.25 : 0.15))
                                .frame(width: geometry.size.width * (row.barUpper - row.barLower))
                                .offset(x: geometry.size.width * row.barLower)
                            // 实心部分画到置信区间的比例下界（单件理智取区间上限）。
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row.isReliable ? Color.accentColor : Color.secondary)
                                .frame(width: geometry.size.width * row.barLower)
                        }
                    }
                    .frame(height: 12)
                    .help(row.toolTip)

                    Text(row.valueText)
                        .font(.callout.monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                    Text(row.errorText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(row.isReliable ? .primary : .secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(row.isHighlighted ? Color.accentColor.opacity(0.15) : .clear))
            }
        }
    }

    // MARK: - 记录卡片

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $model.isMaterialView) {
                    Text("按关卡").tag(false)
                    Text("按材料").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
            }

            if model.rows.isEmpty && model.materials.isEmpty {
                Text("暂无作战记录")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else if model.isMaterialView {
                materialGrid
            } else {
                sessionRows
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sessionRows: some View {
        List(model.rows) { row in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.stage.isEmpty ? "—" : row.stage)
                        .font(.headline)
                    if !row.timeText.isEmpty {
                        Text(row.timeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    Text(row.metaText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !row.drops.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(sortedDrops(row.drops), id: \.itemId) { drop in
                            DropChip(itemId: drop.itemId, count: drop.count, times: row.times, stage: row.stage, model: model) {
                                model.showRanking(itemId: drop.itemId, stage: row.stage)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private func sortedDrops(_ drops: [String: Int]) -> [(itemId: String, count: Int)] {
        drops
            .map { (itemId: $0.key, count: $0.value) }
            .sorted {
                let lhsSort = DailyReportViewModel.itemSortId($0.itemId)
                let rhsSort = DailyReportViewModel.itemSortId($1.itemId)
                if lhsSort != rhsSort {
                    return lhsSort < rhsSort
                }

                return $0.itemId < $1.itemId
            }
    }

    /// 按材料视图：物品网格（游戏物品顺序），点击切换柱状图展示的物品。
    private var materialGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(model.materials) { material in
                    Button {
                        model.toggleMaterial(material.id)
                    } label: {
                        HStack {
                            Text(material.name)
                                .lineLimit(1)
                            Spacer()
                            Text(DailyReportViewModel.RankRow.grouped(material.sources.values.reduce(0, +)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(material.isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                    .help(material.sources.sorted { $0.value > $1.value }.map { "\($0.key) ×\(DailyReportViewModel.RankRow.grouped($0.value))" }.joined(separator: "\n"))
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// 掉落芯片：物品名 ×数量，点击弹出该物品在本关的掉率排名摘要并可跳转关卡排名。
private struct DropChip: View {
    let itemId: String
    let count: Int
    let times: Int
    let stage: String
    let model: DailyReportViewModel
    let onRank: () -> Void

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 3) {
                Text(DailyReportViewModel.itemName(itemId))
                    .lineLimit(1)
                Text("×\(DailyReportViewModel.RankRow.grouped(count))")
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            DropPopover(model: model, itemId: itemId, count: count, times: times, stage: stage, onRank: {
                showPopover = false
                onRank()
            })
        }
    }
}

/// 掉率浮层：本关掉落、每场掉落与该物品的关卡排名摘要、跳转入口（WPF 掉率浮层同构）。
private struct DropPopover: View {
    let model: DailyReportViewModel
    let itemId: String
    let count: Int
    let times: Int
    let stage: String
    let onRank: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DailyReportViewModel.itemName(itemId))
                .font(.headline)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每场掉落")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(times > 0 ? DailyReportViewModel.RankRow.rateText(Double(count) / Double(times)) : "—")
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("单件理智")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let summary = model.buildRankSummary(itemId: itemId, stage: stage)
                    Text(summary.isEmpty ? "—" : summary)
                        .font(.caption)
                }
            }

            Button("查看该材料在各关卡的单件理智排名") {
                onRank()
            }
        }
        .padding(12)
        .frame(minWidth: 300)
    }
}

#Preview {
    DailyReportView()
}
