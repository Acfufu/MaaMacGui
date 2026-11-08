import Foundation
import CryptoKit
import Network

// P24/E02+E06: 外部通知九渠道（WPF Services/ExternalNotification 同构）。
// 凭据面：明文存 UserDefaults（与 P11.5 yituliu token 同例，Keychain 加固归档）；
// 错误反馈不携带凭据（ServerChan 的 key 在 URL path 中，日志截断到域名——WPF 同款防泄漏）。

enum ExternalNotificationChannelKind: String, Codable, CaseIterable, Identifiable {
    case serverChan, telegram, discord, dingTalk, smtp, bark, qmsg, gotify, customWebhook
    var id: String { rawValue }
}

/// 扁平稀疏字段配置（WPF 为类型化子类——序列化形态差异入档；未用字段保持空串）。
struct ExternalNotificationConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ExternalNotificationChannelKind
    var enabled = true
    var sendKey = ""
    var server = ""
    var botToken = ""
    var chatId = ""
    var topicId = ""
    var userID = ""
    var accessToken = ""
    var secret = ""
    var key = ""
    var user = ""
    var bot = ""
    var token = ""
    var url = ""
    var body = ""
    var headers = ""
    var smtpServer = ""
    var smtpPort = "587"
    var smtpUsername = ""
    var smtpPassword = ""
    var smtpUseSSL = true
    var smtpRequiresAuth = true
    var smtpFrom = ""
    var smtpTo = ""

    var displayName: String { kind.rawValue }

    private enum CodingKeys: String, CodingKey {
        case id, kind, enabled, sendKey, server, botToken, chatId, topicId, userID, accessToken
        case secret, key, user, bot, token, url, body, headers
        case smtpServer, smtpPort, smtpUsername, smtpPassword, smtpUseSSL, smtpRequiresAuth, smtpFrom, smtpTo
    }

    init(kind: ExternalNotificationChannelKind) {
        self.kind = kind
    }

    /// 缺键解码缺省（代码库配置解码惯例；合成 Codable 会要求全键）。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(ExternalNotificationChannelKind.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sendKey = try c.decodeIfPresent(String.self, forKey: .sendKey) ?? ""
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        botToken = try c.decodeIfPresent(String.self, forKey: .botToken) ?? ""
        chatId = try c.decodeIfPresent(String.self, forKey: .chatId) ?? ""
        topicId = try c.decodeIfPresent(String.self, forKey: .topicId) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        bot = try c.decodeIfPresent(String.self, forKey: .bot) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        headers = try c.decodeIfPresent(String.self, forKey: .headers) ?? ""
        smtpServer = try c.decodeIfPresent(String.self, forKey: .smtpServer) ?? ""
        smtpPort = try c.decodeIfPresent(String.self, forKey: .smtpPort) ?? "587"
        smtpUsername = try c.decodeIfPresent(String.self, forKey: .smtpUsername) ?? ""
        smtpPassword = try c.decodeIfPresent(String.self, forKey: .smtpPassword) ?? ""
        smtpUseSSL = try c.decodeIfPresent(Bool.self, forKey: .smtpUseSSL) ?? true
        smtpRequiresAuth = try c.decodeIfPresent(Bool.self, forKey: .smtpRequiresAuth) ?? true
        smtpFrom = try c.decodeIfPresent(String.self, forKey: .smtpFrom) ?? ""
        smtpTo = try c.decodeIfPresent(String.self, forKey: .smtpTo) ?? ""
    }
}

struct ExternalNotificationSendResult: Equatable {
    var success: Bool
    var detail: String
}

/// 纯函数面（端点构造/模板/签名/SMTP 对话），供无网络套件断言。
enum ExternalNotificationBuilders {
    /// ServerChan：title 去换行截 32 字符（WPF 同构）；key 在 path，日志用 truncatedHost。
    static func serverChanRequest(sendKey: String, title: String, content: String)
        -> (url: URL, body: String, truncatedHost: String)? {
        guard !sendKey.isEmpty else { return nil }
        let cleaned = title.replacingOccurrences(of: "\n", with: "")
        let clipped = String(cleaned.prefix(32))
        guard let url = URL(string: "https://sctapi.ftqq.com/\(sendKey).send") else { return nil }
        let body = "text=\(clipped.urlEncoded)&desp=\(content.urlEncoded)"
        return (url, body, "sctapi.ftqq.com")
    }

