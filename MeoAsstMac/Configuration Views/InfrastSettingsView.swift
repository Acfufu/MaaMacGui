//
//  InfrastSettingsView.swift
//  MeoAsstMac
//
//  Created by hguandl on 9/10/2022.
//

import SwiftUI

struct InfrastSettingsView: View {
    @Environment(\.defaultMinListRowHeight) private var rowHeight
    // 周计划行标签按区服游戏日星期渲染（F06 同源）。
    @EnvironmentObject private var viewModel: MAAViewModel

    @Binding var config: InfrastConfiguration

    var body: some View {
        VStack {
            Form {
                Picker("基建模式", selection: $config.mode) {
                    Text("常规模式").tag(InfrastConfiguration.Mode.default)
                    Text("队列轮换").tag(InfrastConfiguration.Mode.rotation)
                    Text("自定义基建配置").tag(InfrastConfiguration.Mode.custom)
                }
                if config.mode == .custom {
                    customPlanView
                } else {
                    Picker("无人机用途", selection: $config.drones) {
                        ForEach(droneUsages, id: \.self) { usage in
                            Text(usage.description).tag(usage)
                        }
                    }
                }
            }

            Divider()

            HStack(alignment: .top) {
                if config.mode != .rotation {
                    facilityList
                }
                Form {
                    if config.mode != .rotation {
                        Section {
                            Text("基建工作心情阈值: \(config.threshold * 100, specifier: "%.0f")%")
                            Slider(value: $config.threshold, in: 0...1)
                        }
                        Divider()
                    }
                    Section {
                        preferenceForm
                    }
                }
            }
        }
        .animation(.default, value: config.mode)
        .padding()
    }

