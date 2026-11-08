import ServiceManagement
import SwiftUI

struct SystemSettingsView: View {
    @EnvironmentObject private var viewModel: MAAViewModel

    @State private var showHooks = false
    @State private var showHotkeys = false
    @State private var showExternalNotifications = false
    @State private var showRemoteControl = false
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LoginItemSettingsView()

            Divider()
            Button("日常任务前后脚本…") { showHooks = true }
            Button("全局热键…") { showHotkeys = true }
            Button("外部通知…") { showExternalNotifications = true }
            Button("远控…") { showRemoteControl = true }
            Button("诊断与支持…") { showDiagnostics = true }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $viewModel.runDirectly) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("打开应用即运行")
                            Text("启动后自动开始日常任务, 倒计时内可取消")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $viewModel.skipStartupAutoRunAfterUpdate) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("更新后立即重启时不自动运行")
                            Text("仅在自动安装更新或更新提示中选择立即重启时生效")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Toggle(isOn: $viewModel.preventSystemSleeping) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("阻止系统睡眠")
                    Text("日常任务定时执行会在系统休眠之后失效, 打开此功能可以阻止系统自动睡眠")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $viewModel.blockSleepWithScreenOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("阻止休眠时保持屏幕常亮")
                    Text("任务运行期间保持屏幕点亮, 关闭后允许屏幕休眠而系统保持唤醒")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $viewModel.localNotificationsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("系统通知")
                            Text("任务完成、公招识别出错等事件发送本机通知")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NotificationStatusView(service: viewModel.localNotifications)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $viewModel.runDurationLimitEnabled) {
                        Text("限制运行时长")
                    }
                    if viewModel.runDurationLimitEnabled {
                        Stepper(value: $viewModel.runDurationLimitMinutes, in: 1...RunDurationLimit.maxMinutes) {
                            Text("运行时长上限：\(viewModel.runDurationLimitMinutes) 分钟")
                        }
                        Toggle(isOn: $viewModel.runDurationLimitExecutePostActions) {
                            Text("到点停止后执行收尾动作")
                                .font(.caption)
                        }
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("收尾动作")
                    PostActionSettingsView(store: viewModel.postActionSettings)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showHooks) {
            VStack {
                HookSettingsView(store: viewModel.hookSettings)
                Button("完成") { showHooks = false }.keyboardShortcut(.defaultAction).padding(.bottom)
            }.environmentObject(viewModel)
        }
        .sheet(isPresented: $showHotkeys) {
            HotkeySettingsView(service: viewModel.globalHotkeys)
        }
        .sheet(isPresented: $showExternalNotifications) {
            VStack {
                ExternalNotificationSettingsView(store: viewModel.externalNotificationSettings)
                Button("完成") { showExternalNotifications = false }.keyboardShortcut(.defaultAction).padding(.bottom)
            }.environmentObject(viewModel)
        }
        .sheet(isPresented: $showRemoteControl) {
            VStack {
                RemoteControlSettingsView(service: viewModel.remoteControl)
                Button("完成") { showRemoteControl = false }.keyboardShortcut(.defaultAction).padding(.bottom)
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            VStack {
                DiagnosticsSettingsView()
                Button("完成") { showDiagnostics = false }.keyboardShortcut(.defaultAction).padding(.bottom)
            }.environmentObject(viewModel)
        }
    }
}

struct SystemSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SystemSettingsView()
            .environmentObject(MAAViewModel())
    }
}

/// P23/E01: 通知权限状态行。拒绝时提供系统设置跳转；授权后才允许测试投递。
@MainActor struct NotificationStatusView: View {
    @ObservedObject var service: LocalNotificationService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack {
            statusText.font(.caption).foregroundStyle(.secondary)
            Spacer()
            if service.authorizationState == .denied {
                Button("打开系统通知设置") { service.openSystemSettings() }
            }
            Button("发送测试通知") { Task { await service.sendTest() } }
                .disabled(service.authorizationState != .authorized)
        }
        .onAppear { Task { await service.refreshState() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await service.refreshState() } }
        }
    }

    private var statusText: Text {
        switch service.authorizationState {
        case .loading: Text("正在检查通知权限")
        case .notDetermined: Text("开启开关后请求通知授权")
        case .denied: Text("通知权限被拒绝，请在系统设置中允许")
        case .authorized: Text("系统通知已授权")
        case .unsupported: Text("当前系统不支持通知")
        }
    }
}

/// P22/S17: 收尾动作开关面。锁屏/睡眠/关机等系统动作的实际执行在专用
/// 验收环境验证；此处仅落配置（逐动作失败记录并继续）。
@MainActor struct PostActionSettingsView: View {
    @ObservedObject var store: PostActionSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("有失败任务时跳过收尾动作", isOn: $store.configuration.skipOnError)
            Toggle("返回安卓主页", isOn: $store.configuration.backToAndroidHome)
            Toggle("关闭游戏客户端", isOn: $store.configuration.exitArknights)
            Toggle("退出模拟器", isOn: $store.configuration.exitEmulator)
            Toggle("退出 MAA", isOn: $store.configuration.exitSelf)
            Toggle("锁定屏幕", isOn: $store.configuration.lockScreen)
            Toggle("睡眠", isOn: $store.configuration.sleep)
            Toggle("关机", isOn: $store.configuration.shutdown)
        }
    }
}

@MainActor struct LoginItemSettingsView: View {
    @StateObject private var service: LoginItemService
    @Environment(\.scenePhase) private var scenePhase
    // S02: 与「打开应用即运行」联动更新说明文案。
    @AppStorage("MAARunDirectly") private var runDirectly = false

    init(service: LoginItemService? = nil) {
        _service = StateObject(wrappedValue: service ?? LoginItemService())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "登录时启动 MAA",
                isOn: Binding(
                    get: { service.status == .enabled },
                    set: { enabled in Task { await service.setEnabled(enabled) } }
                )
            )
            .disabled(service.hasPendingOperation)

            Text(runDirectly
                ? "登录后打开应用；已启用「打开应用即运行」，将自动开始日常任务"
                : "登录后仅打开应用，不会自动开始日常任务")
                .font(.caption).foregroundStyle(.secondary)
            statusText.font(.caption).foregroundStyle(.secondary)

            if let error = service.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("重试") { Task { await service.retry() } }
                    .disabled(service.isUpdating)
            }

            VStack(alignment: .leading) {
                Button("打开系统登录项设置") { service.openSettings() }
                if service.status == .requiresApproval {
                    Button("取消登录项申请") {
                        Task { await service.setEnabled(false) }
                    }
                    .disabled(service.hasPendingOperation)
                }
            }
        }
        .onAppear { service.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.refresh()
        }
    }

    private var statusText: Text {
        switch service.status {
        case .notRegistered: Text("登录项未启用")
        case .enabled: Text("登录项已启用")
        case .requiresApproval: Text("等待系统批准，请在系统设置中允许登录时启动")
        case .notFound: Text("找不到登录服务，请将应用移至固定位置后重试")
        @unknown default: Text("无法确认登录项状态，请检查系统设置")
        }
    }
}

#if DEBUG
@MainActor private struct PreviewLoginItem: LoginItemManaging {
    let status: SMAppService.Status
    func register() async throws {}
    func unregister() async throws {}
    func openSettings() {}
}

#Preview("Login item states") {
    VStack(alignment: .leading, spacing: 20) {
        ForEach([SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound], id: \.rawValue) {
            LoginItemSettingsView(service: LoginItemService(manager: PreviewLoginItem(status: $0)))
        }
    }.padding().frame(width: 440)
}
#endif
