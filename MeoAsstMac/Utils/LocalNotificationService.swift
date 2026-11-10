import AppKit
import Foundation
import UserNotifications

/// E01/P23: UNUserNotificationCenter 可注入面。真实现只在用户开启通知后触碰
/// 系统中心（含 delegate 安装），保证无头测试与纯解析路径不依赖系统授权。
@MainActor protocol NotificationCentering {
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func alertSetting() async -> UNNotificationSetting
    func add(_ request: UNNotificationRequest) async throws
    func removePending(withIdentifiers identifiers: [String])
    func openSettings()
}

struct SystemNotificationCenter: NotificationCentering {
    // 类型级 @MainActor（协议推断）会把成员初始化器一并隔离；默认参数在非隔离上下文求值。
    nonisolated init() {}

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func alertSetting() async -> UNNotificationSetting {
        await UNUserNotificationCenter.current().notificationSettings().alertSetting
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func openSettings() {
        // 本 SDK 的 UNUserNotificationCenter 无 openSettings；走系统设置深链。
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// E01/P23: 本机系统通知服务。
/// - 权限状态以系统为权威（授权请求/拒绝/系统级关闭都映射到准确状态）。
/// - 重复终态去重双面：调用方按「运行/链」生成标识符 + 会话级已投递集合；
///   同标识符在系统侧也是替换语义（UN 对已投递/待投递同 id 覆盖）。
/// - 点击通知只重新前置主窗口（onTap 由 App 注入）。
@MainActor final class LocalNotificationService: ObservableObject {
    enum AuthorizationState: Equatable {
        case loading, notDetermined, denied, authorized, unsupported
    }

    static let sanityRecoveryID = "sanity-recovery"
    static let testNotificationID = "test-notification"

    @Published private(set) var authorizationState: AuthorizationState = .loading
    /// 用户总开关（缺省关：历史行为无通知，零暗改）。关闭时一切投递静默跳过。
    var userEnabled = false
    /// 点击通知后的动作（App 注入主窗口前置）。
    var onTap: (@MainActor () -> Void)?

    private let center: any NotificationCentering
    private var sessionDelivered = Set<String>()
    // 协议在新 SDK 为 @MainActor：delegate 须在 MainActor 上构造（延迟到首次安装）。
    private var tapDelegate: TapDelegate?
    private var systemDelegateInstalled = false

    init(center: any NotificationCentering = SystemNotificationCenter()) {
        self.center = center
    }

    /// UNNotificationSettings 无法直接构造；状态映射保持纯函数以便测试。
    nonisolated static func state(authorization: UNAuthorizationStatus,
                                  alertSetting: UNNotificationSetting) -> AuthorizationState {
        if alertSetting == .notSupported { return .unsupported }
        switch authorization {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func refreshState() async {
        let authorization = await center.authorizationStatus()
        let alerts = await center.alertSetting()
        authorizationState = Self.state(authorization: authorization, alertSetting: alerts)
    }

    /// 用户开启开关后的授权链：未决定才弹请求；拒绝/关闭保持可见状态。
    func requestIfNecessary() async {
        guard userEnabled else { return }
        installSystemDelegateIfNeeded()
        await refreshState()
        guard authorizationState == .notDetermined else { return }
        _ = (try? await center.requestAuthorization()) ?? false
        await refreshState()
    }

    func send(id: String, title: String, body: String, deduplicateSession: Bool = false) async {
        guard userEnabled, authorizationState == .authorized else { return }
        if deduplicateSession, !sessionDelivered.insert(id).inserted { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 理智恢复等定时提醒：同 id 先移除待投递再登记（重跑覆盖旧计划）。
    func schedule(id: String, title: String, body: String, fireDate: Date, at now: Date = Date()) async {
        guard userEnabled, authorizationState == .authorized, fireDate > now else { return }
        center.removePending(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSince(now), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func sendTest() async {
        await send(
            id: Self.testNotificationID,
            title: String(localized: "测试通知"),
            body: String(localized: "MAA 本机通知工作正常")
        )
    }

    /// P21/S08: 撤下待投递提醒（计划变更/停用/时刻已过）。
    func cancelPending(id: String) {
        center.removePending(withIdentifiers: [id])
    }

    func openSystemSettings() {
        center.openSettings()
    }

    /// delegate 只装到真实系统中心；注入 mock 的测试进程不触碰 UNUserNotificationCenter。
    private func installSystemDelegateIfNeeded() {
        guard !systemDelegateInstalled, center is SystemNotificationCenter else { return }
        let delegate = TapDelegate()
        UNUserNotificationCenter.current().delegate = delegate
        tapDelegate = delegate
        systemDelegateInstalled = true
    }
}

/// 点击通知 → 仅激活主窗口；前台到达也显示横幅（WPF 前台 toast 同位）。
private final class TapDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let handler = await MainActor.run { LocalNotificationService.sharedTapHandler }
        await MainActor.run { handler?() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension LocalNotificationService {
    /// TapDelegate 无法反向持有 service（delegate 由系统中心强持有）；经共享闭包路由。
    nonisolated(unsafe) static var sharedTapHandler: (@MainActor () -> Void)?

    func installTapHandler(_ handler: @escaping @MainActor () -> Void) {
        Self.sharedTapHandler = handler
    }
}
