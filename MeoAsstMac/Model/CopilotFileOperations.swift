//
//  CopilotFileOperations.swift
//  MAA
//
//  Created by parity P15.1 on 2026/11/7.
//

import Foundation

// MARK: - Copilot File Paths

extension URL {
    static let bundledCopilotDirectory = Bundle.main.resourceURL!
        .appending(path: "resource/")
        .appending(path: "copilot/")

    /// 测试注入点：nil = 文档目录 copilot/（沙盒下随容器）。
    nonisolated(unsafe) static var externalCopilotDirectoryOverride: URL?

    static var externalCopilotDirectory: URL {
        if let externalCopilotDirectoryOverride {
            return externalCopilotDirectoryOverride
        }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appending(path: "copilot/")
    }
}

extension URL {
    /// 外部目录托管的作业（可被移除/覆盖）；内置与任意外部路径返回 false。
    var isManagedCopilot: Bool {
        path.starts(with: URL.externalCopilotDirectory.path)
    }
}

// MARK: - Convenience Methods

extension FileManager {
    func copyCopilotToExternalDirectory(at url: URL) throws -> URL {
        let dest = try externalCopilotURL(for: url)
        try FileManager.default.copyItemOverwriting(at: url, to: dest)
        return dest
    }

    func moveCopilotToExternalDirectory(at url: URL) throws -> URL {
        let dest = try externalCopilotURL(for: url)
        try FileManager.default.moveItemOverwriting(at: url, to: dest)
        return dest
    }

    private func externalCopilotURL(for url: URL) throws -> URL {
        try createDirectory(at: .externalCopilotDirectory, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        return URL.externalCopilotDirectory.appending(path: name)
    }
}
