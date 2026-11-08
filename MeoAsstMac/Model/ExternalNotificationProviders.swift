import Foundation
import CryptoKit
import Network

// P24/E02+E06: 外部通知九渠道（WPF Services/ExternalNotification 同构）。
// 凭据面：明文存 UserDefaults（与 P11.5 yituliu token 同例，Keychain 加固归档）；
// 错误反馈不携带凭据（ServerChan 的 key 在 URL path 中，日志截断到域名——WPF 同款防泄漏；
// SMTP 错误 detail 只含动词+服务器应答，AUTH 行的 base64 凭据永不回显）。

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
    var smtpPort = "465"
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
        smtpPort = try c.decodeIfPresent(String.self, forKey: .smtpPort) ?? "465"
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

    /// SMTP 纯函数面（会话状态机在 SMTPClient；此处为套件断言的字节面）。

    /// AUTH PLAIN 行（base64(\0user\0password)）；错误面凭据脱敏由 SMTPError 负责（只留动词）。
    static func smtpAuthPlain(user: String, password: String) -> String {
        "AUTH PLAIN " + Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
    }

    /// 收件人拆分（逗号/分号/空白；剥包角 <>；去空去重）。
    static func smtpRecipients(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { ",; \t\r\n".contains($0) }).map { part -> String in
            let t = part.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("<") && t.hasSuffix(">") ? String(t.dropFirst().dropLast()) : t
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// RFC 2047 B-编码（仅非 ASCII；ASCII 原样）。
    static func rfc2047B(_ text: String) -> String {
        text.allSatisfy(\.isASCII)
            ? text
            : "=?utf-8?B?" + Data(text.utf8).base64EncodedString() + "?="
    }

    /// 头域值防注入：剥 CR/LF。
    private static func headerSafe(_ s: String) -> String {
        s.filter { $0 != "\r" && $0 != "\n" }
    }

    /// DATA 报文：头（Subject RFC2047/From/To）+ 空行 + base64 正文（76 列折行）。
    /// 正文 base64 化规避裸点/裸 LF 注入面；报文以 CRLF 结尾，终止点由 SMTPClient 的 DATA 步骤承载。
    static func smtpMessageData(from: String, recipients: [String], subject: String, content: String) -> Data {
        let body = Data(content.utf8).base64EncodedString()
        let chars = Array(body)
        let bodyLines = stride(from: 0, to: chars.count, by: 76).map { String(chars[$0..<min($0 + 76, chars.count)]) }
        var lines = [
            "From: \(headerSafe(from))",
            "To: \(headerSafe(recipients.joined(separator: ", ")))",
            "Subject: \(rfc2047B(headerSafe(subject)))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
        ]
        lines += bodyLines
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// 行首裸点字节填充（"."→".."；报文头/正文逐字节兜底）。
    static func smtpDotStuffed(_ payload: Data) -> Data {
        var out = Data()
        var atLineStart = true
        for byte in payload {
            if atLineStart && byte == 0x2E { out.append(0x2E) }
            out.append(byte)
            atLineStart = byte == 0x0A
        }
        return out
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
        guard !c.smtpServer.isEmpty, !c.smtpFrom.isEmpty else {
            return .init(success: false, detail: "SMTP server/发件人配置不完整")
        }
        guard let port = UInt16(c.smtpPort), port > 0, NWEndpoint.Port(rawValue: port) != nil else {
            return .init(success: false, detail: "SMTP 端口无效")
        }
        let recipients = ExternalNotificationBuilders.smtpRecipients(c.smtpTo)
        guard !recipients.isEmpty else {
            return .init(success: false, detail: "SMTP 收件人为空")
        }
        let credentials = c.smtpRequiresAuth && !c.smtpUsername.isEmpty ? (c.smtpUsername, c.smtpPassword) : nil
        // 本客户端无 STARTTLS（NWConnection 不支持在线升级）：明文连接拒绝 AUTH，凭据不裸奔（差异入档）。
        if credentials != nil && !c.smtpUseSSL {
            return .init(success: false, detail: "SMTP 明文连接不支持认证（无 STARTTLS）；请使用 465 端口 + SSL")
        }
        let message = ExternalNotificationBuilders.smtpMessageData(
            from: c.smtpFrom, recipients: recipients, subject: "[MAA] \(title)", content: content)
        let client = SMTPClient(host: c.smtpServer, port: port, useSSL: c.smtpUseSSL, timeout: timeout)
        do {
            try await client.send(from: c.smtpFrom, recipients: recipients, message: message,
                                  credentials: credentials,
                                  ehloHost: ProcessInfo.processInfo.hostName.replacingOccurrences(of: " ", with: ""))
            return .init(success: true, detail: "smtp ok")
        } catch {
            return .init(success: false, detail: error.localizedDescription)
        }
    }
}

/// 自写最小 SMTP 客户端（无第三方依赖；WPF 走 MailKit——差异入档）。
/// 会话状态机：读 220 问候 → EHLO → AUTH PLAIN → MAIL → RCPT×n → DATA → 354 →
/// 报文（dot-stuffed，base64 正文）→ "." → 250 → QUIT。服务器先说话，问候语独立前置读取。
/// 不支持 STARTTLS（NWConnection 无在线升级）：受支持面 = 465+隐式 TLS；明文连接拒 AUTH（sendSMTP 门控）。
/// timeout 全程接线（连接/收发共用同一 deadline，超时取消连接）；错误 detail 只含动词+服务器应答，不含凭据。
final class SMTPClient {
    private let host: String
    private let port: UInt16
    private let useSSL: Bool
    private let timeout: TimeInterval
    private var queue: DispatchQueue!
    private var connection: NWConnection?
    private var pending = [UInt8]()
    private var deadline = Date.distantFuture

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

    /// continuation 只恢复一次（state handler 多次触发/超时定时器/收发回调竞争的唯一出口）。
    private final class Once<T> {
        private let lock = NSLock()
        private var resumed = false
        private var continuation: CheckedContinuation<T, Error>

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func succeed(_ value: T) { resume { $0.resume(returning: value) } }
        func fail(_ error: Error) { resume { $0.resume(throwing: error) } }

        private func resume(_ body: (CheckedContinuation<T, Error>) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            body(continuation)
        }
    }

    func send(from: String, recipients: [String], message: Data,
              credentials: (String, String)?, ehloHost: String) async throws {
        guard port > 0, let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw SMTPError(step: "connect", reply: "端口 \(port) 无效")
        }
        queue = DispatchQueue(label: "maa.smtp.\(UUID().uuidString)")
        pending = []
        deadline = Date().addingTimeInterval(timeout)
        let conn = NWConnection(
            host: NWEndpoint.Host(host), port: endpoint, using: useSSL ? .tls : .tcp)
        connection = conn
        defer { conn.cancel() }
        try await connect(conn)
        let greeting = try await readReply(step: "GREETING")
        guard greeting.hasPrefix("220") else { throw SMTPError(step: "GREETING", reply: greeting) }
        _ = try await command("EHLO \(ehloHost)", expect: "250")
        if let (user, password) = credentials {
            _ = try await command(ExternalNotificationBuilders.smtpAuthPlain(user: user, password: password), expect: "235")
        }
        _ = try await command("MAIL FROM:<\(from)>", expect: "250")
        for recipient in recipients {
            _ = try await command("RCPT TO:<\(recipient)>", expect: "250")
        }
        _ = try await command("DATA", expect: "354")
        try await sendRaw(ExternalNotificationBuilders.smtpDotStuffed(message) + Data(".\r\n".utf8))
        let accepted = try await readReply(step: "DATA")
        guard accepted.hasPrefix("250") else { throw SMTPError(step: "DATA", reply: accepted) }
        // QUIT 失败不影响投递结果（信件已被服务器接收）。
        _ = try? await command("QUIT", expect: "221")
    }

    private func connect(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once(cont)
            let timer = scheduleDeadline {
                once.fail(SMTPError(step: "connect", reply: "连接超时"))
                conn.cancel()
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timer.cancel()
                    once.succeed(())
                case .failed(let error):
                    timer.cancel()
                    once.fail(error)
                case .cancelled:
                    timer.cancel()
                    once.fail(CancellationError())
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        // 就绪后摘除 handler：之后 defer 的 cancel 不再触碰任何 continuation。
        conn.stateUpdateHandler = nil
    }

    private func command(_ line: String, expect: String) async throws -> String {
        try await sendRaw(Data(line.utf8) + Data("\r\n".utf8))
        let reply = try await readReply(step: verb(of: line))
        guard reply.hasPrefix(expect) else { throw SMTPError(step: verb(of: line), reply: reply) }
        return reply
    }

    /// 错误面只保留动词（AUTH PLAIN 的 base64 凭据永不进 detail）。
    private func verb(of line: String) -> String {
        line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? line
    }

    private func sendRaw(_ payload: Data) async throws {
        guard let conn = connection else { throw SMTPError(step: "send", reply: "连接未建立") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once(cont)
            let timer = scheduleDeadline {
                once.fail(SMTPError(step: "send", reply: "发送超时"))
                conn.cancel()
            }
            conn.send(content: payload, completion: .contentProcessed { error in
                timer.cancel()
                if let error { once.fail(error) } else { once.succeed(()) }
            })
        }
    }

    /// 多行应答（250-…）逐行累积，直到末行（第 4 字符为空格或行长 3）。
    private func readReply(step: String) async throws -> String {
        var lines = [String]()
        while true {
            let line = try await readLine(step: step)
            lines.append(line)
            let digits = line.prefix(3)
            guard digits.count == 3, digits.allSatisfy(\.isNumber) else {
                throw SMTPError(step: step, reply: line)
            }
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { break }
        }
        return lines.joined(separator: "\n")
    }

    /// 行式读取：缓冲区累积任意到货字节块，凑齐 \n 才切行（TCP 分段安全）。
    private func readLine(step: String) async throws -> String {
        while true {
            if let index = pending.firstIndex(of: 0x0A) {
                var lineBytes = Array(pending[..<index])
                pending.removeFirst(index + 1)
                if lineBytes.last == 0x0D { lineBytes.removeLast() }
                guard let text = String(bytes: lineBytes, encoding: .utf8) else {
                    throw SMTPError(step: step, reply: "非 UTF-8 应答")
                }
                return text
            }
            guard let conn = connection else { throw SMTPError(step: step, reply: "连接未建立") }
            let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let once = Once(cont)
                let timer = scheduleDeadline {
                    once.fail(SMTPError(step: step, reply: "应答超时"))
                    conn.cancel()
                }
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    timer.cancel()
                    if let error { once.fail(error); return }
                    if let data, !data.isEmpty { once.succeed(data) }
                    else { once.fail(SMTPError(step: step, reply: isComplete ? "连接已关闭" : "空应答")) }
                }
            }
            pending += [UInt8](chunk)
        }
    }

    /// 会话级 deadline 定时器（操作完成即 cancel；触发则取消连接兜底）。
    private func scheduleDeadline(onFire: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: onFire)
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
        return item
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
        if let data = defaults.data(forKey: "MAAExternalNotificationConfigs") {
            if let all = try? JSONDecoder().decode([ExternalNotificationConfig].self, from: data) {
                configs = all
            } else if let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // 逐条保良：单条损坏只丢弃该条，不再静默清空全部配置（评审低3）。
                configs = entries.compactMap { entry in
                    guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
                    return try? JSONDecoder().decode(ExternalNotificationConfig.self, from: entryData)
                }
            } else {
                configs = []
            }
        } else {
            configs = []
        }
    }
}
