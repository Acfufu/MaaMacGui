import Foundation

// P27/U06+U08: 资源更新代理解析与隔离切换/回退模型层套件（真实临时目录操作）。
@main struct ResourceUpdateNetworkTests {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- U08: 代理串解析矩阵
        check(ResourceUpdateNetwork.proxyConfiguration(from: "") == nil, "empty proxy -> system default")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "   ") == nil, "blank proxy -> system default")
        let bare = ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1:7890")
        check(bare != nil, "bare host:port parses as http proxy")
        let explicit = ResourceUpdateNetwork.proxyConfiguration(from: "http://127.0.0.1:7890")
        check(explicit != nil, "http scheme parses")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "https://proxy.local:8443") != nil, "https scheme parses")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "socks5://127.0.0.1:1080") != nil, "socks5 parses")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1") == nil, "missing port rejected")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1:") == nil, "trailing colon rejected (WPF 同款)")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1:abc") == nil, "non-numeric port rejected")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1:99999") == nil, "out-of-range port rejected")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "ftp://127.0.0.1:1080") == nil, "unknown scheme rejected")
        let socksDict = ResourceUpdateNetwork.proxyConfiguration(from: "socks5://127.0.0.1:1080")!
        check(socksDict[kCFNetworkProxiesSOCKSEnable] as? Bool == true, "socks dictionary flags SOCKS")

        // --- 会话构造：无代理=shared；有代理=独立配置
        check(ResourceUpdateNetwork.session(for: "") === URLSession.shared, "no proxy returns shared session")
        let proxied = ResourceUpdateNetwork.session(for: "127.0.0.1:7890")
        check(proxied !== URLSession.shared, "proxy builds dedicated session")
        check(proxied.configuration.connectionProxyDictionary != nil, "proxy dictionary injected")

        // --- U06: staging 全量拷贝 + version 校验
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MAAResourceUpdateTests-\(UUID())", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("extracted", isDirectory: true)
        let staging = root.appendingPathComponent("resource.staging", isDirectory: true)
        let target = root.appendingPathComponent("resource", isDirectory: true)
        let backup = root.appendingPathComponent("resource.backup", isDirectory: true)

        // 源缺 version.json → 拒绝
        try fm.createDirectory(at: source.appendingPathComponent("resource/base", isDirectory: true), withIntermediateDirectories: true)
        try "data".write(to: source.appendingPathComponent("resource/base/task.json"), atomically: true, encoding: .utf8)
        do {
            _ = try ResourceUpdateNetwork.stageResource(source: source, staging: staging)
            check(false, "missing version.json rejected")
        } catch ResourceUpdateError.missingVersionFile {
            check(true, "missing version.json rejected")
        } catch {
            check(false, "missing version.json surfaced as missingVersionFile")
        }
        try "{\"last_updated\":\"2026-11-07\"}".write(
            to: source.appendingPathComponent("resource/version.json"), atomically: true, encoding: .utf8)
        try ResourceUpdateNetwork.stageResource(source: source, staging: staging)
        check(fm.fileExists(atPath: staging.appendingPathComponent("resource/version.json").path),
              "staging contains full copy")

        // --- U06: 原子切换 + 回退
        // 旧 target 内容
        try fm.createDirectory(at: target.appendingPathComponent("resource", isDirectory: true), withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("resource/version.json"), atomically: true, encoding: .utf8)

        // 成功路径：apply 通过 → target 为新内容、backup 清理
        try await ResourceUpdateNetwork.atomicApply(staging: staging, target: target, backup: backup) {}
        check(String(decoding: (try? Data(contentsOf: target.appendingPathComponent("resource/version.json"))) ?? Data(), as: UTF8.self)
              == "{\"last_updated\":\"2026-11-07\"}", "successful apply promotes staging")
        check(!fm.fileExists(atPath: backup.path), "backup removed after success")

        // 失败路径：apply 抛错 → 回退旧内容（先重置 target 为「旧」基线）
        try "old".write(to: target.appendingPathComponent("resource/version.json"), atomically: true, encoding: .utf8)
        try ResourceUpdateNetwork.stageResource(source: source, staging: staging)
        struct ApplyFailure: Error {}
        do {
            try await ResourceUpdateNetwork.atomicApply(staging: staging, target: target, backup: backup) {
                throw ApplyFailure()
            }
            check(false, "apply failure propagates")
        } catch is ApplyFailure {
            check(true, "apply failure propagates")
        }
        check(String(decoding: (try? Data(contentsOf: target.appendingPathComponent("resource/version.json"))) ?? Data(), as: UTF8.self)
              == "old", "failed apply rolls back to previous target")
        check(!fm.fileExists(atPath: staging.path), "staging consumed even on rollback")

        // 无旧 target 时失败：target 清理，不留半套
        try fm.removeItem(at: target)
        try ResourceUpdateNetwork.stageResource(source: source, staging: staging)
        do {
            try await ResourceUpdateNetwork.atomicApply(staging: staging, target: target, backup: backup) {
                throw ApplyFailure()
            }
        } catch {}
        check(!fm.fileExists(atPath: target.path), "failed first apply leaves no half-set resource")

        print("ResourceUpdateNetworkTests: \(count) assertions passed")
    }
}
