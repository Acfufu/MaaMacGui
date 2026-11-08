import Foundation

// P28/U01+U02: fork 主程序更新链的 feed 策略。
// 上游 Info.plist 的 SUFeedURL 已被 fork 移除——Sparkle 无 feed 即无法检查更新；
// 本策略允许用户配置 fork 自有 appcast URL（SPUUpdaterDelegate.feedURLString 注入）。
// 端到端可用还需正式签名 + appcast（EdDSA 签名），验收归 U01 R 级单列。

enum UpdateFeedPolicy {
    static let feedURLDefaultsKey = "MAAUpdateFeedURL"

    /// WPF UpdateVersionType（Nightly/Beta/Stable）→ Mac 渠道面：Sparkle 以
    /// appcast 的 sparkle:channel 标记分流，Mac 现有 stable/beta 两档（useBetaChannel
    /// → allowedChannels）；nightly 无 fork appcast 支撑，不提供（差异入档）。
    static func allowedChannels(useBetaChannel: Bool) -> Set<String> {
        useBetaChannel ? ["beta"] : []
    }

    /// 配置的 feed URL 校验：https 直接可用；http 可用但属明文（UI 层警示）；
    /// 空/非 http(s) → nil（nil 时 Sparkle 回退 Info.plist——fork 已移除，即无 feed）。
    static func feedURLString(configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { return nil }
        return trimmed
    }

    static func isUnsafeHTTP(_ configured: String) -> Bool {
        configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }
}