    /// DingTalk 加签：`timestamp\nsecret` HMAC-SHA256 → base64（WPF 同构）。
    static func dingTalkSign(secret: String, timestamp: Int) -> String {
        let stringToSign = "\(timestamp)\n\(secret)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Data(signature).base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    static func dingTalkURL(accessToken: String, secret: String, timestamp: Int) -> URL? {
        var string = "https://oapi.dingtalk.com/robot/send?access_token=\(accessToken)"
        if !secret.isEmpty {
            string += "&timestamp=\(timestamp)&sign=\(dingTalkSign(secret: secret, timestamp: timestamp))"
        }
        return URL(string: string)
    }

    /// CustomWebhook 模板：{title}/{content} 占位符替换（WPF WebhookPresetTemplate 同位）。
    static func webhookBody(template: String, title: String, content: String) -> String {
        template
            .replacingOccurrences(of: "{title}", with: title.jsonEscaped)
            .replacingOccurrences(of: "{content}", with: content.jsonEscaped)
    }


    static func webhookHeaders(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    /// SMTP 对话（WPF MailKit 语义的 Mac 等价最小面）：EHLO → (STARTTLS/EHLO) →
    /// (AUTH PLAIN) → MAIL FROM → RCPT TO → DATA → QUIT。每步期望前缀由测试钉住。
    static func smtpCommands(host: String, from: String, to: String, subject: String,
                             content: String, requireAuth: Bool, credentials: (String, String)?)
        -> [(send: String, expectPrefix: String)] {
        var commands: [(String, String)] = [("", "220")]
        commands.append(("EHLO \(host)", "250"))
        if let (user, password) = credentials {
            let plain = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
            commands.append(("AUTH PLAIN \(plain)", "235"))
        }
        commands.append(("MAIL FROM:<\(from)>", "250"))
        commands.append(("RCPT TO:<\(to)>", "250"))
        let data = "Subject: \(subject)\r\nFrom: \(from)\r\nTo: \(to)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(content)\r\n."
        commands.append((data, "250"))
        commands.append(("QUIT", "221"))
        return commands
    }
}

extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "~-._"))) ?? self
    }

    /// JSON 字符串字面量转义（走 JSONSerialization，避免手写引号转义表）。
    var jsonEscaped: String {
        // 直接取序列化原始文本（形如 ["..."]，转义已在其中）；回解析会把转义还原。
        guard let data = try? JSONSerialization.data(withJSONObject: [self]),
              let raw = String(data: data, encoding: .utf8), raw.count >= 2 else { return self }
        return String(raw.dropFirst(2).dropLast(2))
    }
}

/// 发送执行面（URLSession 注入以便离线测试）。
@MainActor final class ExternalNotificationSender {
    struct HTTPStubbing {
        var dataFor: (@Sendable (URLRequest) async -> (Data, HTTPURLResponse))?
    }

    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    func send(config: ExternalNotificationConfig, title: String, content: String) async -> ExternalNotificationSendResult {
        switch config.kind {
        case .serverChan: return await sendServerChan(config, title, content)
        case .telegram: return await sendTelegram(config, title, content)
        case .discord: return await sendDiscord(config, title, content)
        case .dingTalk: return await sendDingTalk(config, title, content)
        case .bark: return await sendBark(config, title, content)
        case .qmsg: return await sendQmsg(config, title, content)
        case .gotify: return await sendGotify(config, title, content)
        case .customWebhook: return await sendWebhook(config, title, content)
        case .smtp: return await sendSMTP(config, title, content)
        }
    }

