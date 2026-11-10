//
//  VideoRecognitionImport.swift
//  MAA
//
//  Created by parity P15.1 on 2026/11/7.
//

import Foundation

/// C13 视频识别转作业：Core `CombatRecordRecognitionTask` 的产物导入与
/// 取消/失败残留清理。
///
/// Core 成功时把产物写到 `UserDir/cache/CombatRecord/MaaAI_*.json` 并经
/// `Finished` 回调上报路径；取消/失败路径 Core 不清理，残留由 GUI 侧在
/// `TaskChainError`/`TaskChainStopped` 时统一丢弃。
enum VideoRecognitionImport {
    /// 识别产物缓存目录（Core UserDir 同源）。
    static func cacheDirectory(userDirectory: URL) -> URL {
        userDirectory
            .appending(path: "cache/")
            .appending(path: "CombatRecord/")
    }

    /// 取消/失败后的残留清理：成功产物此刻已被移入外部目录，缓存目录里
    /// 剩余的 json 一律是残段。逐文件 best-effort，不抛错。
    static func discardLeftoverCacheFiles(userDirectory: URL) {
        let directory = cacheDirectory(userDirectory: userDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    enum Outcome: Equatable {
        /// 产物已通过作业解析并移入外部目录。
        case imported(URL, name: String)
        /// 产物不是可解析的作业文件（已删除，不误导为可执行）。
        case discardedInvalid
        /// 移动/写盘失败。
        case failed(String)
    }

    /// 导入一次识别产物：先按作业格式回读校验（GUI 生成文件回读），再挪入
    /// 外部目录；校验失败的产物直接删除。
    static func importOutput(filename: String) -> Outcome {
        let url = URL(filePath: filename)
        guard MAACopilot(url: url) != nil else {
            try? FileManager.default.removeItem(at: url)
            return .discardedInvalid
        }
        do {
            let destination = try FileManager.default.moveCopilotToExternalDirectory(at: url)
            return .imported(destination, name: destination.deletingPathExtension().lastPathComponent)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
