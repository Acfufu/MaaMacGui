//
//  DepotMaintainSettingsView.swift
//  MAA
//

import SwiftUI

/// 库存保持设置（P12.1：全局开关面；计划编辑与预设导入随 P12.2/P12.5 扩展）。
struct DepotMaintainSettingsView: View {
    @Binding var config: DepotMaintainConfiguration

    var body: some View {
        Form {
            Section("计划") {
                Text(config.plans.isEmpty
                     ? "尚未配置计划。每条计划指定关卡与目标材料，达到目标库存即停。"
                     : "已配置 \(config.plans.count) 项计划。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
            Section {
                Toggle("双芯片折算计入芯片组", isOn: $config.countDualChipAsChipPack)
            } header: {
                Text("统计")
            } footer: {
                Text("开启后每个双芯片按配方折算为 2 个对应芯片组参与达标判定，不会自动合成。")
                    .font(.caption)
            }
        }
        .padding()
    }
}
