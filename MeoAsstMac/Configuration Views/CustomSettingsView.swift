//
//  CustomSettingsView.swift
//  MAA
//
//  Created by zhangweijian on 11/9/2026.
//

import SwiftUI

struct CustomSettingsView: View {
    @Binding var config: CustomConfiguration

    var body: some View {
        Form {
            TextField(String(localized: "任务名"), text: $config.taskList, axis: .vertical)
                .lineLimit(3...6)

            if !config.parsedTaskNames.isEmpty {
                Text(formattedTaskNames)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if config.parsedTaskNames.isEmpty {
                Text("请填写至少一个任务名。").foregroundStyle(.red)
            }
            Text(String(localized: "以逗号分隔的任务名列表，将执行第一个匹配的任务及其后续链。示例：TaskA, TaskB → 运行 TaskA（若未匹配则尝试 TaskB）"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var formattedTaskNames: String {
        "[" + config.parsedTaskNames.map { n in
            let escaped = n.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ", ") + "]"
    }
}

struct CustomSettings_Preview: PreviewProvider {
    static var previews: some View {
        CustomSettingsView(config: .constant(.init()))
    }
}

struct OperProgressSettingsView: View {
    @Binding var config: OperProgressConfiguration

    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Text("干员养成计划按数组顺序执行，可能消耗龙门币、材料与训练时间。请确认目标后再启用任务。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("填写 JSON 计划数组；干员名使用中文。支持 name、role、elite、skill_level、skill_mastery，省略不执行的动作。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "role: Pioneer / Warrior / Tank / Sniper / Caster / Medic / Support / Special")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextEditor(text: $config.plansJSON)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .accessibilityLabel("养成计划 JSON")
            // v6.22.0 #19140 同位：清空计划一键化并加二次确认；空计划不弹框。
            HStack {
                Spacer()
                Button("清空计划", role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled((try? config.validatedPlans().isEmpty) ?? true)
            }
            if let error = validationError {
                Text(error).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("确认要清空全部干员培养计划吗？此操作不可恢复。", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("清空计划", role: .destructive) { config.plansJSON = "[]" }
        }
        .padding()
    }

    private var validationError: String? {
        do { _ = try config.validatedPlans(); return nil }
        catch { return error.localizedDescription }
    }
}
