//
//  CopilotListContent.swift
//  MAA
//
//  Created by hguandl on 2026/8/7.
//

import SwiftUI

struct CopilotListContent: View {
    @Bindable var context: CopilotContext

    var body: some View {
        ForEach($context.copilotList) { $item in
            HStack {
                Toggle(item.displayLabel(for: context.copilotSet?.kind), isOn: $item.isOn)
                if context.copilotSet?.kind == .regular {
                    // C10 单行难度编辑：常规作业集的每行可切普通/突袭。
                    Picker(
                        "",
                        selection: Binding(
                            get: { item.isRaid ?? false },
                            set: { $item.wrappedValue.isRaid = $0 }
                        )
                    ) {
                        Text("普通").tag(false)
                        Text("突袭").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 96)
                    // C10 单行导航覆盖：空 = 不覆盖。
                    TextField(
                        "导航覆盖",
                        text: Binding(
                            get: { item.navOverride ?? "" },
                            set: { $item.wrappedValue.navOverride = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .frame(maxWidth: 90)
                    .help("覆盖导航识别名，作业无法导航到关卡时使用。")
                }
            }
            .contextMenu {
                Button("上移") {
                    context.moveRow(of: item.id, by: -1)
                }
                .disabled(!context.canMoveRow(of: item.id, by: -1))
                Button("下移") {
                    context.moveRow(of: item.id, by: 1)
                }
                .disabled(!context.canMoveRow(of: item.id, by: 1))
            }
        }
    }
}

struct CopilotListControls: View {
    @Bindable var context: CopilotContext

    var body: some View {
        HStack(spacing: 12) {
            Button("全选") {
                $context.copilotList.forEach { $i in i.isOn = true }
            }
            .buttonStyle(.borderedProminent)
            Button("取消") {
                $context.copilotList.forEach { $i in i.isOn = false }
            }
            Button("清除") {
                context.copilotList.removeAll()
            }
            .tint(.red)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture {
            context.selection = nil
        }
    }
}

extension CopilotContext.ListItem {
    /// 行标签：突袭行按集合类型标注（常规=突袭，保全=磨难）。
    func displayLabel(for kind: MAACopilot.Kind?) -> String {
        guard isRaid == true else {
            return stageCode
        }
        let suffix = kind == .sss ? String(localized: "（磨难）") : String(localized: "（突袭）")
        return stageCode + suffix
    }
}

#Preview {
    @Previewable @State var selection = URL?.none
    @Previewable @State var context = CopilotContext()
    NavigationSplitView {
        EmptyView()
    } content: {
        List(selection: $selection) {
            CopilotListContent(context: context)
        }
        .safeAreaInset(edge: .bottom) {
            CopilotListControls(context: context)
        }
    } detail: {
        EmptyView()
    }
}
