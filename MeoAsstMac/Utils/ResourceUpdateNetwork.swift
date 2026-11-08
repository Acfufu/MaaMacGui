import Foundation

// P27/U06+U08: 资源更新的网络代理与隔离切换面。
// U08: 代理串解析（WPF Proxy/ProxyType 同位子集——仅 http/https；P27-[b]：
// URLSession connectionProxyDictionary 对 SOCKS 键族实测旁路（kCFStreamPropertySOCKS*
// 与 kCFNetworkProxiesSOCKS* 均直连），Mac 无 SOCKS 支持而 WPF（net6+）原生支持，
// 故不解析 socks5://（配置该前缀走系统默认直连，UI 已如实标注））。
// U06: 隔离 staging + 原子切换 + 失败回退（与 P02.2 门控统一：onUpdate 资源重载
// 抛错即回退旧资源；备份保留到下一次成功切换）。staging 校验按生产布局：source
// 即 resource 目录本身（github: MaaResource-main/resource；mirrorChyan: tmp/resource），
// version.json 在 staging 根——P27-2 修复（原 staging/resource/version.json 期望父目录
// 布局，生产恒抛 missingVersionFile）。

enum ResourceUpdateNetwork {
    /// 代理串 → URLSession 代理字典。支持 `host:port`（按 http 代理）、
    /// `http://host:port`、`https://host:port`；
    /// 空串或缺省 → nil（系统默认会话）；非法（端口缺失/非数字/未知 scheme，含
    /// socks5://——P27-[b] 静默旁路根除）→ nil。
    /// 尾冒号拒绝为 Mac 较 WPF 更严：WPF（net10）经 `Uri.TryCreate` 默认端口接受
    /// `host:`（dotnet/runtime UriTests.cs:707-713 Uri_EmptyPort_UsesDefaultPort），
    /// Mac 拒绝走系统默认——P27-[a] 口径（原「WPF 同款」声称失实）。
    static func proxyConfiguration(from proxy: String) -> [AnyHashable: Any]? {
        let trimmed = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var scheme = "http"
        var remainder = trimmed
        if let range = trimmed.range(of: "://") {
            let separator = range.lowerBound
            scheme = String(trimmed[..<separator]).lowercased()
            remainder = String(trimmed[trimmed.index(after: separator)...])
        }
        guard ["http", "https"].contains(scheme) else { return nil }
        let parts = remainder.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port), !parts[0].isEmpty else {
            return nil
        }
        let host = String(parts[0])
        let isHTTPS = scheme == "https"
        return [
            kCFNetworkProxiesHTTPSEnable as AnyHashable: true,
            kCFNetworkProxiesHTTPSProxy as AnyHashable: host,
            kCFNetworkProxiesHTTPSPort as AnyHashable: port,
            kCFNetworkProxiesHTTPEnable as AnyHashable: true,
            kCFNetworkProxiesHTTPProxy as AnyHashable: host,
            kCFNetworkProxiesHTTPPort as AnyHashable: port,
        ] as [AnyHashable: Any]
    }

    /// 资源更新链使用的会话：无代理 → 系统默认；有代理 → 注入代理字典的独立会话。
    static func session(for proxy: String) -> URLSession {
        guard let configurationDictionary = proxyConfiguration(from: proxy) else { return .shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = configurationDictionary
        return URLSession(configuration: configuration)
    }

    /// U06: 把解压出的新资源全量拷入隔离 staging 目录，并校验其 version.json 可解析。
    /// source = resource 目录本身（生产两渠道布局），version.json 在其根。
    static func stageResource(source: URL, staging: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.copyItem(at: source, to: staging)
        let versionURL = staging.appendingPathComponent("version.json")
        guard fileManager.fileExists(atPath: versionURL.path) else {
            throw ResourceUpdateError.missingVersionFile
        }
        _ = try Data(contentsOf: versionURL)
    }

    /// U06: 原子切换 + 失败回退。staging → target，旧 target → backup；apply
    /// （资源重载/门控校验）抛错时删除新资源并把 backup 恢复回 target 后上抛；
    /// 成功时清除 backup。
    static func atomicApply(staging: URL, target: URL, backup: URL,
                            fileManager: FileManager = .default,
                            apply: () async throws -> Void) async throws {
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        let hadTarget = fileManager.fileExists(atPath: target.path)
        if hadTarget {
            try fileManager.moveItem(at: target, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            if hadTarget {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
        do {
            try await apply()
        } catch {
            // 应用失败（P02.2 门控/加载校验）→ 回退旧资源。
            try? fileManager.removeItem(at: target)
            if hadTarget {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }
}

enum ResourceUpdateError: LocalizedError {
    case missingVersionFile
    var errorDescription: String? {
        switch self {
        case .missingVersionFile:
            return String(localized: "下载的资源缺少 version.json，已放弃应用。")
        }
    }
}
