import AppKit
import Foundation

// P29/U12+U13: 环境信息一键复制与支持报告（WPF #90/#107 反馈链 Mac 等价面）。

enum DiagnosticsReport {
    /// U12: 环境/资源/连接版本信息（支持包与一键复制共用；字段收集可注入以便测试）。
    static func environmentInfo(resourceVersion: String, clientChannel: String,
                                appVersion: String, appBuild: String,
                                osVersion: String, architecture: String,
                                coreVersion: String) -> String {
        """
        MAA (MeoAsstMac) \(appVersion) (\(appBuild))
        OS: \(osVersion)
        Arch: \(architecture)
        Core: \(coreVersion)
        Resource: \(resourceVersion)
        Channel: \(clientChannel)
        """
    }

    /// 从进程/Bundle 收集（无注入时的生产缺省面）。
    @MainActor static func currentEnvironmentInfo(resourceVersion: String, clientChannel: String,
                                                  coreVersion: String) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = DiagnosticsReport.machineArchitecture()
        return environmentInfo(resourceVersion: resourceVersion, clientChannel: clientChannel,
                               appVersion: version, appBuild: build, osVersion: os,
                               architecture: arch, coreVersion: coreVersion)
    }

    /// 机器架构（hw.machine 经 sysctl；无注入时生产面）。
    nonisolated static func machineArchitecture() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "-" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// U13: 支持报告打包（环境信息 + gui.log + resource/version.json → zip）。
    /// 脱敏边界：不收集 UserDefaults/Keychain/连接地址——只含上述三类（WPF 反馈包
    /// 脱敏要求同向；差异：Mac 包为最小面）。zip 步骤注入（app 侧用 ZIPFoundation，
    /// 无头套件免 SPM 依赖）。
    static func buildSupportReport(to destination: URL, logFileURL: URL, resourceVersionURL: URL,
                                   environment: String, fileManager: FileManager = .default,
                                   zip: (URL, URL) throws -> Void) throws {
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("MAASupportReport-\(UUID().uuidString)", isDirectory: true)
        let contents = workspace.appendingPathComponent("MAA-Support", isDirectory: true)
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try environment.write(to: contents.appendingPathComponent("environment.txt"),
                              atomically: true, encoding: .utf8)
        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.copyItem(at: logFileURL, to: contents.appendingPathComponent("gui.log"))
        }
        if fileManager.fileExists(atPath: resourceVersionURL.path) {
            try? fileManager.copyItem(at: resourceVersionURL,
                                      to: contents.appendingPathComponent("resource-version.json"))
        }

        let parent = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try zip(contents, destination)
    }

    /// U13: 清理截图/调试产物缓存（Core 截图与临时调试 png）。
    @discardableResult
    static func clearScreenshotCaches(debugDirectory: URL, fileManager: FileManager = .default) -> Int {
        guard fileManager.fileExists(atPath: debugDirectory.path) else { return 0 }
        var removed = 0
        if let enumerator = fileManager.enumerator(at: debugDirectory,
                                                   includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let isImage = ["png", "jpg", "jpeg"].contains(fileURL.pathExtension.lowercased())
                if isImage, (try? fileManager.removeItem(at: fileURL)) != nil {
                    removed += 1
                }
            }
        }
        return removed
    }

    /// U14: 界面语言独立选择（WPF 语言设置同位；AppleLanguages 重启生效）。
    static func applyAppLanguage(_ language: String, defaults: UserDefaults = .standard) {
        if language.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language], forKey: "AppleLanguages")
        }
    }
}
