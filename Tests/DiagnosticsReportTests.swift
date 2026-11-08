import Foundation

// P29/U12+U13+U14: 诊断报告模型层套件（真实临时目录操作）。
// 打包步骤以 copy 桩注入（无头套件免 SPM 依赖；真实 zip 在 app 层由 ZIPFoundation 承担）。
// workspace 在 buildSupportReport 返回时被 defer 清理——检查打包桩的副本。
@main struct DiagnosticsReportTests {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- U12: 环境信息形态
        let info = DiagnosticsReport.environmentInfo(
            resourceVersion: "2026-11-07", clientChannel: "Official",
            appVersion: "5.12.0", appBuild: "421", osVersion: "macOS 27.2",
            architecture: "arm64", coreVersion: "v6.x-51dac87")
        for needle in ["MAA (MeoAsstMac) 5.12.0 (421)", "OS: macOS 27.2", "Arch: arm64",
                       "Core: v6.x-51dac87", "Resource: 2026-11-07", "Channel: Official"] {
            check(info.contains(needle), "env info carries: \(needle)")
        }

        // --- U13: 支持报告打包
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MAADiagTests-\(UUID())", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let logFile = root.appendingPathComponent("gui.log")
        try "line1\nline2".write(to: logFile, atomically: true, encoding: .utf8)
        let versionFile = root.appendingPathComponent("version.json")
        try "{\"last_updated\":\"2026-11-07\"}".write(to: versionFile, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("Diag/support-report.zip")
        // 打包桩：先删后拷（copyItem 对已存在目录是「拷入」语义，二次生成会撞名）。
        let pack: (URL, URL) throws -> Void = { source, target in
            let bundlePath = target.appendingPathExtension("bundle")
            if fm.fileExists(atPath: bundlePath.path) {
                try fm.removeItem(at: bundlePath)
            }
            try fm.copyItem(at: source, to: bundlePath)
        }
        try DiagnosticsReport.buildSupportReport(to: destination, logFileURL: logFile,
                                                 resourceVersionURL: versionFile,
                                                 environment: info, zip: pack)
        let bundle = destination.appendingPathExtension("bundle")
        check(fm.fileExists(atPath: bundle.path), "report bundle written")
        check(fm.fileExists(atPath: bundle.appendingPathComponent("environment.txt").path),
              "environment gathered")
        check(fm.fileExists(atPath: bundle.appendingPathComponent("gui.log").path),
              "log gathered")
        check(fm.fileExists(atPath: bundle.appendingPathComponent("resource-version.json").path),
              "resource version gathered")
        // 重复生成覆盖旧包
        try DiagnosticsReport.buildSupportReport(to: destination, logFileURL: logFile,
                                                 resourceVersionURL: versionFile, environment: "again", zip: pack)
        check(fm.fileExists(atPath: destination.path.appending(".bundle")), "regeneration overwrites")

        // --- U13: 截图缓存清理（png/jpg 删除、日志保留）
        let debugDir = root.appendingPathComponent("debug", isDirectory: true)
        try fm.createDirectory(at: debugDir.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        for name in ["a.png", "b.jpg", "c.txt", "sub/d.jpeg", "e.png"] {
            try Data().write(to: debugDir.appendingPathComponent(name))
        }
        try "log".write(to: debugDir.appendingPathComponent("gui.log"), atomically: true, encoding: .utf8)
        let removed = DiagnosticsReport.clearScreenshotCaches(debugDirectory: debugDir)
        check(removed == 4, "four image files removed")
        check(fm.fileExists(atPath: debugDir.appendingPathComponent("gui.log").path), "log preserved")
        check(fm.fileExists(atPath: debugDir.appendingPathComponent("c.txt").path), "non-image preserved")

        // --- U14: 语言应用（system=清除覆盖；套件域规避全局域 CLI 怪癖）
        let langSuite = "MAADiagLangTests-\(UUID())"
        let langDefaults = UserDefaults(suiteName: langSuite)!
        DiagnosticsReport.applyAppLanguage("en", defaults: langDefaults)
        check(langDefaults.stringArray(forKey: "AppleLanguages") == ["en"], "language override written")
        DiagnosticsReport.applyAppLanguage("", defaults: langDefaults)
        // 套件域搜索会穿透全局域的系统 AppleLanguages——断言持久域本身已清。
        let domain = langDefaults.persistentDomain(forName: langSuite)
        let persisted = domain?["AppleLanguages"]
        check(persisted == nil, "system language clears override")

        print("DiagnosticsReportTests: \(count) assertions passed")
    }
}
