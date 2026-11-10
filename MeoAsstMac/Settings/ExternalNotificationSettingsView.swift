import SwiftUI

/// P24/E02+E06: 外部通知九渠道配置面（多配置 + 逐配置测试发送 + 错误反馈）。
/// 凭据以明文保存在本机偏好（与上游 WPF 一致，Keychain 加固归档）；错误反馈
/// 不回显密钥（ServerChan 等 key-in-path 渠道只留域名）。
struct ExternalNotificationSettingsView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @ObservedObject var store: ExternalNotificationSettingsStore

    var body: some View {
        Form {
            Toggle("启用外部通知", isOn: $viewModel.externalNotificationEnabled)
            Text("任务完成/公招识别出错/作业完成等事件按下方启用配置逐渠道发送；错误反馈不回显密钥。凭据以明文保存在本机偏好。")
                .font(.caption).foregroundStyle(.secondary)
            ExternalNotificationTriggerPolicyView(store: viewModel.externalNotificationPolicyStore,
                                                  viewModel: viewModel)
            ForEach($store.configs) { $config in
                ExternalNotificationConfigEditor(config: $config)
            }
            HStack {
                Spacer()
                Button("新增配置") {
                    store.configs.append(ExternalNotificationConfig(kind: .serverChan))
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// P25/E03-E05: 触发策略与停滞检测配置（WPF DeliverySettings+NotificationSettings 同位）。
struct ExternalNotificationTriggerPolicyView: View {
    @ObservedObject var store: ExternalNotificationDeliveryPolicyStore
    @ObservedObject var viewModel: MAAViewModel

    var body: some View {
        Section("触发策略") {
            Toggle("完成时发送", isOn: $store.policy.sendWhenComplete)
            Toggle("错误时发送", isOn: $store.policy.sendWhenError)
            Toggle("停滞时发送", isOn: $store.policy.sendWhenStalled)
            Toggle("定时开始前发送", isOn: $store.policy.sendBeforeScheduledStart)
            Toggle("按日志条数发送", isOn: $store.policy.sendAfterLogCount)
            if store.policy.sendAfterLogCount {
                Stepper(value: $store.policy.newLogCount, in: 1...1000) {
                    Text("累计 \(store.policy.newLogCount) 条日志后发送")
                }
            }
            Toggle("按内容匹配发送", isOn: $store.policy.sendWhenContentMatches)
            if store.policy.sendWhenContentMatches {
                TextField("白名单（每行一个正则）", text: $store.policy.whitelist, axis: .vertical)
                    .lineLimit(2...4)
            }
            Toggle("附带最近日志", isOn: $store.policy.includePreviousLogs)
            if store.policy.includePreviousLogs {
                Stepper(value: $store.policy.maxEntries, in: 0...50) {
                    Text("最多附带 \(store.policy.maxEntries) 条")
                }
                Stepper(value: $store.policy.timeMinutes, in: 0...1440) {
                    Text("时间窗 \(store.policy.timeMinutes) 分钟")
                }
                Toggle("过滤最近日志（黑名单）", isOn: $store.policy.filterPreviousLogs)
                if store.policy.filterPreviousLogs {
                    TextField("黑名单（每行一个正则）", text: $store.policy.blacklist, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            Toggle("停滞检测", isOn: $viewModel.notifyStallTimeoutEnabled)
            if viewModel.notifyStallTimeoutEnabled {
                Stepper(value: $viewModel.notifyStallTimeoutMinutes, in: 1...11451) {
                    Text("无输出 \(viewModel.notifyStallTimeoutMinutes) 分钟后告警，按同间隔重复")
                }
            }
        }
    }
}

struct ExternalNotificationConfigEditor: View {
    @Binding var config: ExternalNotificationConfig
    @State private var testDetail: String?
    @State private var isTesting = false

    var body: some View {
        Section {
            Picker("渠道", selection: $config.kind) {
                ForEach(ExternalNotificationChannelKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            fields
            HStack {
                Button(isTesting ? "发送中…" : "测试发送") {
                    isTesting = true
                    testDetail = nil
                    Task {
                        let sender = ExternalNotificationSender()
                        let result = await sender.send(config: config, title: "测试通知", content: "MAA 外部通知测试消息")
                        testDetail = result.success ? "发送成功" : "发送失败：\(result.detail)"
                        isTesting = false
                    }
                }
                .disabled(isTesting || !config.enabled)
                if let testDetail {
                    Text(testDetail).font(.caption).foregroundStyle(testDetail.hasPrefix("发送成功") ? .green : .red)
                        .textSelection(.enabled)
                }
                Spacer()
                Toggle("启用", isOn: $config.enabled)
            }
        } header: {
            Text(config.kind.rawValue)
        }
    }

    @ViewBuilder private var fields: some View {
        switch config.kind {
        case .serverChan:
            TextField("发送密钥", text: $config.sendKey)
        case .telegram:
            TextField("机器人令牌", text: $config.botToken)
            TextField("聊天 ID", text: $config.chatId)
            TextField("主题 ID（可选）", text: $config.topicId)
        case .discord:
            TextField("机器人令牌", text: $config.botToken)
            TextField("用户 ID", text: $config.userID)
        case .dingTalk:
            TextField("访问令牌", text: $config.accessToken)
            TextField("加签密钥（可选）", text: $config.secret)
        case .smtp:
            TextField("SMTP 服务器", text: $config.smtpServer)
            TextField("端口", text: $config.smtpPort)
            Toggle("使用 SSL", isOn: $config.smtpUseSSL)
            Toggle("需要认证", isOn: $config.smtpRequiresAuth)
            if config.smtpRequiresAuth {
                TextField("用户名", text: $config.smtpUsername)
                SecureField("密码", text: $config.smtpPassword)
            }
            TextField("发件人", text: $config.smtpFrom)
            TextField("收件人", text: $config.smtpTo)
        case .bark:
            TextField("发送密钥", text: $config.sendKey)
            TextField("服务器", text: $config.server)
        case .qmsg:
            TextField("密钥", text: $config.key)
            TextField("服务器（可选）", text: $config.server)
            TextField("用户 QQ（可选）", text: $config.user)
            TextField("机器人（可选）", text: $config.bot)
        case .gotify:
            TextField("服务器", text: $config.server)
            TextField("令牌", text: $config.token)
        case .customWebhook:
            TextField("URL", text: $config.url)
            TextField("请求体模板（{title}/{content} 占位）", text: $config.body, axis: .vertical)
                .lineLimit(2...4)
            TextField("请求头 JSON（可选）", text: $config.headers, axis: .vertical)
                .lineLimit(1...3)
        }
    }
}
