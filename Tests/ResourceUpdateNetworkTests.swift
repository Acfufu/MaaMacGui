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
        // P27-[b]（P27.2）：socks5:// 不再解析——URLSession connectionProxyDictionary
        // 对 SOCKS 键族实测旁路（评审本地桩实锤），静默直连；UI 已如实标注仅 http/https。
        check(ResourceUpdateNetwork.proxyConfiguration(from: "socks5://127.0.0.1:1080") == nil,
              "socks5 rejected (URLSession ignores SOCKS dictionaries — P27-[b])")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1") == nil, "missing port rejected")
        // P27-[a]（P27.2）：尾冒号拒绝为 Mac 较 WPF 更严——WPF（net10）经 Uri 默认端口
        // 接受 `host:`（dotnet/runtime UriTests.cs:707-713），原「WPF 同款」声称失实。
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1:") == nil,
              "trailing colon rejected (Mac stricter than WPF — dotnet Uri uses default port)")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1:abc") == nil, "non-numeric port rejected")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "127.0.0.1:99999") == nil, "out-of-range port rejected")
        check(ResourceUpdateNetwork.proxyConfiguration(from: "ftp://127.0.0.1:1080") == nil, "unknown scheme rejected")

        // --- 会话构造：无代理=shared；有代理=独立配置
        check(ResourceUpdateNetwork.session(for: "") === URLSession.shared, "no proxy returns shared session")
        let proxied = ResourceUpdateNetwork.session(for: "127.0.0.1:7890")
        check(proxied !== URLSession.shared, "proxy builds dedicated session")
        check(proxied.configuration.connectionProxyDictionary != nil, "proxy dictionary injected")

        // --- U06: staging 全量拷贝 + version 校验（P27.2：生产布局——source 即
        // resource 目录本身，version.json 在其根；评审探针实证原 staging/resource/
        // version.json 期望父目录布局在生产恒抛 missingVersionFile）。
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MAAResourceUpdateTests-\(UUID())", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 生产布局镜像：github 渠道 extract 根 = tmp/MaaResource-main，source = 其下
        // resource/；此处 source 直接取 resource 目录本身。
        let extractRoot = root.appendingPathComponent("MaaResource-main", isDirectory: true)
        let source = extractRoot.appendingPathComponent("resource", isDirectory: true)
        let staging = root.appendingPathComponent("resource.staging", isDirectory: true)
        let target = root.appendingPathComponent("resource", isDirectory: true)
        let backup = root.appendingPathComponent("resource.backup", isDirectory: true)

        // 源缺 version.json → 拒绝
        try fm.createDirectory(at: source.appendingPathComponent("base", isDirectory: true), withIntermediateDirectories: true)
        try "data".write(to: source.appendingPathComponent("base/task.json"), atomically: true, encoding: .utf8)
        do {
            _ = try ResourceUpdateNetwork.stageResource(source: source, staging: staging)
            check(false, "missing version.json rejected")
        } catch ResourceUpdateError.missingVersionFile {
            check(true, "missing version.json rejected")
        } catch {
            check(false, "missing version.json surfaced as missingVersionFile")
        }
        try "{\"last_updated\":\"2026-11-07\"}".write(
            to: source.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)
        try ResourceUpdateNetwork.stageResource(source: source, staging: staging)
        check(fm.fileExists(atPath: staging.appendingPathComponent("version.json").path),
              "staging contains full copy (version.json at staging root — production layout)")

        // --- U06: 解压产物→staging→apply 端到端最小链 + 原子切换 + 回退
        // 旧 target 内容
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)

        // 成功路径（端到端链：staging→apply 读新资源→promote）：apply 通过 →
        // target 为新内容、backup 清理
        try await ResourceUpdateNetwork.atomicApply(staging: staging, target: target, backup: backup) {
            // onUpdate 等价面：新资源在 target 可读（P02.2 门控消费的就是它）。
            _ = try Data(contentsOf: target.appendingPathComponent("version.json"))
        }
        check(String(decoding: (try? Data(contentsOf: target.appendingPathComponent("version.json"))) ?? Data(), as: UTF8.self)
              == "{\"last_updated\":\"2026-11-07\"}", "successful apply promotes staging")
        check(!fm.fileExists(atPath: backup.path), "backup removed after success")

        // 失败路径：apply 抛错 → 回退旧内容（先重置 target 为「旧」基线）
        try "old".write(to: target.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)
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
        check(String(decoding: (try? Data(contentsOf: target.appendingPathComponent("version.json"))) ?? Data(), as: UTF8.self)
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