    @ViewBuilder private var facilityList: some View {
        List {
            Section {
                ForEach(config.facility) { facility in
                    Toggle(facility.description, isOn: facilityBinding(for: facility))
                }
                .onMove { source, destination in
                    config.facility.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("已启用")
            }

            Section {
                ForEach(disabledFacilities) { facility in
                    Toggle(facility.description, isOn: facilityBinding(for: facility))
                }
            } header: {
                Text("未启用")
            }
        }
        .animation(.default, value: config.facility)
        .frame(height: 12 * rowHeight)
    }

    @ViewBuilder private var preferenceForm: some View {
        Toggle("宿舍空余位置蹭信赖", isOn: $config.dorm_trust_enabled)
        Toggle("不将已进驻的干员放入宿舍", isOn: $config.dorm_notstationed_enabled)
        Toggle("源石碎片自动补货", isOn: $config.replenish)
        Toggle("会客室信息板收取信用", isOn: $config.reception_message_board)
        // B08 线索交流/赠送独立开关（Core 缺省双开，关闭才改变会客室行为）。
        Toggle("进行线索交流", isOn: $config.reception_clue_exchange)
        Toggle("赠送线索", isOn: $config.reception_send_clue)
        Toggle("训练完成后继续尝试专精当前技能", isOn: $config.continue_training)
        Divider()
        // B07 跨设施编组：Core 仅常规模式消费（default_mode 门控），非常规
        // 模式下勾选不产生效果，禁用并提示。
        Toggle("使用红松骑士团跨设施组合", isOn: $config.use_pinus_sylvestris)
            .disabled(config.mode != .default)
        Toggle("使用感知信息跨设施组合", isOn: $config.use_perception_information)
            .disabled(config.mode != .default)
        Toggle("使用人间烟火跨设施组合", isOn: $config.use_worldly_plight)
            .disabled(config.mode != .default)
        Toggle("使用深海猎人跨设施组合", isOn: $config.use_abyssal_hunter)
            .disabled(config.mode != .default)
        Text("跨设施编组仅常规模式生效，其他模式保留勾选但不参与排班。")
            .font(.caption).foregroundStyle(.secondary)
        Divider()
        // B13 每周执行日（F06/P06.2 同构：nil=每天，游戏日 04:00 重置）。
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
        Divider()
        fiammettaPreferences
    }

    /// 启用周计划=weeklyDays 非 nil；开启时按上游 WeeklySchedule 缺省全勾选，
    /// 关闭即恢复每天执行（nil 不写键）。
    private var weeklyScheduleEnabled: Binding<Bool> {
        Binding {
            config.weeklyDays != nil
        } set: { on in
            config.weeklyDays = on ? Array(0...6) : nil
        }
    }

    /// 单日勾选：直接改写 weeklyDays 数组（保持升序稳定存储）；全取消时
    /// 空表是「永不执行」的合法显式态，与 F06 防护一致不允许回到 nil。
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

    @ViewBuilder private var fiammettaPreferences: some View {
        Toggle("菲亚梅塔心情恢复", isOn: fiammettaEnabled)
            .disabled(config.mode != .default || config.fiammetta_targets.isEmpty)
        Text("仅常规模式生效，其他模式保留所选偏好。")
            .font(.caption).foregroundStyle(.secondary)
        Text("最多选择3名恢复目标")
            .font(.caption)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
            ForEach(InfrastConfiguration.FiammettaTarget.allCases) { target in
                Toggle(target.title, isOn: fiammettaTarget(target))
                    .disabled(
                        config.mode != .default
                            || (!config.fiammetta_targets.contains(target.rawValue)
                                && config.fiammetta_targets.count >= 3)
                    )
            }
        }
        if config.fiammetta_targets.isEmpty {
            Text("请选择恢复目标后再启用，空名单不会使用默认目标。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fiammettaEnabled: Binding<Bool> {
        Binding {
            config.fiammetta_recovery_enabled
        } set: { enabled in
            config.fiammetta_recovery_enabled = enabled && !config.fiammetta_targets.isEmpty
        }
    }

    private func fiammettaTarget(_ target: InfrastConfiguration.FiammettaTarget) -> Binding<Bool> {
        Binding {
            config.fiammetta_targets.contains(target.rawValue)
        } set: { selected in
            var updated = config
            if selected {
                updated.fiammetta_targets = InfrastConfiguration.normalizedFiammettaTargets(
                    updated.fiammetta_targets + [target.rawValue])
            } else {
                updated.fiammetta_targets.removeAll { $0 == target.rawValue }
                if updated.fiammetta_targets.isEmpty { updated.fiammetta_recovery_enabled = false }
            }
            config = updated
        }
    }

    @ViewBuilder private var customPlanView: some View {
        VStack {
            Picker("方案", selection: customPlan) {
                Section {
                    ForEach(customInfrastPaths, id: \.self) { path in
                        path.label
                    }
                } header: {
                    Text("自定义排班")
                }

                Section {
                    ForEach(String.bundledPlans, id: \.self) { path in
                        path.label
                    }
                } header: {
                    Text("内置排班")
                }
            }

            Picker("班次", selection: $config.plan_index) {
                try? MAAInfrast(path: config.filename).planList
            }
            // B11 时间轮换：任一 plan 带 period 时下发前按当前时刻选班，
            // 这里显示当前命中的班次（无匹配回退第一个，与下发逻辑同源）。
            if let plan = try? MAAInfrast(path: config.filename),
                let rotated = config.resolvedPlanIndex(at: Date.now, plan: plan) {
                Text("时间轮换 (\(plan.plans.indices.contains(rotated) ? (plan.plans[rotated].name ?? "\(rotated)") : "\(rotated)"))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Button("打开自定义排班文件夹…") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: customInfrastDirectory.path)
                }
                Button("重新加载文件") {
                    refreshCustomPlans.toggle()
                }
            }
        }
    }

    // MARK: - State Wrappers

    private var customPlan: Binding<String> {
        Binding {
            config.filename
        } set: {
            config.plan_index = 0
            config.filename = $0
        }
    }

    private var disabledFacilities: [InfrastConfiguration.Facility] {
        InfrastConfiguration.Facility.allCases.filter { facility in
            !config.facility.contains(facility)
        }
    }

    private func facilityBinding(for facility: InfrastConfiguration.Facility) -> Binding<Bool> {
        Binding {
            config.facility.contains(facility)
        } set: { newValue in
            if newValue {
                config.facility.append(facility)
            } else {
                config.facility.removeAll { $0 == facility }
            }
        }
    }

    private var droneUsages: [InfrastConfiguration.DroneUsage] {
        var usages = [InfrastConfiguration.DroneUsage.NotUse]

        if config.mode == .rotation {
            return InfrastConfiguration.DroneUsage.allCases
        } else if config.mode == .custom {
            return usages
        }

        if config.facility.contains(.Mfg) {
            usages.append(contentsOf: [.Chip, .CombatRecord, .OriginStone, .PureGold, .SyntheticJade])
        }

        if config.facility.contains(.Trade) {
            usages.append(.Money)
        }

        return usages
    }

    // MARK: - File Paths

    @State private var refreshCustomPlans = false

    private var customInfrastPaths: [String] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: customInfrastDirectory,
                includingPropertiesForKeys: [.contentTypeKey],
                options: .skipsHiddenFiles)
        else { return [] }

        // Dummy state to force refreshing files
        _ = refreshCustomPlans

        return
            urls
            .filter { url in
                let value = try? url.resourceValues(forKeys: [.contentTypeKey])
                return value?.contentType == .json
            }
            .map(\.path)
    }

    private var customInfrastDirectory: URL {
        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("infrast")

        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        return directory
    }
}

// MARK: - Infrast Plan

extension String {
    fileprivate var label: some View {
        if let plan = try? MAAInfrast(path: self) {
            return Text(plan.title ?? self).tag(self)
        } else {
            return Text("无效文件").tag(self)
        }
    }

    fileprivate static let bundledPlans = [
        plan_153_3, plan_243_3, plan_243_4, plan_252_3, plan_333_3,
    ]

    fileprivate static let plan_153_3 = bundledPath(for: "153_layout_3_times_a_day.json")
    fileprivate static let plan_243_3 = bundledPath(for: "243_layout_3_times_a_day.json")
    fileprivate static let plan_243_4 = bundledPath(for: "243_layout_4_times_a_day.json")
    fileprivate static let plan_252_3 = bundledPath(for: "252_layout_3_times_a_day.json")
    fileprivate static let plan_333_3 = bundledPath(for: "333_layout_for_Orundum_3_times_a_day.json")

    private static func bundledPath(for name: String) -> String {
        Bundle.main.resourceURL?
            .appendingPathComponent("resource")
            .appendingPathComponent("custom_infrast")
            .appendingPathComponent(name)
            .path ?? ""
    }
}

struct InfrastSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        InfrastSettingsView(config: .constant(.init()))
            .environmentObject(MAAViewModel())
    }
}
