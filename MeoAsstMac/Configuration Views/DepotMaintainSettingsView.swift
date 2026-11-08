//
//  DepotMaintainSettingsView.swift
//  MAA
//

import SwiftUI

/// 库存保持设置（P12.2：计划编辑器 + 全局开关；预设导入归 P12.5）。
struct DepotMaintainSettingsView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Binding var config: DepotMaintainConfiguration

    @State private var showClearConfirmation = false

    var body: some View {
        Form {
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
            if config.isStageManually || isStoredOutsideCatalog(plan.wrappedValue.stage) {
                TextField("关卡名", text: plan.stage)
            }
            Picker("材料", selection: plan.dropID) {
                Text("未选择").tag("")
                ForEach(FightConfiguration.dropItems, id: \.id) { item in
                    Text(item.item.name).tag(item.id)
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
            }
        }
    }

    private func planTitle(_ index: Int) -> String {
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
