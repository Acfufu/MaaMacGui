import Foundation

// P28/U01+U02: fork 更新 feed 策略模型层套件。
@main struct UpdateFeedPolicyTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- feed URL 校验（fork 自有更新源；nil 时 Sparkle 回退已移除的 Info.plist）
        check(UpdateFeedPolicy.feedURLString(configured: "") == nil, "empty configured -> nil (no feed)")
        check(UpdateFeedPolicy.feedURLString(configured: "   ") == nil, "blank configured -> nil")
        check(UpdateFeedPolicy.feedURLString(configured: "ftp://x/appcast.xml") == nil, "non-http rejected")
        check(UpdateFeedPolicy.feedURLString(configured: "appcast.xml") == nil, "relative rejected")
        check(UpdateFeedPolicy.feedURLString(configured: "https://fork.example/appcast.xml")
              == "https://fork.example/appcast.xml", "https feed passes through")
        check(UpdateFeedPolicy.feedURLString(configured: "  https://fork.example/appcast.xml  ")
              == "https://fork.example/appcast.xml", "whitespace trimmed")
        check(UpdateFeedPolicy.feedURLString(configured: "http://fork.example/appcast.xml") != nil,
              "http tolerated with UI warning")

        // --- 明文警示面
        check(UpdateFeedPolicy.isUnsafeHTTP("http://a") && !UpdateFeedPolicy.isUnsafeHTTP("https://a"),
              "unsafe-http flag only for http")
        check(!UpdateFeedPolicy.isUnsafeHTTP(""), "empty is not unsafe")

        // --- U02 渠道面（WPF Nightly/Beta/Stable → Mac stable/beta；nightly 差异入档）
        check(UpdateFeedPolicy.allowedChannels(useBetaChannel: false).isEmpty, "stable channel empty set")
        check(UpdateFeedPolicy.allowedChannels(useBetaChannel: true) == ["beta"], "beta channel set")

        // --- 键名稳定（AppStorage 与 UpdaterSettingsView 共享）
        check(UpdateFeedPolicy.feedURLDefaultsKey == "MAAUpdateFeedURL", "defaults key literal")

        print("UpdateFeedPolicyTests: \(count) assertions passed")
    }
}
