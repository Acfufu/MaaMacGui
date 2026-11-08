//
//  OperBoxAssistExport.swift
//  MAA
//
//  Created by parity P14.1 on 2026/11/7.
//

import Foundation

/// C11 干员资料辅助编队：把历史/会话干员快照落盘为 Core `OperBoxData.load`
/// 消费的 JSON。文件形态与 WPF `DataDir/OperBoxData.json` 同构
/// （done / own_opers / source / syncTime；条目键 name/own/elite/level/
/// mainSkillLevel/skills[{id, level}] 与 Core OperBoxDataConfig 解析一一对应）。
enum OperBoxAssistExport {
    /// 测试注入点：nil = 应用支持目录（WPF DataDir 同位，沙盒下随容器）。
    nonisolated(unsafe) static var overrideDirectory: URL?

    /// 写盘目标（WPF DataDir 同位：应用支持目录根，沙盒下随容器）。
    static func fileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appending(path: "OperBoxData.json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OperBoxData.json")
    }

    /// 可用性判定（P14-1-R3 记录1 措辞如实化）：谓词面=own_opers 非空且至少一名
    /// 干员带技能数据——与 WPF `CheckData`（OperBoxAssistHelper.cs:76-79：source
    /// =="yituliu" **且** own_opers 非空 **且** 任一 skills 非空）的差异在 source 检查：
    /// Mac 不查 source，等价性靠「识别回调快照永不携带 skills」的间接不变量收敛
    /// （见 P14-[b] 台账），非逐字同构。
    static func isAssistUsable(_ payload: OperBoxHistoryPayload) -> Bool {
        guard !payload.ownedOperators.isEmpty else { return false }
        return payload.ownedOperators.contains { oper in
            !(oper.skills ?? []).isEmpty
        }
    }

    /// 落盘并返回路径。快照条目的可选字段（mainSkillLevel/skills/equips）按
    /// Codable 语义在缺省时整体省略；Core 侧 `get(key, default)` 容忍缺键。
    static func write(
        _ payload: OperBoxHistoryPayload, source: String, syncTime: Date?
    ) throws -> URL {
        let url = fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let opersData = try JSONEncoder().encode(payload.ownedOperators)
        guard let opers = try JSONSerialization.jsonObject(with: opersData) as? [[String: Any]] else {
            throw CocoaError(.fileWriteUnknown)
        }

        var object: [String: Any] = [
            "done": payload.done,
            "own_opers": opers,
            "source": source,
        ]
        if let syncTime {
            object["syncTime"] = ISO8601DateFormatter().string(from: syncTime)
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }
}