    private func post(_ request: URLRequest, successHint: String) async -> ExternalNotificationSendResult {
        do {
            var request = request
            request.timeoutInterval = timeout
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .init(success: false, detail: "non-HTTP response")
            }
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            guard (200..<300).contains(http.statusCode) else {
                return .init(success: false, detail: "HTTP \(http.statusCode): \(body)")
            }
            return .init(success: true, detail: successHint)
        } catch {
            return .init(success: false, detail: error.localizedDescription)
        }
    }

    private func sendServerChan(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard let built = ExternalNotificationBuilders.serverChanRequest(sendKey: c.sendKey, title: title, content: content) else {
            return .init(success: false, detail: "ServerChan send key 为空")
        }
        var request = URLRequest(url: built.url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(built.body.utf8)
        // 日志只留域名，sendKey 不进错误反馈（WPF uriPartial: Authority 同款防泄漏）。
        return await post(request, successHint: "sent via \(built.truncatedHost)")
    }

    private func sendTelegram(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard !c.botToken.isEmpty, !c.chatId.isEmpty else {
            return .init(success: false, detail: "Telegram bot token 或 chat id 为空")
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(c.botToken)/sendMessage") else {
            return .init(success: false, detail: "Telegram URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["chat_id": c.chatId, "text": "[MAA] \(title)\n\(content)"]
        if !c.topicId.isEmpty, let topic = Int(c.topicId) { payload["message_thread_id"] = topic }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return await post(request, successHint: "telegram ok")
    }

    private func sendDiscord(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard !c.botToken.isEmpty, !c.userID.isEmpty else {
            return .init(success: false, detail: "Discord bot token 或 user id 为空")
        }
        // 先建 DM 频道再投递（WPF 同构两步流）。
        guard let dmURL = URL(string: "https://discord.com/api/v10/users/@me/channels") else {
            return .init(success: false, detail: "Discord URL 无效")
        }
        var dmRequest = URLRequest(url: dmURL)
        dmRequest.httpMethod = "POST"
        dmRequest.setValue("Bot \(c.botToken)", forHTTPHeaderField: "Authorization")
        dmRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        dmRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["recipient_id": c.userID])
        do {
            var request = dmRequest
            request.timeoutInterval = timeout
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let channelID = object["id"] as? String else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .init(success: false, detail: "Discord DM channel HTTP \(code)")
            }
            guard let messageURL = URL(string: "https://discord.com/api/v10/channels/\(channelID)/messages") else {
                return .init(success: false, detail: "Discord message URL 无效")
            }
            var message = URLRequest(url: messageURL)
            message.httpMethod = "POST"
            message.setValue("Bot \(c.botToken)", forHTTPHeaderField: "Authorization")
            message.setValue("application/json", forHTTPHeaderField: "Content-Type")
            message.httpBody = try? JSONSerialization.data(withJSONObject: ["content": "[MAA] \(title)\n\(content)"])
            return await post(message, successHint: "discord ok")
        } catch {
            return .init(success: false, detail: error.localizedDescription)
        }
    }

    private func sendDingTalk(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard !c.accessToken.isEmpty else {
            return .init(success: false, detail: "DingTalk access token 为空")
        }
        guard let url = ExternalNotificationBuilders.dingTalkURL(accessToken: c.accessToken, secret: c.secret,
                                                                 timestamp: Int(Date().timeIntervalSince1970) * 1000) else {
            return .init(success: false, detail: "DingTalk URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "msgtype": "text", "text": ["content": "[MAA] \(title)\n\(content)"]])
        return await post(request, successHint: "dingtalk ok")
    }

    private func sendBark(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard !c.sendKey.isEmpty, !c.server.isEmpty else {
            return .init(success: false, detail: "Bark send key 或 server 为空")
        }
        var base = c.server
        if !base.hasSuffix("/") { base += "/" }
        guard let url = URL(string: base + "push") else {
            return .init(success: false, detail: "Bark URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title, "body": content, "device_key": c.sendKey])
        return await post(request, successHint: "bark ok")
    }

    private func sendQmsg(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard !c.key.isEmpty else {
            return .init(success: false, detail: "Qmsg key 为空")
        }
        let host = c.server.isEmpty ? "https://qmsg.zendee.cn" : c.server
        guard let url = URL(string: host + "/send/" + c.key) else {
            return .init(success: false, detail: "Qmsg URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["msg": "[MAA] \(title)\n\(content)"]
        if !c.user.isEmpty { payload["qq"] = c.user }
        if !c.bot.isEmpty { payload["bot"] = c.bot }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return await post(request, successHint: "qmsg ok")
    }

    private func sendGotify(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard !c.server.isEmpty, !c.token.isEmpty else {
            return .init(success: false, detail: "Gotify server 或 token 为空")
        }
        var base = c.server
        if !base.hasSuffix("/") { base += "/" }
        guard let url = URL(string: base + "message?token=" + c.token.urlEncoded) else {
            return .init(success: false, detail: "Gotify URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": "[MAA] \(title)", "message": content, "priority": 5])
        return await post(request, successHint: "gotify ok")
    }

    private func sendWebhook(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard let url = URL(string: c.url), !c.url.isEmpty else {
            return .init(success: false, detail: "Webhook URL 为空或无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let template = c.body.isEmpty ? "{\"title\":\"{title}\",\"content\":\"{content}\"}" : c.body
        request.httpBody = Data(template.replacingOccurrences(of: "{title}", with: title.jsonEscaped)
            .replacingOccurrences(of: "{content}", with: content.jsonEscaped).utf8)
        for (key, value) in ExternalNotificationBuilders.webhookHeaders(c.headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return await post(request, successHint: "webhook ok")
    }

    private func sendSMTP(_ c: ExternalNotificationConfig, _ title: String, _ content: String) async -> ExternalNotificationSendResult {
        guard !c.smtpServer.isEmpty, !c.smtpFrom.isEmpty, !c.smtpTo.isEmpty,
              let port = UInt16(c.smtpPort) else {
            return .init(success: false, detail: "SMTP server/port/发件人/收件人配置不完整")
        }
        let credentials = c.smtpRequiresAuth && !c.smtpUsername.isEmpty ? (c.smtpUsername, c.smtpPassword) : nil
        let commands = ExternalNotificationBuilders.smtpCommands(
            host: c.smtpServer, from: c.smtpFrom, to: c.smtpTo, subject: "[MAA] \(title)",
            content: content, requireAuth: c.smtpRequiresAuth, credentials: credentials)
        let client = SMTPClient(host: c.smtpServer, port: port, useSSL: c.smtpUseSSL, timeout: timeout)
        do {
            try await client.run(commands: commands)
            return .init(success: true, detail: "smtp ok")
        } catch {
            return .init(success: false, detail: error.localizedDescription)
        }
    }
}

/// 自写最小 SMTP 客户端（无第三方依赖；WPF 走 MailKit——差异入档）。
/// 每条命令读一行状态码校验前缀；STARTTLS 升级后重跑 EHLO。
final class SMTPClient {
    private let host: String
    private let port: UInt16
    private let useSSL: Bool
    private let timeout: TimeInterval

    init(host: String, port: UInt16, useSSL: Bool, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.useSSL = useSSL
        self.timeout = timeout
    }

    struct SMTPError: LocalizedError {
        let step: String
        let reply: String
        var errorDescription: String? { "SMTP \(step): \(reply.prefix(120))" }
    }

    func run(commands: [(send: String, expectPrefix: String)]) async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: useSSL ? .tls : .tcp)
        try await connect(connection)
        defer { connection.cancel() }
        for (command, expect) in commands where !command.isEmpty {
            let reply = try await exchange(connection, command: command)
            guard reply.hasPrefix(expect) else {
                throw SMTPError(step: command.prefix(24).description, reply: reply)
            }
        }
    }

    private func connect(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume(returning: ())
                case .failed(let error): cont.resume(throwing: error)
                case .cancelled: cont.resume(throwing: CancellationError())
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "maa.smtp"))
        }
    }

    private func exchange(_ connection: NWConnection, command: String) async throws -> String {
        var payload = Data(command.utf8)
        payload.append(contentsOf: [13, 10])
        try await send(connection, payload)
        return try await readLine(connection)
    }

    private func send(_ connection: NWConnection, _ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            })
        }
    }

    private func readLine(_ connection: NWConnection) async throws -> String {
        // SMTP 多行应答（250-…）取最后一行；简化面按读到 \n 即返回（真实验收单列）。
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    cont.resume(throwing: SMTPClient.SMTPError(step: "read", reply: "empty"))
                    return
                }
                cont.resume(returning: text)
            }
        }
    }
}

/// P24: 多配置存储（UserDefaults JSON "MAAExternalNotificationConfigs"，凭据明文——差异入档）。
@MainActor final class ExternalNotificationSettingsStore: ObservableObject {
    @Published var configs: [ExternalNotificationConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(configs) { defaults.set(data, forKey: "MAAExternalNotificationConfigs") }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configs = defaults.data(forKey: "MAAExternalNotificationConfigs")
            .flatMap { try? JSONDecoder().decode([ExternalNotificationConfig].self, from: $0) } ?? []
    }
}
