import Foundation
import UserNotifications

// P23/E01: 本机通知服务模型层套件（mock 中心注入，不触碰系统授权）。
@main struct LocalNotificationTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        @MainActor final class MockNotificationCenter: NotificationCentering {
            var requestResult = true
            var statusAfterRequest: UNAuthorizationStatus = .authorized
            var status: UNAuthorizationStatus = .notDetermined
            var alerts: UNNotificationSetting = .enabled
            private(set) var added: [UNNotificationRequest] = []
            private(set) var removedPending: [[String]] = []
            private(set) var requestCalled = 0
            private(set) var openSettingsCalled = 0

            func requestAuthorization() async throws -> Bool {
                requestCalled += 1
                status = statusAfterRequest
                return requestResult
            }
            func authorizationStatus() async -> UNAuthorizationStatus { status }
            func alertSetting() async -> UNNotificationSetting { alerts }
            func add(_ request: UNNotificationRequest) async throws { added.append(request) }
            func removePending(withIdentifiers identifiers: [String]) { removedPending.append(identifiers) }
            func openSettings() { openSettingsCalled += 1 }
        }

        // --- 状态映射（UNNotificationSettings 不可构造，映射保持纯函数）
        check(LocalNotificationService.state(authorization: .notDetermined, alertSetting: .enabled) == .notDetermined, "notDetermined maps")
        check(LocalNotificationService.state(authorization: .denied, alertSetting: .enabled) == .denied, "denied maps")
        check(LocalNotificationService.state(authorization: .authorized, alertSetting: .enabled) == .authorized, "authorized maps")
        check(LocalNotificationService.state(authorization: .provisional, alertSetting: .enabled) == .authorized, "provisional counts as authorized")
        check(LocalNotificationService.state(authorization: .authorized, alertSetting: .notSupported) == .unsupported, "system-level unsupported dominates")

        // --- refreshState / 请求链
        do {
            let mock = MockNotificationCenter()
            let service = LocalNotificationService(center: mock)
            await service.refreshState()
            check(service.authorizationState == .notDetermined, "initial refresh reflects mock")
            service.userEnabled = true
            await service.requestIfNecessary()
            check(mock.requestCalled == 1, "authorization requested when notDetermined")
            check(service.authorizationState == .authorized, "state refreshed after grant")
            await service.requestIfNecessary()
            check(mock.requestCalled == 1, "no repeated request when already authorized")

            let denied = MockNotificationCenter()
            denied.statusAfterRequest = .denied
            let deniedService = LocalNotificationService(center: denied)
            deniedService.userEnabled = true
            await deniedService.requestIfNecessary()
            check(deniedService.authorizationState == .denied, "denial surfaces accurately")
        }

        // --- 投递门控
        do {
            let mock = MockNotificationCenter()
            let service = LocalNotificationService(center: mock)
            await service.send(id: "a", title: "t", body: "b")
            check(mock.added.isEmpty, "disabled service never adds")
            service.userEnabled = true
            await service.send(id: "a", title: "t", body: "b")
            check(mock.added.isEmpty, "unauthorized state gates delivery")
            await service.refreshState()
            service.userEnabled = true
            await service.requestIfNecessary()
            await service.send(id: "run-1", title: "标题", body: "正文")
            check(mock.added.count == 1 && mock.added[0].identifier == "run-1", "authorized delivery reaches center")
            check(mock.added[0].content.title == "标题" && mock.added[0].content.body == "正文", "content carried")
        }

        // --- 重复终态去重（按运行/链标识 + 会话集合）
        do {
            let mock = MockNotificationCenter()
            mock.status = .authorized
            let service = LocalNotificationService(center: mock)
            service.userEnabled = true
            await service.refreshState()
            await service.send(id: "run-A", title: "t", body: "b", deduplicateSession: true)
            await service.send(id: "run-A", title: "t", body: "b", deduplicateSession: true)
            check(mock.added.count == 1, "duplicate terminal in same session suppressed")
            await service.send(id: "run-B", title: "t", body: "b", deduplicateSession: true)
            check(mock.added.count == 2, "next run notifies again")
            await service.send(id: "recruit-1", title: "t", body: "b")
            await service.send(id: "recruit-2", title: "t", body: "b")
            check(mock.added.count == 4, "non-deduplicated events pass through")
        }

        // --- 定时提醒（理智恢复）：同 id 覆盖 + 过去时刻不登记
        do {
            let mock = MockNotificationCenter()
            mock.status = .authorized
            let service = LocalNotificationService(center: mock)
            service.userEnabled = true
            await service.refreshState()
            let now = Date()
            await service.schedule(id: "sanity-recovery", title: "t", body: "b",
                                   fireDate: now.addingTimeInterval(600), at: now)
            check(mock.removedPending == [["sanity-recovery"]], "pending request replaced before scheduling")
            check(mock.added.count == 1, "future fire date scheduled")
            let trigger = mock.added[0].trigger as? UNTimeIntervalNotificationTrigger
            check(trigger != nil && abs(trigger!.timeInterval - 600) < 1, "trigger interval matches recovery gap")
            await service.schedule(id: "sanity-recovery", title: "t", body: "b",
                                   fireDate: now.addingTimeInterval(-5), at: now)
            check(mock.added.count == 1, "past fire date rejected")
            check(mock.removedPending.count == 1, "past fire date leaves pending untouched")
        }

        // --- 测试投递与设置跳转
        do {
            let mock = MockNotificationCenter()
            mock.status = .authorized
            let service = LocalNotificationService(center: mock)
            service.userEnabled = true
            await service.refreshState()
            await service.sendTest()
            check(mock.added.count == 1 && mock.added[0].identifier == LocalNotificationService.testNotificationID, "test send uses fixed id")
            service.openSystemSettings()
            check(mock.openSettingsCalled == 1, "settings deep link routed to center")
        }

        print("LocalNotificationTests: \(count) assertions passed")
    }
}
