import Foundation
import CryptoKit
import Network

// P24/E02+E06: 九渠道模型层套件（纯函数面+SMTP 套接字级集成+配置持久化+空凭据门控；真实服务 NOT_RUN(凭据)）。
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

        // --- 存储逐条保良：单条损坏不再清空全部配置（评审低3）
        let salvageSuite = "MAAExtNotifSalvage-\(UUID())"
        let salvageDefaults = UserDefaults(suiteName: salvageSuite)!
        defer { salvageDefaults.removePersistentDomain(forName: salvageSuite) }
        let goodObject = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ExternalNotificationConfig(kind: .gotify))) as? [String: Any]) ?? [:]
        let corruptObject: [String: Any] = ["id": UUID().uuidString, "kind": "no-such-kind"]
        let mixed = try JSONSerialization.data(withJSONObject: [corruptObject, goodObject])
        salvageDefaults.set(mixed, forKey: "MAAExternalNotificationConfigs")
        let salvaged = ExternalNotificationSettingsStore(defaults: salvageDefaults)
        check(salvaged.configs.count == 1 && salvaged.configs[0].kind == .gotify, "corrupt entry dropped, survivor kept")

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

        // --- SMTP 纯函数面
        let expectedPlain = Data("\u{0}u\u{0}p".utf8).base64EncodedString()
        check(ExternalNotificationBuilders.smtpAuthPlain(user: "u", password: "p") == "AUTH PLAIN \(expectedPlain)",
              "auth plain base64")
        check(ExternalNotificationBuilders.smtpRecipients("a@b.c, d@e.f;<x@y.z>  w@v.u")
              == ["a@b.c", "d@e.f", "x@y.z", "w@v.u"], "recipients split/strip/dedupe")
        check(ExternalNotificationBuilders.smtpRecipients("").isEmpty, "empty recipients")
        check(ExternalNotificationBuilders.rfc2047B("任务已完成").hasPrefix("=?utf-8?B?"), "non-ASCII subject encoded")
        check(ExternalNotificationBuilders.rfc2047B("plain subject") == "plain subject", "ASCII subject untouched")
        let message = ExternalNotificationBuilders.smtpMessageData(
            from: "a@b.c", recipients: ["d@e.f"], subject: "[MAA] 正文标题", content: "内容")
        let messageText = String(decoding: message, as: UTF8.self)
        check(messageText.contains("Subject: =?utf-8?B?"), "subject RFC2047 in headers")
        check(messageText.contains("Content-Transfer-Encoding: base64"), "body base64 CTE")
        check(messageText.hasSuffix("\r\n"), "message CRLF terminated")
        check(!messageText.contains("\r\r"), "no stray CR pairs")
        check(ExternalNotificationBuilders.smtpDotStuffed(Data(".x\r\ny\r\n".utf8)) == Data("..x\r\ny\r\n".utf8),
              "dot stuffing")

        // --- SMTP 套接字级集成（本地假服务器逐字节对话；评审高1/高2/中4 回归钉）
        let server = FakeSMTPServer()
        try await server.start()
        let client = SMTPClient(host: "127.0.0.1", port: server.port, useSSL: false, timeout: 5)
        try await client.send(from: "a@b.c", recipients: ["d@e.f"], message: message,
                              credentials: ("u", "p"), ehloHost: "client.test")
        check(server.transcript.first == "EHLO client.test", "EHLO first after greeting consumed")
        check(server.transcript.contains("AUTH PLAIN \(expectedPlain)"), "auth line on wire")
        check(server.transcript.contains("MAIL FROM:<a@b.c>") && server.transcript.contains("RCPT TO:<d@e.f>"),
              "envelope on wire")
        check(server.transcript.contains("DATA"), "DATA verb sent")
        check(server.dataPayload?.hasSuffix("\r\n.\r\n") == true, "DATA terminated by dot line")
        check(server.dataPayload?.contains(Data("内容".utf8).base64EncodedString()) == true,
              "message body carried base64-encoded")
        check(server.dataPayload?.contains("内容") != true, "raw content not sent unencoded")
        server.stop()

        // AUTH 被拒：错误面只含动词，凭据不回显（高2）
        let reject = FakeSMTPServer(rejectStep: "AUTH", reply: "550 auth failed")
        try await reject.start()
        do {
            let rejecting = SMTPClient(host: "127.0.0.1", port: reject.port, useSSL: false, timeout: 5)
            try await rejecting.send(from: "a@b.c", recipients: ["d@e.f"], message: message,
                                     credentials: ("u", "p"), ehloHost: "client.test")
            check(false, "auth rejection must throw")
        } catch {
            let text = error.localizedDescription
            check(text.contains("SMTP AUTH"), "error step is verb-only: \(text)")
            check(!text.contains(expectedPlain), "credentials not in error detail")
        }
        reject.stop()

        // MAIL 被拒：动词定位
        let mailReject = FakeSMTPServer(rejectStep: "MAIL", reply: "550 relay denied")
        try await mailReject.start()
        do {
            let rejecting = SMTPClient(host: "127.0.0.1", port: mailReject.port, useSSL: false, timeout: 5)
            try await rejecting.send(from: "a@b.c", recipients: ["d@e.f"], message: message,
                                     credentials: nil, ehloHost: "client.test")
            check(false, "mail rejection must throw")
        } catch {
            check(error.localizedDescription.hasPrefix("SMTP MAIL"), "MAIL rejection step: \(error.localizedDescription)")
        }
        mailReject.stop()

        // 静默服务器：timeout 接线（中4）——run 必须在 deadline 内返回而非永挂
        let silent = FakeSMTPServer(silent: true)
        try await silent.start()
        let began = Date()
        do {
            let hanging = SMTPClient(host: "127.0.0.1", port: silent.port, useSSL: false, timeout: 1)
            try await hanging.send(from: "a@b.c", recipients: ["d@e.f"], message: message,
                                   credentials: nil, ehloHost: "client.test")
            check(false, "silent server must timeout")
        } catch {
            check(Date().timeIntervalSince(began) < 4, "timeout honored within deadline")
        }
        silent.stop()

        // 端口 0：不再强解包崩溃（低2）
        do {
            let invalid = SMTPClient(host: "127.0.0.1", port: 0, useSSL: false, timeout: 1)
            try await invalid.send(from: "a@b.c", recipients: ["d@e.f"], message: message,
                                   credentials: nil, ehloHost: "client.test")
            check(false, "port 0 must throw")
        } catch {
            check(error.localizedDescription.contains("端口"), "port 0 guarded: \(error.localizedDescription)")
        }

        // 明文+AUTH 门控（无 STARTTLS）：离线拒绝（中5 姿态）
        var plainAuth = ExternalNotificationConfig(kind: .smtp)
        plainAuth.smtpServer = "127.0.0.1"
        plainAuth.smtpPort = "25"
        plainAuth.smtpUseSSL = false
        plainAuth.smtpUsername = "u"
        plainAuth.smtpFrom = "a@b.c"
        plainAuth.smtpTo = "d@e.f"
        let policy = await ExternalNotificationSender().send(config: plainAuth, title: "t", content: "c")
        check(!policy.success && policy.detail.contains("STARTTLS"), "plain+auth refused offline: \(policy.detail)")

        // 多收件人：逐条 RCPT（低6）
        let multi = FakeSMTPServer()
        try await multi.start()
        let multiClient = SMTPClient(host: "127.0.0.1", port: multi.port, useSSL: false, timeout: 5)
        try await multiClient.send(from: "a@b.c",
                                   recipients: ExternalNotificationBuilders.smtpRecipients("d@e.f, x@y.z"),
                                   message: message, credentials: nil, ehloHost: "client.test")
        check(multi.transcript.contains("RCPT TO:<d@e.f>") && multi.transcript.contains("RCPT TO:<x@y.z>"),
              "one RCPT per recipient")
        multi.stop()

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

