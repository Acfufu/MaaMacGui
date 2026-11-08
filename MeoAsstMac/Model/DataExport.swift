//
//  DataExport.swift
//  MAA
//
//  Created on 2026/11/6.
//

import Foundation

/// 仓库/干员导出行构建（P16 T07/T09，WPF ToolboxViewModel 导出方法同构）。
/// 行构建为纯函数：表头由调用方传入（本地化属视图层），换行/引号按 RFC 4180 转义。
/// 一图流技能/模组列需要快照不承载的数据（I04-[b]），本层始终输出基础 7 列（T09 远端字段部分开放）。
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

    // MARK: - OperBox（WPF BuildOperBoxMarkdownExportLines / Csv，基础列版）

    struct OperBoxRow: Equatable {
        let name: String
        let id: String
        let rarity: Int
        let elite: Int
        let level: Int
        let own: Bool
        let potential: Int
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
    }

    static func operBoxMarkdownLines(
        rows: [OperBoxRow], headers: OperBoxHeaders
    ) -> [String] {
        var lines = [
            "| \(headers.name) | \(headers.id) | \(headers.rarity) | \(headers.elite) | \(headers.level) | \(headers.own) | \(headers.potential) |",
            "| :-- | :-- | :-- | :-- | :-- | :-- | :-- |",
        ]
        for row in rows {
            lines.append(
                "| \(row.name) | \(row.id) | \(row.rarity) | \(row.elite) | \(row.level) | \(row.own ? headers.yes : headers.no) | \(row.potential) |")
        }
        return lines
    }

    static func operBoxCsvLines(rows: [OperBoxRow], headers: OperBoxHeaders) -> [String] {
        var lines = [
            "\(Self.csvField(headers.name)),\(Self.csvField(headers.id)),\(Self.csvField(headers.rarity)),\(Self.csvField(headers.elite)),\(Self.csvField(headers.level)),\(Self.csvField(headers.own)),\(Self.csvField(headers.potential))",
        ]
        for row in rows {
            lines.append(
                "\(Self.csvField(row.name)),\(row.id),\(row.rarity),\(row.elite),\(row.level),\(row.own ? headers.yes : headers.no),\(row.potential)")
        }
        return lines
    }

    // MARK: - 共享

    /// WPF 导出空集直接返回，不产生空文件。
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
