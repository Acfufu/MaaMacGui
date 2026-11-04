//
//  FightSettingsView.swift
//  MeoAsstMac
//
//  Created by hguandl on 9/10/2022.
//

import SwiftUI

struct FightSettingsView: View {
    @Binding var config: FightConfiguration
    @EnvironmentObject private var viewModel: MAAViewModel

    @State private var useCustomStage = false
    @State private var dropItemList: [(name: String, id: String)] = []
    // 当前资源支持的连战倍率上限,onAppear/换服时按已加载资源刷新
    @State private var seriesUpperBound = 10

    var body: some View {
        ScrollView {
            Form {
                Section {
                    HStack(spacing: 20) {
                        if useCustomStage || stageNotListed {
                            TextField("关卡名", text: $config.stage)
                        } else {
                            TimelineView(.everyMinute) { timeline in
                                Picker("关卡选择", selection: $config.stage) {
                                    Section("常用") {
                                        Text("当前/上次").tag("")
                                        Text("1-7").tag("1-7")
                                        Text("剿灭模式").tag("Annihilation")
                                    }
                                    Section("当期活动") {
                                        ForEach(
                                            stageCatalog.openEntries(at: timeline.date)
                                                .filter { $0.group == .activity }, id: \.code
                                        ) { entry in
                                            Text(activityEntryTitle(entry)).tag(entry.code)
                                        }
                                    }
                                    Section("今日资源收集") {
                                        ForEach(
                                            stageCatalog.openEntries(at: timeline.date)
                                                .filter { $0.group == .resourceCollection }, id: \.code
                                        ) { entry in
                                            Text(entry.name).tag(entry.code)
                                        }
                                    }
                                }
                            }
                        }
                        Toggle("手动输入关卡名", isOn: isUsingCustomStage)
                    }
                    .animation(.default, value: config.stage)
                }

                if useCustomStage || stageNotListed {
                    Text("<无忧梦呓>请使用特殊关卡名，如AveMujica-8").foregroundStyle(.secondary)
                }
                if let closedStageHint {
                    Text(closedStageHint).foregroundStyle(.secondary)
                }

                // MARK: 关卡重置策略（F20）

                Picker("关卡轮换后", selection: $config.stageResetMode) {
                    Text("保留原值").tag(FightStageResetMode.ignore)
                    Text("重置为当前/上次").tag(FightStageResetMode.current)
                }
                Text("主选关卡已不在目录（活动轮换）时的处理；启用备选关卡时由备选顺序接管。")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()

                // MARK: 备选关卡（F05）：候选开放判定与可选目录同源（StageCatalog）

                Section {
                    Toggle("启用备选关卡", isOn: $config.useOptionalStage)
                    if config.useOptionalStage {
                        Text("自上而下执行第一个开放的候选；全部关闭时跳过本任务。常驻候选之后的备选不会执行。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(config.optionalStages.indices, id: \.self) { index in
                            HStack {
                                TimelineView(.everyMinute) { timeline in
                                    Picker("备选\(index + 1)", selection: optionalStageBinding(index)) {
                                        optionalStagePickerEntries(
                                            at: timeline.date, stored: optionalStageStored(index))
                                    }
                                }
                                Button {
                                    guard index < config.optionalStages.count else { return }
                                    _ = config.optionalStages.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button {
                            config.optionalStages.append("")
                        } label: {
                            Label("添加备选关卡", systemImage: "plus")
                        }
                        TimelineView(.everyMinute) { timeline in
                            optionalStageStatus(at: timeline.date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // MARK: 每周执行日（F06）：按区服游戏日判定，未勾选的星期跳过

                Section {
                    Toggle("启用周计划", isOn: weeklyScheduleEnabled)
                    if config.weeklyDays != nil {
                        ForEach(0...6, id: \.self) { day in
                            Toggle(
                                viewModel.clientChannel.calendar.weekdaySymbol(at: day),
                                isOn: weeklyDayBinding(day))
                        }
                        Text("按区服游戏日（每日 04:00 重置）判定，未勾选的星期自动跳过本任务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Section {
                    TextField(value: $config.medicine, format: .number) {
                        Toggle("吃理智药", isOn: useMedicine)
                    }

                    if config.medicine != nil {
                        Toggle("理智药仅一次", isOn: $config.medicineOnce)
                            .help("完整成功的运行结束后自动清除理智药设置；失败或取消不消耗")
                    }

                    TextField(value: $config.stone, format: .number) {
                        Toggle("吃源石", isOn: useStone)
                    }

                    if config.stone != nil {
                        Toggle("源石仅一次", isOn: $config.stoneOnce)
                            .help("完整成功的运行结束后自动清除源石设置；失败或取消不消耗")
                    }

                    TextField(value: $config.times, format: .number) {
                        Toggle("指定次数", isOn: limitBattles)
                    }

                    Picker(selection: $config.series) {
                        Text(verbatim: "AUTO").tag(0)
                        ForEach((1...seriesUpperBound).reversed(), id: \.self) { i in
                            Text(verbatim: "\(i)").tag(i)
                        }
                        if let stored = config.series, stored > seriesUpperBound {
                            // 换旧资源后保留超限存量值,避免选项失配
                            Text(verbatim: "\(stored)").tag(stored)
                        }
                        Text("保留当前").tag(-1)
                        Text("不使用").tag(Int?.none)
                    } label: {
                        Toggle("连战次数", isOn: seriesBattles)
                    }
                    .onAppear { refreshSeriesUpperBound() }
                    .onChange(of: viewModel.clientChannel) { refreshSeriesUpperBound() }
                    if config.series == nil || config.series == -1 {
                        // Core 契约:省略 series 时 params.get("series",1) 切至单倍;-1 才是保留当前
                        Text("保留当前沿用游戏内倍率；不使用为单倍连战")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if seriesUpperBound < 10 {
                        Text("当前资源为旧版倍率界面，最高支持 6 倍连战")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Section {
                    Toggle("Inventory.TargetMode", isOn: inventoryTargetEnabled)
                    if config.inventoryTarget != nil {
                        Picker("Inventory.Material", selection: inventoryItemID) {
                            Text("Inventory.SelectMaterial").tag("")
                            ForEach(FightConfiguration.inventoryDropItems, id: \.id) { item in
                                Text(item.item.name).tag(item.id)
                            }
                        }
                        TextField("Inventory.TargetQuantity", value: inventoryQuantity, format: .number)
                        if let snapshot = viewModel.currentInventorySnapshot {
                            LabeledContent("Inventory.CapturedAt", value: snapshot.capturedAt.formatted(date: .numeric, time: .shortened))
                            LabeledContent("Inventory.CurrentQuantity", value: String(snapshot.items[config.inventoryTarget?.itemID ?? ""] ?? 0))
                        } else {
                            Text("Inventory.RecognitionRequired").foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Inventory.SessionNotice").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Inventory.ChangeAccount") { viewModel.invalidateInventory() }
                    }
                }

                Section {
                    Picker(selection: dropItemIdx) {
                        Text("").tag(nil as Int?)
                        ForEach(Array(zip(dropItemList.indices, dropItemList)), id: \.0) {
                            Text($1.0).tag($0 as Int?)
                        }
                    } label: {
                        Toggle("指定材料", isOn: dropItemToggle)
                    }
                    if dropItemToggle.wrappedValue {
                        TextField(value: dropItemCount, format: .number) {
                            Text("刷取数量")
                        }
                    }
                }
                .disabled(config.inventoryTarget != nil)
                .onAppear {
                    do {
                        try FightConfiguration.initDropItems("zh-cn")
                    } catch let err {
                        print(String(localized: "Read item_index.json failed: \(err.localizedDescription)"))
                    }
                    dropItemList = FightConfiguration.dropItems.map {
                        (name: $0.item.name, id: $0.id)
                    }
                    dropItem = config.drops?.first
                }

                Divider()

            Section {
                LabeledContent {
                    Text(config.localizedExpiry)
                } label: {
                    Stepper("吃临期理智药", value: $config.medicine_expire_days, in: 0...7, step: 1)
                }
                Toggle("活动结束前使用本周临期药", isOn: $config.useActivityMedicine)
                if config.useActivityMedicine {
                    Text("仅活动结束前不足 48 小时生效，使用本周结束前到期的药。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        activityMedicineStatus(at: timeline.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("博朗台碎石模式", isOn: $config.DrGrandet)
            }

            Divider()

            TextField(text: $config.penguin_id) {
                Toggle("企鹅物流汇报ID", isOn: $config.report_to_penguin)
            }

            Divider()

            DailyStageTipView(channel: viewModel.clientChannel, activities: viewModel.stageActivity)
            }
            .padding()
            .animation(.default, value: useCustomStage)
        }
    }

    private var inventoryTargetEnabled: Binding<Bool> {
        Binding { config.inventoryTarget != nil } set: { enabled in
            config.inventoryTarget = enabled ? InventoryTarget(itemID: "", quantity: 20) : nil
        }
    }

    private var inventoryItemID: Binding<String> {
        Binding { config.inventoryTarget?.itemID ?? "" } set: { config.inventoryTarget?.itemID = $0 }
    }

    private var inventoryQuantity: Binding<Int> {
        Binding { config.inventoryTarget?.quantity ?? 0 } set: { config.inventoryTarget?.quantity = $0 }
    }

    @ViewBuilder private func activityMedicineStatus(at date: Date) -> some View {
        let context = StageActivityContext(channel: viewModel.clientChannel, activities: viewModel.stageActivity)
        switch context.medicineWindow(at: date, enabled: config.useActivityMedicine) {
        case .unavailable:
            Text("活动数据不可用，沿用原临期药设置")
        case .inactive:
            Text("当前不在活动临期窗口，沿用原临期药设置")
        case .extended:
            Text("当前有效临期药窗口：\(config.params(at: date, stageActivity: context).medicine_expire_days) 天（包含当天）")
        }
    }

    private var useMedicine: Binding<Bool> {
        Binding {
            config.medicine != nil
        } set: {
            config.medicine = $0 ? 999 : nil
        }
    }

    private var useStone: Binding<Bool> {
        Binding {
            config.stone != nil
        } set: {
            config.stone = $0 ? 0 : nil
        }
    }

    private var limitBattles: Binding<Bool> {
        Binding {
            config.times != nil
        } set: {
            config.times = $0 ? 5 : nil
        }
    }

    private var seriesBattles: Binding<Bool> {
        Binding {
            config.series != nil
        } set: {
            config.series = $0 ? 0 : nil
        }
    }

    // 根解析提升为 CoreCapabilities.effectiveResourceRoot（R2-1）：与
    // MAAViewModel 的能力推导共用同一覆盖层感知口径，国际服读 global 覆盖层。
    private func refreshSeriesUpperBound() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let preferUser = (try? viewModel.resourceChannel.version())?.0 ?? false
        let root = CoreCapabilities.effectiveResourceRoot(
            channel: viewModel.clientChannel,
            cacheRoot: documents.appendingPathComponent("cache"),
            userRoot: preferUser ? documents : nil,
            bundleRoot: Bundle.main.resourceURL!
        )
        seriesUpperBound = FightConfiguration.seriesUpperBound(resourceRoot: root)
    }

    @State private var dropItem: (String, Int)? = nil {
        didSet {
            if dropItemToggle.wrappedValue {
                config.drops =
                    if let dropItem {
                        [dropItem.0: dropItem.1]
                    } else {
                        nil
                    }
            }
        }
    }

    private var dropItemIdx: Binding<Int?> {
        Binding {
            guard let id = dropItem?.0 else { return nil }
            return FightConfiguration.id2index[id]
        } set: {
            dropItem =
                if let idx = $0 {
                    (dropItemList[idx].id, dropItemCount.wrappedValue)
                } else {
                    nil
                }
        }
    }

    private var dropItemCount: Binding<Int> {
        Binding {
            dropItem?.1 ?? 5
        } set: {
            guard dropItem != nil else { return }
            dropItem!.1 = $0
        }
    }

    private var dropItemToggle: Binding<Bool> {
        Binding {
            config.drops != nil
        } set: {
            config.drops =
                if $0 {
                    if let dropItem { [dropItem.0: dropItem.1] } else { nil }
                } else {
                    nil
                }
        }
    }

    private var isUsingCustomStage: Binding<Bool> {
        Binding {
            useCustomStage || stageNotListed
        } set: { newValue in
            if !newValue {
                config.stage = ""
            }
            useCustomStage = newValue
        }
    }

    private var stageNotListed: Bool { !openStageCodes.contains(config.stage) }

    // MARK: 关卡目录（P05.2）：提示与可选关卡共用同一 StageCatalog 判定源

    private var stageCatalog: StageCatalog {
        StageCatalog(context: StageActivityContext(
            channel: viewModel.clientChannel,
            activities: viewModel.stageActivity))
    }

    /// 今日可选代码集：目录开放项 + 常驻主线 1-7（主线无数据源，保留常驻项与手输）。
    private var openStageCodes: Set<String> {
        var codes = Set(stageCatalog.openEntries(at: .now).map(\.code))
        codes.insert("1-7")
        return codes
    }

    /// F04：存量选择今日关闭（目录内但未开放）的可见提示；目录外关卡不打扰。
    private var closedStageHint: String? {
        guard !useCustomStage, !config.stage.isEmpty else { return nil }
        let entry = stageCatalog.entries(at: .now).first { $0.code == config.stage }
        guard let entry, !entry.isOpen else { return nil }
        return String(localized: "「\(config.stage)」今日未开放，已切换为手动输入；可保留原值或改选其他关卡。")
    }

    private func activityEntryTitle(_ entry: StageCatalog.Entry) -> String {
        guard let drop = entry.drop else { return entry.name }
        return "\(entry.name)（\(StageDropLabel.text(drop))）"
    }

    // MARK: 备选关卡（F05/P06.1）

    /// 下标 binding 的越界防护：删除行导致的暂态 stale index 不得越界崩库
    /// （评审 A #4；仓库先例 TaskTimerView 为裸下标，此处收紧）。
    private func optionalStageBinding(_ index: Int) -> Binding<String> {
        Binding {
            index < config.optionalStages.count ? config.optionalStages[index] : ""
        } set: {
            guard index < config.optionalStages.count else { return }
            config.optionalStages[index] = $0
        }
    }

    /// P06.2 R2 残留①收口：`stored:` 参数与 selection binding 同源走越界防护，
    /// 删除行后的暂态 stale index 不再直接下标存档数组。
    private func optionalStageStored(_ index: Int) -> String {
        index < config.optionalStages.count ? config.optionalStages[index] : ""
    }

    // MARK: 每周执行日（F06/P06.2）

    /// 启用周计划=weeklyDays 非 nil；开启时按上游 WeeklySchedule 缺省全勾选
    /// （7 天全选），关闭即恢复每天执行（nil 不写键）。
    private var weeklyScheduleEnabled: Binding<Bool> {
        Binding {
            config.weeklyDays != nil
        } set: { on in
            config.weeklyDays = on ? Array(0...6) : nil
        }
    }

    /// 单日勾选：直接改写 weeklyDays 数组（保持升序稳定存储）；行仅在启用时
    /// 渲染，stale index 无从产生。
    private func weeklyDayBinding(_ day: Int) -> Binding<Bool> {
        Binding {
            config.weeklyDays?.contains(day) ?? false
        } set: { on in
            var days = config.weeklyDays ?? []
            if on {
                if !days.contains(day) { days.append(day) }
            } else {
                days.removeAll { $0 == day }
            }
            config.weeklyDays = days.sorted()
        }
    }

    /// 备选候选列表：与主选单不同，收录今日关闭的目录关卡并加标注——
    /// 备选的意义正是跨日回退（如资源收集轮换）。存档中已不在目录的遗留
    /// 候选（如已轮换活动码）单独成组兜底展示，值不丢失。
    @ViewBuilder private func optionalStagePickerEntries(at date: Date, stored: String) -> some View {
        Section("常用") {
            Text("当前/上次").tag("")
            Text("1-7").tag("1-7")
            Text("剿灭模式").tag("Annihilation")
        }
        Section("当期活动") {
            ForEach(stageCatalog.entries(at: date).filter { $0.group == .activity }, id: \.code) { entry in
                Text(optionalStageTitle(entry)).tag(entry.code)
            }
        }
        Section("资源收集") {
            ForEach(stageCatalog.entries(at: date).filter { $0.group == .resourceCollection }, id: \.code) { entry in
                Text(optionalStageTitle(entry)).tag(entry.code)
            }
        }
        if isStoredOutsideCatalog(stored, at: date) {
            Section("存档关卡") {
                Text(verbatim: stored).tag(stored)
            }
        }
    }

    private func isStoredOutsideCatalog(_ code: String, at date: Date) -> Bool {
        let known = ["", "1-7", "Annihilation"]
            + stageCatalog.entries(at: date).map(\.code)
        return !known.contains(code)
    }

    private func optionalStageTitle(_ entry: StageCatalog.Entry) -> String {
        var title = entry.group == .activity ? activityEntryTitle(entry) : entry.name
        if !entry.isOpen { title += String(localized: "（今日关闭）") }
        return title
    }

    @ViewBuilder private func optionalStageStatus(at date: Date) -> some View {
        let resolution = config.resolvedStagePlan(at: date, catalog: stageCatalog)
        switch resolution.outcome {
        case .dispatch(let code):
            Text("今日将执行：\(code.isEmpty ? String(localized: "当前/上次") : code)")
            if let blocked = resolution.truncatedAfter {
                Text("「\(blocked)」之后的备选不会执行")
            }
        case .skipAllClosed:
            Text("今日全部候选关闭，运行时将跳过本任务")
        }
    }
}

struct FightSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        FightSettingsView(config: .constant(.init()))
            .environmentObject(MAAViewModel())
    }
}
