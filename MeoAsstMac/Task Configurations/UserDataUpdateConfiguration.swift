import Foundation

/// GUI composite task. This name must never be submitted to AsstAppendTask.
struct UserDataUpdateConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .UserDataUpdate }
    var updateOperBox = true
    var updateDepot = true
    var triggerInterval = UserDataUpdateTriggerInterval.everyTime
    var lastDepotSync: UserDataSyncReceipt?
    var lastOperBoxSync: UserDataSyncReceipt?

    var title: String { String(localized: "更新资料") }
    var subtitle: String {
        [updateDepot ? String(localized: "仓库识别") : nil,
         updateOperBox ? String(localized: "干员识别") : nil].compactMap { $0 }.joined(separator: " / ")
    }
    var summary: String { triggerInterval.description }
    var projectedTask: MAATask { .userdataupdate(self) }
    var params: Self { self }

    enum CodingKeys: String, CodingKey {
        case updateOperBox, updateDepot, triggerInterval, lastDepotSync, lastOperBoxSync
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateOperBox = try c.decodeIfPresent(Bool.self, forKey: .updateOperBox) ?? true
        updateDepot = try c.decodeIfPresent(Bool.self, forKey: .updateDepot) ?? true
        triggerInterval = try c.decodeIfPresent(UserDataUpdateTriggerInterval.self, forKey: .triggerInterval) ?? .everyTime
        lastDepotSync = try c.decodeIfPresent(UserDataSyncReceipt.self, forKey: .lastDepotSync)
        lastOperBoxSync = try c.decodeIfPresent(UserDataSyncReceipt.self, forKey: .lastOperBoxSync)
    }

    func dueKinds(scope: InventoryScope, calendar: HGCalendar, at now: Date) -> [UserDataKind] {
        UserDataKind.allCases.filter { kind in
            let enabled = kind == .depot ? updateDepot : updateOperBox
            let receipt = kind == .depot ? lastDepotSync : lastOperBoxSync
            return enabled && triggerInterval.isDue(receipt: receipt, scope: scope, calendar: calendar, at: now)
        }
    }
}

enum UserDataKind: String, CaseIterable, Codable, Hashable, Sendable { case operBox, depot }
struct UserDataSyncReceipt: Codable, Hashable, Sendable {
    let scope: InventoryScope
    let completedAt: Date
}

enum UserDataUpdateTriggerInterval: String, Codable, CaseIterable, Sendable {
    case everyTime, daily, weekly
    var description: String {
        switch self {
        case .everyTime: String(localized: "每次")
        case .daily: String(localized: "每天")
        case .weekly: String(localized: "每周")
        }
    }
    func isDue(receipt: UserDataSyncReceipt?, scope: InventoryScope, calendar: HGCalendar, at now: Date) -> Bool {
        guard self != .everyTime, !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let receipt, receipt.scope == scope,
              (Date.distantPast...Date.distantFuture).contains(receipt.completedAt),
              (Date.distantPast...Date.distantFuture).contains(now),
              receipt.completedAt <= now else { return true }
        switch self {
        case .everyTime: return true
        case .daily: return !calendar.isDate(receipt.completedAt, inSameDayAs: now)
        case .weekly: return !calendar.isDate(receipt.completedAt, inSameWeekAs: now)
        }
    }
}
