//
//  CustomConfiguration.swift
//  MAA
//
//  Created by zhangweijian on 11/9/2026.
//

import Foundation

struct CustomTaskParams: Encodable {
    let task_names: [String]
}

struct CustomConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .Custom }

    var taskList: String

    var title: String {
        type.description
    }

    var subtitle: String {
        let names = parsedTaskNames
        if names.isEmpty {
            return String(localized: "未填写任务名")
        }
        return names.joined(separator: " ")
    }

    var summary: String { "" }

    var projectedTask: MAATask {
        .custom(self)
    }

    /// 解析用户输入的任务名列表，兼容全角/半角逗号与换行分隔（对照 WPF TaskName 的逗号拆分 + Trim + RemoveEmptyEntries）。
    /// 先归一化换行：Swift 中 "\r\n" 是单个 grapheme cluster，split 谓词按 Character 比较匹配不到，需拆成 "\n" 再进入分隔。
    var parsedTaskNames: [String] {
        taskList
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "，", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func validate() throws {
        if parsedTaskNames.isEmpty { throw DailyPipelineError.invalid(String(localized: "请填写至少一个任务名。")) }
    }

    typealias Params = CustomTaskParams

    var params: CustomTaskParams {
        CustomTaskParams(task_names: parsedTaskNames)
    }
}

extension CustomConfiguration {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.taskList = try container.decodeIfPresent(String.self, forKey: .taskList) ?? ""
    }
}

enum DailyPipelineError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// The editor stores source text so an invalid edit survives a restart and can
/// be corrected. Only validated plans reach Core; no new runtime state is added.
struct OperProgressConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .OperProgress }
    var plansJSON: String = "[]"
    var title: String { type.description }
    var subtitle: String { String(localized: "精英化、技能升级与专精") }
    var summary: String { "" }
    var projectedTask: MAATask { .operProgress(self) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plansJSON = try container.decodeIfPresent(String.self, forKey: .plansJSON) ?? "[]"
    }

    func validatedPlans() throws -> [Plan] {
        let plans = try JSONDecoder().decode([Plan].self, from: Data(plansJSON.utf8))
        guard !plans.isEmpty else {
            throw DailyPipelineError.invalid(String(localized: "请填写至少一个干员养成计划。"))
        }
        return plans
    }

    struct Plan: Codable, Hashable, Sendable {
        let name: String
        let role: String?
        let elite: Int?
        let skill_level: Int?
        let skill_mastery: [Int]?

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        enum CodingKeys: String, CodingKey { case name, role, elite, skill_level, skill_mastery }

        init(from decoder: any Decoder) throws {
            let raw = try decoder.container(keyedBy: Key.self)
            let allowed = Set(["name", "role", "elite", "skill_level", "skill_mastery"])
            guard raw.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
                throw DailyPipelineError.invalid(String(localized: "养成计划含有未知字段。"))
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Present null is an error in Core, rather than an omitted action.
            for key in c.allKeys where try c.decodeNil(forKey: key) {
                throw DailyPipelineError.invalid(String(localized: "养成计划字段不能为 null。"))
            }
            name = try c.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            elite = try c.decodeIfPresent(Int.self, forKey: .elite)
            skill_level = try c.decodeIfPresent(Int.self, forKey: .skill_level)
            skill_mastery = try c.decodeIfPresent([Int].self, forKey: .skill_mastery)
            guard !name.isEmpty,
                  elite.map({ (1...2).contains($0) }) ?? true,
                  skill_level.map({ (2...7).contains($0) }) ?? true,
                  skill_mastery.map({ $0.count == 3 && $0.allSatisfy { (0...3).contains($0) } }) ?? true,
                  elite != nil || skill_level != nil || skill_mastery != nil else {
                throw DailyPipelineError.invalid(String(localized: "请检查干员名和养成目标：精英化 1–2，技能 2–7，专精为三个 0–3 的整数。"))
            }
            // Use canonical Core role names; omit role for automatic lookup.
            // §5/P10-[a]（P10-R3）：文案限定多职业干员边界——该类干员省略职业时
            // Core append 拒绝阻塞整队（失败可见可恢复）；单职业干员省略仍自动识别。
            if let role, !["Pioneer", "Warrior", "Tank", "Sniper", "Caster", "Medic", "Support", "Special"].contains(role) {
                throw DailyPipelineError.invalid(String(localized: "职业需使用 Core 标准名称；多职业干员不可省略职业（Core 将拒绝整队下发）。"))
            }
        }
    }

    struct Params: Encodable {
        let source: OperProgressConfiguration
        private enum CodingKeys: String, CodingKey { case plans }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(source.validatedPlans(), forKey: .plans)
        }
    }
    var params: Params { .init(source: self) }
}
