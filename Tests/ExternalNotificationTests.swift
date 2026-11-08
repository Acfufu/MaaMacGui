import Foundation
import CryptoKit

// P24/E02+E06: 九渠道模型层套件（纯函数面+配置持久化+空凭据门控；真实服务 NOT_RUN(凭据)）。
@main struct ExternalNotificationTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- 配置 Codable 往返（九渠道枚举面）
        let kinds: [ExternalNotificationChannelKind] = ExternalNotificationChannelKind.allCases
        check(kinds.count == 9, "nine channels")
        for kind in kinds {
            let config = ExternalNotificationConfig(kind: kind)
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(ExternalNotificationConfig.self, from: data)
            check(decoded == config, "\(kind.rawValue) config roundtrip")
        }
        // 旧档案缺字段解码缺省（enabled 缺省 true 由字段缺省承载）
        // 合成 Codable 不落结构体缺省：id 由写入方恒编码，此处带 id 验证其余面缺省。
        let fixedID = "11111111-2222-3333-4444-555555555555"
        let minimal = try JSONDecoder().decode(ExternalNotificationConfig.self, from: Data(
            "{\"id\":\"\(fixedID)\",\"kind\":\"bark\"}".utf8))
        check(minimal.kind == .bark && minimal.enabled, "minimal config decodes with defaults")

        // --- 配置存储持久化
        let suite = "MAAExternalNotificationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExternalNotificationSettingsStore(defaults: defaults)
        check(store.configs.isEmpty, "fresh store empty")
        store.configs.append(ExternalNotificationConfig(kind: .telegram))
        let reloaded = ExternalNotificationSettingsStore(defaults: defaults)
        check(reloaded.configs.count == 1 && reloaded.configs[0].kind == .telegram, "configs persist across stores")

        // --- ServerChan 构造：title 去换行截 32（WPF 同构）+ key 不进日志面
        let sc = ExternalNotificationBuilders.serverChanRequest(
            sendKey: "SCT123", title: "a\nb" + String(repeating: "c", count: 40), content: "正文&内容")
        check(sc != nil, "serverChan builds with key")
        check(sc!.truncatedHost == "sctapi.ftqq.com", "log host only")
        check(!sc!.url.absoluteString.contains("正文"), "content not in URL")
        check(sc!.body.hasPrefix("text="), "form body shape")
        check(sc!.body.contains("desp=%E6%AD%A3%E6%96%87%26%E5%86%85%E5%AE%B9"), "content percent-encoded")
        check(ExternalNotificationBuilders.serverChanRequest(sendKey: "", title: "t", content: "c") == nil,
              "empty key rejected")

        // --- DingTalk 加签：确定性与 URL 形态
        let sign1 = ExternalNotificationBuilders.dingTalkSign(secret: "s", timestamp: 1710000000000)
        let sign2 = ExternalNotificationBuilders.dingTalkSign(secret: "s", timestamp: 1710000000000)
        check(sign1 == sign2 && !sign1.isEmpty, "sign deterministic")
        let dingURL = ExternalNotificationBuilders.dingTalkURL(accessToken: "tok", secret: "", timestamp: 1)
        check(dingURL?.absoluteString == "https://oapi.dingtalk.com/robot/send?access_token=tok", "unsigned URL shape")
        let dingSigned = ExternalNotificationBuilders.dingTalkURL(accessToken: "tok", secret: "s", timestamp: 1)
        check(dingSigned!.absoluteString.contains("timestamp=1&sign="), "signed URL carries timestamp+sign")

        // --- Webhook 模板与头
        let body = ExternalNotificationBuilders.webhookBody(template: "{\"t\":\"{title}\",\"c\":\"{content}\"}",
                                                            title: "he\"llo", content: "a\nb")
        check(body.contains("\\\"llo"), "title JSON-escaped")
        check(body.contains("a\\nb"), "content newline escaped")
        check(ExternalNotificationBuilders.webhookHeaders("{\"X-A\":\"1\"}") == ["X-A": "1"], "headers parsed")
        check(ExternalNotificationBuilders.webhookHeaders("not json").isEmpty, "invalid headers empty")

        // --- SMTP 对话：顺序与 AUTH PLAIN
        let withAuth = ExternalNotificationBuilders.smtpCommands(host: "mx", from: "a@b.c", to: "d@e.f",
                                                                 subject: "[MAA] t", content: "正文",
                                                                 requireAuth: true, credentials: ("u", "p"))
        check(withAuth.count == 7, "full dialog steps")
        check(withAuth[0].expectPrefix == "220", "greeting first")
        check(withAuth[1].send == "EHLO mx", "ehlo")
        let expectedPlain = Data("\u{0}u\u{0}p".utf8).base64EncodedString()
        check(withAuth[2].send == "AUTH PLAIN \(expectedPlain)", "auth plain base64")
        check(withAuth[3].send == "MAIL FROM:<a@b.c>", "mail from")
        check(withAuth[4].send == "RCPT TO:<d@e.f>", "rcpt to")
        check(withAuth[5].send.hasSuffix("\r\n."), "data terminated")
        let noAuth = ExternalNotificationBuilders.smtpCommands(host: "mx", from: "a@b.c", to: "d@e.f",
                                                               subject: "t", content: "c",
                                                               requireAuth: false, credentials: nil)
        check(noAuth.count == 6 && !noAuth[2].send.hasPrefix("AUTH"), "no auth when disabled")

        // --- 空凭据门控（不触网）
        let sender = ExternalNotificationSender()
        var empty = ExternalNotificationConfig(kind: .serverChan)
        var r = await sender.send(config: empty, title: "t", content: "c")
        check(!r.success && r.detail.contains("为空"), "serverChan empty key gated offline")
        empty.kind = .bark
        r = await sender.send(config: empty, title: "t", content: "c")
        check(!r.success, "bark empty gated offline")
        empty.kind = .telegram
        r = await sender.send(config: empty, title: "t", content: "c")
        check(!r.success, "telegram empty gated offline")
        empty.kind = .customWebhook
        r = await sender.send(config: empty, title: "t", content: "c")
        check(!r.success, "webhook empty gated offline")

        print("ExternalNotificationTests: \(count) assertions passed")
    }
}
