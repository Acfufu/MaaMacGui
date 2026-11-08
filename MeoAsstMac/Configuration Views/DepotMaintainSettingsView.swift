//
//  DepotMaintainSettingsView.swift
//  MAA
//

import SwiftUI

/// 库存保持设置（P12.2 计划编辑器 + 全局开关；P12.5 预设导入与计划摘要）。
struct DepotMaintainSettingsView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Binding var config: DepotMaintainConfiguration

    @State private var showClearConfirmation = false
    /// 材料面数据经 @State 承载（FightSettingsView 先例）：initDropItems 在 onAppear
    /// 才填充 static，直接读 static 不触发首渲染后刷新（P12-2-R3 记录-2 收口）。
    @State private var dropItems: [(name: String, id: String)] = []

    var body: some View {
        Form {
            presetSection
            plansSection
            executionSection
            orderBudgetSection
            statisticsSection
        }
        .padding()
        .confirmationDialog("确认清空所有计划？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("清空计划", role: .destructive) { config.plans.removeAll() }
        }
        .onAppear {
            do { try FightConfiguration.initDropItems("zh-cn") }
            catch let err {
                print(String(localized: "Read item_index.json failed: \(err.localizedDescription)"))
            }
            dropItems = FightConfiguration.dropItems.map { (name: $0.item.name, id: $0.id) }
        }
    }

    // MARK: 预设导入（P12.5，upstream Preset SplitButton 同构）

    private var presetSection: some View {
        Section {
            Menu {
                Section("常驻关卡") {
                    ForEach(DepotMaintainPlanner.presetOrder, id: \.self) { key in
                        Button(Self.presetDisplay(key)) { importStaticPreset(key) }
                    }
                }
                if !activityPresets.isEmpty {
                    Section("当期活动") {
                        ForEach(activityPresets, id: \.key) { preset in
                            Button(preset.display) { importActivityPreset(preset.key) }
                        }
                    }
                }
            } label: {
                Text("导入预设")
            }
            if config.skipDuringActivity {
                Text("「活动期间跳过」已开启，导入的计划在活动期间不会执行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("预设")
        }
    }

    /// 快捷导入不干预运行语义：活动跳过开启时仅提示，导入的计划在活动期间不会执行
    /// （upstream PresetActivitySkipConflict 的常驻提示形态）。
    private var activityPresets: [(key: String, display: String)] {
        viewModel.depotActivityPresets()
    }

    private func importStaticPreset(_ key: String) {
        guard let plans = DepotMaintainPlanner.presetPlans(forKey: key) else { return }
        appendPlans(plans)
    }

    private func importActivityPreset(_ key: String) {
        appendPlans(viewModel.depotActivityPresetPlans(forKey: key))
    }

    /// 批量追加计划（upstream AppendPlans 同构：逐条追加，不去重不排序）。
    private func appendPlans(_ plans: [(stage: String, dropID: String, count: Int)]) {
        for plan in plans {
            config.plans.append(DepotMaintainPlan(stage: plan.stage, dropID: plan.dropID, dropCount: plan.count))
        }
    }

    private static func presetDisplay(_ key: String) -> String {
        switch key {
        case "Chip1": String(localized: "低级芯片（全职业）")
        case "Chip2": String(localized: "高级芯片组（全职业）")
        case "CE6": String(localized: "龙门币")
        case "AP5": String(localized: "采购凭证（红票）")
        case "CA5": String(localized: "技巧概要·卷3")
        default: key
        }
    }

    // MARK: 计划（I05 编辑面）

    private var plansSection: some View {
        Section {
            ForEach(config.plans.indices, id: \.self) { index in
                planRow(index: index)
            }
            .onDelete { config.plans.remove(atOffsets: $0) }

            Button("添加计划") {
                config.plans.append(DepotMaintainPlan())
            }
            if !config.plans.isEmpty {
                Button("清空计划", role: .destructive) { showClearConfirmation = true }
            }
            if let info = planInfo {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("计划")
        } footer: {
            Text(config.plans.isEmpty
                 ? "尚未配置计划。每条计划指定关卡与目标材料，达到目标库存即停。"
                 : "按列表顺序逐条评估；缺口在每次运行时按最新库存重算。")
                .font(.caption)
        }
    }

    /// 下标 binding 的越界防护（P06.1 先例）：删除行导致的暂态 stale index 不越界。
    private func planBinding(_ index: Int) -> Binding<DepotMaintainPlan> {
        Binding {
            index < config.plans.count ? config.plans[index] : DepotMaintainPlan()
        } set: {
            guard index < config.plans.count else { return }
            config.plans[index] = $0
        }
    }

    @ViewBuilder
    private func planRow(index: Int) -> some View {
        let plan = planBinding(index)
        DisclosureGroup {
            Picker("关卡", selection: plan.stage) {
                Text("未选择").tag("")
                Section("常用") {
                    Text("1-7").tag("1-7")
                    Text("剿灭模式").tag("Annihilation")
                }
                Section("当期活动") {
                    ForEach(catalog.entries(at: .now).filter { $0.group == .activity }, id: \.code) { entry in
                        Text("\(entry.name)（\(StageDropLabel.text(entry.drop ?? ""))）").tag(entry.code)
                    }
                }
                Section("资源收集") {
                    ForEach(catalog.entries(at: .now).filter { $0.group == .resourceCollection }, id: \.code) { entry in
                        Text(entry.name).tag(entry.code)
                    }
                }
                if isStoredOutsideCatalog(plan.wrappedValue.stage) {
                    Section("存档关卡") {
                        Text(verbatim: plan.wrappedValue.stage).tag(plan.wrappedValue.stage)
                    }
                }
            }
            // P12-8：手输开关（WPF DepotMaintainTaskUserControl.xaml:416 CustomStageCode
            // 同位）——原 isStageManually 全仓零写点，手输 TextField 仅存档关卡过期可达
            // （P12-2-R3 中-1）。Mac Picker/TextField 并存与 WPF 互斥形态差已在 [t](a) 入档。
            Toggle("手动输入关卡名", isOn: $config.isStageManually)
            if config.isStageManually || isStoredOutsideCatalog(plan.wrappedValue.stage) {
                TextField("关卡名", text: plan.stage)
            }
            Picker("材料", selection: plan.dropID) {
                Text("未选择").tag("")
                ForEach(dropItems, id: \.id) { item in
                    Text(verbatim: item.name).tag(item.id)
                }
            }
            TextField("目标数量", value: plan.dropCount, format: .number)
            Toggle("使用药剂", isOn: plan.useMedicine)
                .disabled(!config.useMedicine)
            if plan.useMedicine.wrappedValue && config.useMedicine {
                Stepper(value: plan.medicineCount, in: 0...999) {
                    Text("药剂预算：\(plan.wrappedValue.medicineCount)")
                }
            }
            Toggle("使用源石", isOn: plan.useStone)
                .disabled(!config.useStone)
            if plan.useStone.wrappedValue && config.useStone {
                Stepper(value: plan.stoneCount, in: 0...99) {
                    Text("源石预算：\(plan.wrappedValue.stoneCount)")
                }
            }
        } label: {
            HStack {
                Text(verbatim: planTitle(index))
                    .font(.subheadline)
                Spacer()
                // P12-[w]（快照 82 清单②裁定：随 WPF 对齐，2026-11-09）：行内
                // 上/下移按钮——WPF dd:DragDrop 拖拽重排（xaml:121-123，S8-1-R3
                // 低-4 行号勘正）的可达重排入口；macOS Form 的 List 拖拽 onMove
                // 行为随平台版本不稳（P11.4 安慰剂先例），取确定性按钮形态，
                // I05「顺序」腿真实可达。
                Button {
                    guard index > 0, index < config.plans.count else { return }
                    config.plans.swapAt(index, index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index <= 0 || index >= config.plans.count)
                .accessibilityLabel(Text("上移"))
                Button {
                    guard index >= 0, index < config.plans.count - 1 else { return }
                    config.plans.swapAt(index, index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index < 0 || index >= config.plans.count - 1)
                .accessibilityLabel(Text("下移"))
                // P12-8：行内删除按钮（WPF DepotMaintainTaskUserControl.xaml:159-176
                // DeleteTaskGeometry 行内按钮同位）——原 .onDelete 在 macOS List/Form
                // 无触发 UI，删腿不可达（P12-2-R3 高-1）。borderless 防整行误触。
                Button(role: .destructive) {
                    guard index < config.plans.count else { return }
                    config.plans.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("删除计划"))
            }
        }
    }

    private func planTitle(_ index: Int) -> String {
        // 越界防护（P06.1 先例同款）：删除行导致的暂态 stale index 不越界（P12-2-R3 记录-3 收口）。
        guard index < config.plans.count else { return "" }
        let plan = config.plans[index]
        let stage = plan.stage.isEmpty ? String(localized: "未选择") : plan.stage
        let drop = FightConfiguration.dropItems.first { $0.id == plan.dropID }?.item.name
            ?? (plan.dropID.isEmpty ? String(localized: "未选择") : plan.dropID)
        return "\(index + 1). \(stage) - \(drop) ×\(plan.dropCount)"
    }

    private func isStoredOutsideCatalog(_ code: String) -> Bool {
        let known = ["", "1-7", "Annihilation"] + catalog.entries(at: .now).map(\.code)
        return !known.contains(code)
    }

    // 与 FightSettingsView 同源判定（P05.2）：提示与可选关卡共用同一 StageCatalog。
    private var catalog: StageCatalog {
        StageCatalog(context: StageActivityContext(
            channel: viewModel.clientChannel,
            activities: viewModel.stageActivity))
    }

    /// 计划摘要（upstream PlanInfo 同构）：「N: 关卡 - 材料 当前/目标」逐行。
    private var planInfo: String? {
        DepotMaintainPlanner.planInfo(
            for: config,
            inventory: viewModel.currentInventorySnapshot?.items,
            chipConversion: config.countDualChipAsChipPack,
            formulas: FightConfiguration.dropFormulaTable,
            dropName: { id in
                FightConfiguration.dropItems.first { $0.id == id }?.item.name
                    ?? (id.isEmpty ? String(localized: "未选择") : id)
            },
            stageDisplay: { code in
                code.isEmpty ? String(localized: "未选择")
                    : (catalog.entries(at: .now).first { $0.code == code }?.name ?? code)
            })
    }

    // MARK: 执行

    private var executionSection: some View {
        Section {
            Toggle("执行前更新仓库数据", isOn: $config.updateDepot)
            Toggle("活动期间跳过", isOn: $config.skipDuringActivity)
            Toggle("资源全开放期间跳过", isOn: $config.skipDuringResourceCollection)
        } header: {
            Text("执行")
        } footer: {
            Text("开启活动/资源跳过后，对应期间整个任务不会下发，计划配置保持不变。")
                .font(.caption)
        }
    }

    // MARK: 顺序与预算（I06/I09/I12）

    private var orderBudgetSection: some View {
        Section("顺序与预算") {
            Toggle("仅执行第一个不足计划", isOn: $config.onlyFirstInsufficientPlan)
            Toggle("按库存达成率排序", isOn: $config.sortByProgress)
            if config.onlyFirstInsufficientPlan && config.sortByProgress {
                Text("两个策略同时开启时，先按达成率排序，再执行排序后的第一个不足计划。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("使用药剂", isOn: $config.useMedicine)
            Toggle("使用源石", isOn: $config.useStone)
            Toggle("使用临期理智药（48 小时内）", isOn: $config.useExpiringMedicine)
            Toggle("AUTO 代理倍率", isOn: $config.useAutoSeries)
        }
    }

    // MARK: 统计（I10）

    private var statisticsSection: some View {
        Section {
            Toggle("双芯片折算计入芯片组", isOn: $config.countDualChipAsChipPack)
        } header: {
            Text("统计")
        } footer: {
            Text("开启后每个双芯片按配方折算为 2 个对应芯片组参与达标判定，不会自动合成。")
                .font(.caption)
        }
    }
}