/// 本地假 SMTP 服务器（套接字级对话回归——评审 P24-1-R3 实证路径的反向钉）。
final class FakeSMTPServer {
    var transcript = [String]()
    var dataPayload: String?
    var port: UInt16 = 0
    private var listener: NWListener?
    private var connections = [NWConnection]()
    private var inDataMode = false
    private var dataRaw = Data()
    private let queue = DispatchQueue(label: "maa.fakesmtp")
    private let rejectStep: String?
    private let rejectReply: String
    private let silent: Bool

    init(rejectStep: String? = nil, reply: String = "", silent: Bool = false) {
        self.rejectStep = rejectStep
        self.rejectReply = reply
        self.silent = silent
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let once = TestOnce()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: once.succeed()
            case .failed(let error): once.fail(error)
            case .cancelled: once.fail(CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            once.arm(cont)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        if !silent { send(conn, "220 mx.test ESMTP\r\n") }
        receiveLoop(conn, pending: [])
    }

    private func send(_ conn: NWConnection, _ text: String) {
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ conn: NWConnection, pending: [UInt8]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            var buf = pending
            if let data { buf += [UInt8](data) }
            var lines = [String]()
            while let index = buf.firstIndex(of: 0x0A) {
                var line = Array(buf[..<index])
                buf.removeFirst(index + 1)
                if line.last == 0x0D { line.removeLast() }
                lines.append(String(decoding: line, as: UTF8.self))
            }
            for line in lines {
                if inDataMode {
                    if line == "." {
                        inDataMode = false
                        dataRaw += Data(".\r\n".utf8)
                        dataPayload = String(decoding: dataRaw, as: UTF8.self)
                        send(conn, "250 queued\r\n")
                    } else {
                        dataRaw += Data((line + "\r\n").utf8)
                    }
                    continue
                }
                transcript.append(line)
                if silent { continue }
                if let rejectStep, line.hasPrefix(rejectStep) {
                    send(conn, rejectReply + "\r\n")
                    continue
                }
                if line.hasPrefix("EHLO") {
                    send(conn, "250-mx.test\r\n250-AUTH PLAIN\r\n250 8BITMIME\r\n")
                } else if line.hasPrefix("AUTH") {
                    send(conn, "235 ok\r\n")
                } else if line.hasPrefix("MAIL") {
                    send(conn, "250 ok\r\n")
                } else if line.hasPrefix("RCPT") {
                    send(conn, "250 ok\r\n")
                } else if line.hasPrefix("DATA") {
                    inDataMode = true
                    dataRaw = Data()
                    send(conn, "354 go\r\n")
                } else if line.hasPrefix("QUIT") {
                    send(conn, "221 bye\r\n")
                    conn.cancel()
                }
            }
            receiveLoop(conn, pending: buf)
        }
    }
}

private final class TestOnce {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Error>?
    func arm(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        continuation = cont
        if resumed { cont.resume(returning: ()) }
        lock.unlock()
    }
    func succeed() { finish { $0.resume(returning: ()) } }
    func fail(_ error: Error) { finish { $0.resume(throwing: error) } }
    private func finish(_ body: (CheckedContinuation<Void, Error>) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        if let cont = continuation { body(cont) }
    }
}
