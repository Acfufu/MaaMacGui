//
//  MAACopilot.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import Foundation

struct MAACopilot: Codable, Equatable {
    let stage_name: String
    let opers: [Operator]
    let groups: [Group]?
    let minimum_required: String
    let doc: Documentation?
    let difficulty: Int?

    // MARK: SSS

    let type: String?
    let equipment: [String]?
    let strategy: String?
    let tool_men: [String: Int]?

    struct Operator: Codable, Equatable {
        let name: String
        let skill: Int?
    }

    struct Group: Codable, Equatable {
        let name: String
        let opers: [Operator]
    }

    struct Documentation: Codable, Equatable {
        let title: String?
        let title_color: String?
        let details: String?
        let details_color: String?
    }
}

extension MAACopilot.Operator: CustomStringConvertible {
    var description: String {
        if let skill {
            return "\(name) \(skill)"
        } else {
            return name
        }
    }
}

extension MAACopilot {
    init?(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            self = try JSONDecoder().decode(MAACopilot.self, from: data)
        } catch {
            return nil
        }
    }

    static func download(id: Int, toDirectory directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appending(path: "\(id)")
            .appendingPathExtension("json")

        let url = URL(string: "https://prts.maa.plus/copilot/get/\(id)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        struct Content: Codable {
            let data: CopilotData

            struct CopilotData: Codable {
                let content: String
            }
        }

        let content = try JSONDecoder().decode(Content.self, from: data)
        try content.data.content.write(toFile: file.path, atomically: true, encoding: .utf8)

        return file
    }
}

struct CopilotSetData: Codable, Hashable {
    let name: String
    let description: String
    let copilot_ids: [Int]
}

extension CopilotSetData {
    init?(atDirectory url: URL) {
        guard url.isDirectory else { return nil }
        let setID = url.lastPathComponent
        let metaURL = url.appending(path: ".\(setID).json")
        do {
            let data = try Data(contentsOf: metaURL)
            self = try JSONDecoder().decode(CopilotSetData.self, from: data)
        } catch {
            return nil
        }
    }

    static func download(id setID: Int, progress: Progress?) async throws -> URL {
        let url = URL(string: "https://prts.maa.plus/set/get?id=\(setID)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        struct Content: Codable {
            let data: CopilotSetData
        }

        let content = try JSONDecoder().decode(Content.self, from: data)

        let directory = URL.externalCopilotDirectory
            .appending(path: "s\(setID)/")

        progress?.totalUnitCount = Int64(content.data.copilot_ids.count)
        progress?.completedUnitCount = 0

        try await withThrowingTaskGroup { group in
            var ids = content.data.copilot_ids.makeIterator()
            // Limit to 8 concurrent downloads
            for _ in 0..<8 {
                guard let id = ids.next() else { break }
                group.addTask {
                    try await MAACopilot.download(id: id, toDirectory: directory)
                }
            }
            while (try await group.next()) != nil {
                progress?.completedUnitCount += 1
                if let id = ids.next() {
                    let added = group.addTaskUnlessCancelled {
                        try await MAACopilot.download(id: id, toDirectory: directory)
                    }
                    if !added {
                        throw CancellationError()
                    }
                }
            }
        }

        let file = directory.appending(path: ".s\(setID)")
            .appendingPathExtension("json")

        let contentData = try JSONEncoder().encode(content.data)
        try contentData.write(to: file, options: .atomic)

        return directory
    }
}

extension URL {
    /// 作业文件名主干（去扩展名）——展示名与纯数字作业站 id 判定的单点提取。
    /// ⑦（健壮性 backlog，快照 82 清单③）：收敛三处拷贝——
    /// CopilotConfiguration.currentRateableCopilotID（C12 评价入口 id 解析）/
    /// VideoRecognitionImport.importOutput（C13 导入产物展示名）/
    /// CopilotContent.Item.name（作业树条目名）。MAACopilot.swift 落位使三个
    /// copilot 套件（compile/persistence/video-recognition）的 verbatim 提取面
    /// 均含本助手，无需 strip 同步。
    /// 数字谓词第二份拷贝（CopilotConfiguration 私有 `digits`，prtsCode 用）
    /// 未随本助手移动——移动会打破 compile/persistence 两套件的单文件编译
    /// 布局（需 stub 同步且 stub 复制实现无测试价值），S6-1-R3 低-1 注记。
    var copilotFileStem: String {
        deletingPathExtension().lastPathComponent
    }
}
