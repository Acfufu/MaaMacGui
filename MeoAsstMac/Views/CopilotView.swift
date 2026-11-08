//
//  CopilotView.swift
//  MAA
//
//  Created by hguandl on 19/4/2023.
//

import SwiftUI

struct CopilotView: View {
    let context: CopilotContext
    @Environment(NewViewModel.self) private var newModel

    var body: some View {
        @Bindable var context = context
        if context.category == .list {
            if let set = context.copilotSet {
                switch context.content {
                case .copilot(_, let kind, let copilot):
                    CopilotConfigView(
                        kind: kind, config: $context.config,
                        userAdditionalEnabled: $context.enableUserAdditional
                    ) {
                        CopilotDescriptionView(pilot: copilot)
                    }
                case .invalid:
                    Text("文件格式错误")
                case .pending:
                    ProgressView().controlSize(.small)
                default:
                    CopilotConfigView(
                        kind: set.kind, config: $context.config,
                        userAdditionalEnabled: $context.enableUserAdditional
                    ) {
                        CopilotSetDescriptionView(set: set.data)
                    }
                }
            } else {
                Text("请选择作业项目")
            }
        } else {
            switch context.content {
            case .copilot(_, let kind, let copilot):
                CopilotConfigView(
                    kind: kind, config: $context.config,
                    userAdditionalEnabled: $context.enableUserAdditional
                ) {
                    CopilotDescriptionView(pilot: copilot)
                }
            case .set(let url, let set):
                Button("激活此作业集") {
                    Task {
                        // C09/C02：激活失败与部分成员跳过不再静默。
                        if let listing = await context.updateSet(at: url, set: set) {
                            context.category = .list
                            if !listing.skipped.isEmpty {
                                newModel.appendLog(
                                    .init(
                                        date: .now,
                                        content: String(
                                            localized:
                                                "作业集已激活，部分成员无法加载：\(listing.skipped.joined(separator: "、"))"
                                        ),
                                        color: .warning))
                            }
                        } else {
                            newModel.appendLog(
                                .init(
                                    date: .now,
                                    content: String(
                                        localized: "作业集无法激活：清单损坏或成员类型不一致。"),
                                    color: .error))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                Divider().padding(.vertical)
                CopilotSetDescriptionView(set: set)
            case .directory, nil:
                Text("请选择作业项目")
            case .invalid:
                Text("文件格式错误")
            case .pending:
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Copilot Config

private struct CopilotConfigView<D: View>: View {
    let kind: MAACopilot.Kind

    @Binding var config: CopilotConfiguration
    @Binding var userAdditionalEnabled: Bool

    let description: D

    init(
        kind: MAACopilot.Kind, config: Binding<CopilotConfiguration>,
        userAdditionalEnabled: Binding<Bool>, @ViewBuilder description: () -> D
    ) {
        self.kind = kind
        self._config = config
        self._userAdditionalEnabled = userAdditionalEnabled
        self.description = description()
    }

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .regular:
                RegularCopilotConfigView(config: $config, userAdditionalEnabled: $userAdditionalEnabled)
                Divider()
            case .sss:
                SSSCopilotConfigView(config: $config)
                Divider()
            case .paradox:
                EmptyView()
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    description
                }
            }
        }
        .padding(.top)
        .animation(.default, value: config.formation)
    }
}

private struct RegularCopilotConfigView: View {
    @Binding var config: CopilotConfiguration
    @Binding var userAdditionalEnabled: Bool

    var body: some View {
        HStack {
            Toggle("自动编队", isOn: $config.formation)
            Toggle("吃理智药", isOn: $config.use_sanity_potion)
        }
        if config.formation {
            HStack {
                Picker("编队栏位", selection: $config.formation_index) {
                    Text("当前").tag(0)
                    ForEach(1...4, id: \.self) { index in
                        Text("\(index)").tag(index)
                    }
                }
                .pickerStyle(.menu)
                Toggle("忽视干员属性要求", isOn: $config.ignore_requirements)
                Toggle("补充低信赖干员", isOn: $config.add_trust)
            }
            HStack {
                Picker("助战模式", selection: $config.support_unit_usage) {
                    ForEach(CopilotConfiguration.SupportUnitUsage.allCases, id: \.self) {
                        Text($0.description).tag($0)
                    }
                }
                if config.support_unit_usage == .specific {
                    TextField("干员名称", text: $config.support_unit_name)
                        .frame(maxWidth: 150)
                }
            }
            .animation(.default, value: config.support_unit_usage)
        }
        // C08 额外自选干员：门控开关（GUI 侧）+ 名单编辑。
        Toggle("额外自选干员", isOn: $userAdditionalEnabled)
        if userAdditionalEnabled {
            UserAdditionalEditor(config: $config)
        }
        SSSCopilotConfigView(config: $config)
    }
}

private struct UserAdditionalEditor: View {
    @Binding var config: CopilotConfiguration

    var body: some View {
        VStack(spacing: 6) {
            ForEach(config.user_additional.indices, id: \.self) { index in
                HStack {
                    TextField(
                        "干员名称",
                        text: Binding(
                            get: { config.user_additional[index].name },
                            set: { config.user_additional[index].name = $0 }
                        )
                    )
                    .frame(maxWidth: 160)
                    Picker(
                        "技能等级",
                        selection: Binding(
                            get: { config.user_additional[index].skill },
                            set: { config.user_additional[index].skill = $0 }
                        )
                    ) {
                        ForEach(1...3, id: \.self) { rank in
                            Text("\(rank)").tag(rank)
                        }
                    }
                    .frame(maxWidth: 84)
                    Button {
                        config.user_additional.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("移除")
                }
            }
            Button("添加干员") {
                config.user_additional.append(.init(name: "", skill: 1))
            }
        }
    }
}

private struct SSSCopilotConfigView: View {
    @Binding var config: CopilotConfiguration

    var body: some View {
        HStack {
            Text("循环次数")
            TextField("1", value: $config.loop_times, format: .number)
        }
        .frame(maxWidth: 130)
    }
}

// MARK: - Copilot Document

private struct CopilotDescriptionView: View {
    let pilot: MAACopilot

    var body: some View {
        if let title = pilot.doc?.title {
            Text(title).font(.title2)
        }
        if let details = pilot.doc?.details {
            Text(details)
        }

        if let equipments = pilot.equipment {
            Text("装备：") + Text(equipments.joined(separator: ", "))
        }

        if let strategy = pilot.strategy {
            Text(strategy)
        }

        if pilot.opers.count > 0 {
            VStack {
                ForEach(pilot.opers, id: \.name) { oper in
                    Text(oper.description)
                }
            }
        }

        if let groups = pilot.groups {
            VStack {
                ForEach(groups, id: \.name) { group in
                    Text(group.name) + Text(verbatim: ": ")
                        + Text(group.opers.map(\.description).joined(separator: " / "))
                }
            }
        }

        if let toolmen = pilot.tool_men {
            Text(toolmen.sorted { $0.key < $1.key }.map { "\($1)\($0)" }.joined(separator: ", "))
        }
    }
}

private struct CopilotSetDescriptionView: View {
    let set: CopilotSetData

    var body: some View {
        Text(set.name).font(.title2)
        Text(set.description)
    }
}

#Preview("Regular Copilot Config") {
    let context = CopilotContext()
    let url = URL.bundledCopilotDirectory
        .appending(path: "OF-1_credit_fight")
        .appendingPathExtension("json")
    context.selection = .init(url: url, isRaid: nil)

    return VStack {
        CopilotView(context: context)
    }
}

#Preview("SSS Copilot Config") {
    let context = CopilotContext()
    let url = URL.bundledCopilotDirectory
        .appending(path: "old/")
        .appending(path: "约翰老妈新建地块_Mama_Johns_New_Plate/")
        .appending(path: "SSS_约翰老妈新建地块")
        .appendingPathExtension("json")
    context.selection = .init(url: url, isRaid: nil)

    return VStack {
        CopilotView(context: context)
    }
}
