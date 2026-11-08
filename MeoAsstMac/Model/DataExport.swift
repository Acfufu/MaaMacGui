//
//  DataExport.swift
//  MAA
//
//  Created on 2026/11/6.
//

import Foundation

/// 仓库/干员导出行构建（P16 T07/T09，WPF ToolboxViewModel 导出方法同构）。
/// 行构建为纯函数：表头由调用方传入（本地化属视图层），换行/引号按 RFC 4180 转义。
/// 干员扩展列/JSON 现态（勘正 I04-[b] 陈旧注释「本层始终输出基础 7 列」——P16-2-R3
/// 记录-4、S7-1-R3 低-1；P16-[h] 裁定 2026-11-09 恢复扩展面，快照已承载技能/模组数据）：
/// Markdown/CSV=基础 7 列，includeYituliuFields=true 时追加主技能等级/技能专精/模组
/// 三扩展列；JSON 行=WPF OperData（OperBoxData.cs d75bf9a）10 属性同构——7 基键+
/// mainSkillLevel/skills/equips 三扩展键，缺数据键省略=WPF NullValueHandling.Ignore
/// 同构（详见 OperBoxJSONRow）。
enum DataExport {
    // MARK: - Depot（WPF BuildMarkdownExportLines / BuildCsvExportLines 逐字同构）

    static func depotMarkdownLines(rows: [(id: String, name: String, count: Int)]) -> [String] {
        var lines = ["# Arknights Depot Export", "", "| ID | Name | Count |", "| --- | --- | --- |"]
        for row in rows {
            lines.append("| \(row.id) | \(row.name) | \(row.count) |")
        }
        return lines
    }

    static func depotCsvLines(rows: [(id: String, name: String, count: Int)]) -> [String] {
        var lines = ["ID,Name,Count"]
        for row in rows {
            lines.append("\(row.id),\(Self.csvField(row.name)),\(row.count)")
        }
        return lines
    }

    // MARK: - OperBox（WPF BuildOperBoxMarkdownExportLines / Csv 同构；一图流列按 includeYituliuFields）

    struct OperBoxRow: Equatable {
        let name: String
        let id: String
        let rarity: Int
        let elite: Int
        let level: Int
        let own: Bool
        let potential: Int
        var mainSkillLevel: Int? = nil
        var skills: [OperBoxHistoryPayload.Skill]? = nil
        var equips: [OperBoxHistoryPayload.Equip]? = nil
    }

    /// 表头文本由视图按当前语言传入；列序与分隔符固定（WPF 同构）。
    struct OperBoxHeaders: Equatable {
        let name: String
        let id: String
        let rarity: String
        let elite: String
        let level: String
        let own: String
        let potential: String
        let yes: String
        let no: String
        var mainSkill: String = ""
        var skills: String = ""
        var equips: String = ""
    }

    /// WPF FormatMainSkillColumn：1~7，无数据为空。
    static func mainSkillText(_ level: Int?) -> String {
        level.map(String.init) ?? ""
    }

    /// WPF FormatSkillsColumn：按技能顺序拼接专精等级（如 3/3/0），无专精技能为空。
    static func skillsText(_ skills: [OperBoxHistoryPayload.Skill]?) -> String {
        guard let skills, !skills.isEmpty else { return "" }
        return skills.map { String($0.level) }.joined(separator: "/")
    }

    /// WPF FormatEquipsColumn：分支加等级（如 X3 Y1），过滤等级为 0 的占位条目。
    static func equipsText(_ equips: [OperBoxHistoryPayload.Equip]?) -> String {
        guard let equips, !equips.isEmpty else { return "" }
        return equips.filter { $0.level > 0 }.map { "\($0.type)\($0.level)" }.joined(separator: " ")
    }

