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
            Text(verbatim: #"[{"name":"阿米娅","role":"Caster","elite":1},{"name":"阿米娅","role":"Caster","skill_level":7},{"name":"棘刺","skill_mastery":[0,0,3]}]"#)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let error = validationError {
                Text(error).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding()
    }

    private var validationError: String? {
        do { _ = try config.validatedPlans(); return nil }
        catch { return error.localizedDescription }
    }
}