    /// 中2（P16-1-R3）：WPF BuildOperBoxExportList 全表导出同构——未拥有行以
    /// Own=false、Elite/Level/Potential=0 补齐（快照 allOperators 全表在位，
    /// 非 owned-only 的未申报范围选择）；行序 = 快照负载序（Core battle_data
    /// 遍历序 ≈ WPF DataHelper.Operators 资源序，低-5 同步对齐；Mac 展示排序
    /// 不适用于导出）。行内容中 owned 细节以 ownedOperators 按 id 取得。
    static func operBoxExportRows(
        allOperators: [OperBoxHistoryPayload.Operator],
        ownedOperators: [OperBoxHistoryPayload.OwnedOperator]
    ) -> [OperBoxRow] {
        let detailsByID = Dictionary(ownedOperators.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        return allOperators.map { oper in
            guard let detail = detailsByID[oper.id] else {
                return OperBoxRow(
                    name: oper.name, id: oper.id, rarity: oper.rarity, elite: 0,
                    level: 0, own: false, potential: 0,
                    mainSkillLevel: nil, skills: nil, equips: nil)
            }
            return OperBoxRow(
                name: detail.name, id: detail.id, rarity: detail.rarity, elite: detail.elite,
                level: detail.level, own: true, potential: detail.potential,
                mainSkillLevel: detail.mainSkillLevel, skills: detail.skills, equips: detail.equips)
        }
    }

    /// JSON 行对象对齐 WPF OperData（OperBoxData.cs d75bf9a :21-88）：7 基键
    /// （id/own/name/rarity/elite/level/potential）+ yituliu 扩展键
    /// mainSkillLevel/skills/equips（P16-[h] 对齐，2026-11-09 裁定：恢复扩展键，
    /// 修正 [d]「WPF 7 键」失实前提——WPF 实为 10 属性全量序列化、null 省略）。
    /// Optional 合成 Codable 走 encodeIfPresent = WPF NullValueHandling.Ignore
    /// 同构：缺数据（本地识别无扩展值）时键不出现在 JSON，与原 7 键面逐字节一致；
    /// Skill/Equip 嵌套形状与 WPF SkillData/EquipData 逐字段同构。
    struct OperBoxJSONRow: Codable {
        let id: String
        let own: Bool
        let name: String
        let rarity: Int
        let elite: Int
        let level: Int
        let potential: Int
        let mainSkillLevel: Int?
        let skills: [OperBoxHistoryPayload.Skill]?
        let equips: [OperBoxHistoryPayload.Equip]?

        init(id: String, own: Bool, name: String, rarity: Int, elite: Int, level: Int,
             potential: Int, mainSkillLevel: Int? = nil,
             skills: [OperBoxHistoryPayload.Skill]? = nil,
             equips: [OperBoxHistoryPayload.Equip]? = nil) {
            self.id = id
            self.own = own
            self.name = name
            self.rarity = rarity
            self.elite = elite
            self.level = level
            self.potential = potential
            self.mainSkillLevel = mainSkillLevel
            self.skills = skills
            self.equips = equips
        }
    }

    /// 中1（P16-1-R3）：WPF ExportOperBoxToJson 同构补齐——Formatting.Indented
    /// 对应 `.prettyPrinted`；键序以 `.sortedKeys` 钉死（JSONEncoder 缺省哈希序
    /// 逐次运行漂移不可复现；sortedKeys 字母序 vs WPF Newtonsoft 声明序残余
    /// 差异入台账 P16-[a]）。
    static func operBoxJSONData(rows: [OperBoxJSONRow]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    static func operBoxMarkdownLines(
        rows: [OperBoxRow], headers: OperBoxHeaders, includeYituliuFields: Bool = false
    ) -> [String] {
        var header = "| \(headers.name) | \(headers.id) | \(headers.rarity) | \(headers.elite) | \(headers.level) | \(headers.own) | \(headers.potential) |"
        var separator = "| :-- | :-- | :-- | :-- | :-- | :-- | :-- |"
        if includeYituliuFields {
            header += " \(headers.mainSkill) | \(headers.skills) | \(headers.equips) |"
            separator += " :-- | :-- | :-- |"
        }
        var lines = [header, separator]
        for row in rows {
            var line = "| \(row.name) | \(row.id) | \(row.rarity) | \(row.elite) | \(row.level) | \(row.own ? headers.yes : headers.no) | \(row.potential) |"
            if includeYituliuFields {
                line += " \(mainSkillText(row.mainSkillLevel)) | \(skillsText(row.skills)) | \(equipsText(row.equips)) |"
            }
            lines.append(line)
        }
        return lines
    }

    static func operBoxCsvLines(
        rows: [OperBoxRow], headers: OperBoxHeaders, includeYituliuFields: Bool = false
    ) -> [String] {
        var header = "\(Self.csvField(headers.name)),\(Self.csvField(headers.id)),\(Self.csvField(headers.rarity)),\(Self.csvField(headers.elite)),\(Self.csvField(headers.level)),\(Self.csvField(headers.own)),\(Self.csvField(headers.potential))"
        if includeYituliuFields {
            header += ",\(Self.csvField(headers.mainSkill)),\(Self.csvField(headers.skills)),\(Self.csvField(headers.equips))"
        }
        var lines = [header]
        for row in rows {
            var line = "\(Self.csvField(row.name)),\(row.id),\(row.rarity),\(row.elite),\(row.level),\(row.own ? headers.yes : headers.no),\(row.potential)"
            if includeYituliuFields {
                line += ",\(mainSkillText(row.mainSkillLevel)),\(skillsText(row.skills)),\(equipsText(row.equips))"
            }
            lines.append(line)
        }
        return lines
    }

    // MARK: - 共享

    /// 行拼接（LF join；WPF 为 Environment.NewLine=CRLF——平台惯例差异入台账
    /// P16-[b]，行内容级同构）。字面空数组返回 nil；注意运行期空集防线在
    /// OperBoxHistoryStore.save 的 isValid 门+按钮禁用（低-6/P16-1-R3：构建层
    /// 恒产表头，四个构建器对空行集产出仅表头文件——此处兜底语义有限）。
    static func joinedLines(_ lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// RFC 4180：含逗号/引号/换行时整字段加引号，内部引号翻倍（WPF 同构）。
    static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// WPF 干员导出走 UTF-8 BOM（Excel 兼容），仓库导出为无 BOM UTF-8；此处保持两口径。
    static func write(_ content: String, to url: URL, withBOM: Bool) throws {
        var data = Data(content.utf8)
        if withBOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        try data.write(to: url, options: .atomic)
    }
}
