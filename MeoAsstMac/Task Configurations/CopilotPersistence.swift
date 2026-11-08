//
//  CopilotPersistence.swift
//  MAA
//
//  Created by parity P13.1 on 2026/11/7.
//

import Foundation

/// Persisted state of the copilot list tab (C09): the activated set and the
/// per-row edits (勾选/突袭/导航覆盖) plus the user's row order.
///
/// Rows are keyed by `ListItem.memberID` (`copilotID#派生难度行`), which stays
/// stable across edits of the row itself: the 常态/突袭 twin rows produced by
/// set `difficulty == 3` share one file but keep distinct keys, and toggling a
/// row's `isRaid` does not orphan its overrides. Overrides for rows that no
/// longer exist in the re-derived listing are dropped on restore.
struct CopilotListState: Codable, Equatable {
    struct ItemOverride: Codable, Equatable {
        var isOn: Bool
        var isRaid: Bool?
        var navOverride: String?
    }

    /// Absolute path of the activated set directory; `nil` = 无激活集。
    var setPath: String?
    /// Row keys in execution order (subset of `overrides` keys plus any new
    /// rows; unknown keys are ignored on restore).
    var order: [String]
    var overrides: [String: ItemOverride]
}

/// Restore outcome reported to the log channel by the view-model bridge.
enum CopilotRestoreOutcome: Equatable {
    /// Nothing to restore (first launch, cleared list, or state taken over).
    case none
    /// The set was re-derived from disk; `skipped` carries per-member reasons.
    case restored(active: Int, skipped: [String])
    /// The persisted set could not be read at all (moved/deleted/corrupt).
    case failed(CopilotRestoreFailure)
}

enum CopilotRestoreFailure: Equatable {
    case setUnreadable

    var logMessage: String {
        switch self {
        case .setUnreadable:
            return String(localized: "上次激活的作业集无法恢复：目录被移动或作业集清单损坏，已重置列表。")
        }
    }
}

enum CopilotPersistence {
    /// Injectable so suites can run against an isolated defaults domain; the
    /// app path always uses `.standard`.
    nonisolated(unsafe) static var store: UserDefaults = .standard

    private static let configurationKey = "CopilotConfigurationState"
    private static let listStateKey = "CopilotListState"

    // MARK: - Configuration (设置持久化)

    static func saveConfiguration(_ config: CopilotConfiguration, store: UserDefaults = CopilotPersistence.store) {
        guard let data = try? JSONEncoder().encode(config) else {
            return
        }
        store.set(data, forKey: configurationKey)
    }

    /// `nil` = 无存档或存档损坏（调用方按缺省值重建，不抛错）。
    static func loadConfiguration(store: UserDefaults = CopilotPersistence.store) -> CopilotConfiguration? {
        guard let data = store.data(forKey: configurationKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CopilotConfiguration.self, from: data)
    }

    // MARK: - List State (列表状态)

    static func saveListState(_ state: CopilotListState, store: UserDefaults = CopilotPersistence.store) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        store.set(data, forKey: listStateKey)
    }

    static func loadListState(store: UserDefaults = CopilotPersistence.store) -> CopilotListState? {
        guard let data = store.data(forKey: listStateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CopilotListState.self, from: data)
    }

    // MARK: - Pure Transforms

    /// Snapshot of the live list rows (didSet 持久化入口共用)。
    static func capture(items: [CopilotContext.ListItem], setURL: URL?) -> CopilotListState {
        var overrides: [String: CopilotListState.ItemOverride] = [:]
        overrides.reserveCapacity(items.count)
        for item in items {
            overrides[item.memberID] = .init(isOn: item.isOn, isRaid: item.isRaid, navOverride: item.navOverride)
        }
        return CopilotListState(
            setPath: setURL?.path(percentEncoded: false),
            order: items.map(\.memberID),
            overrides: overrides)
    }

    /// Rebuilds rows from a fresh listing: persisted overrides are applied
    /// where the member still exists, and `order` decides execution order
    /// (未排序的新成员按派生顺序追加在末尾；order 里的未知键被忽略).
    static func apply(_ state: CopilotListState, to items: [CopilotContext.ListItem]) -> [CopilotContext.ListItem] {
        var applied = items
        for index in applied.indices {
            guard let override = state.overrides[applied[index].memberID] else {
                continue
            }
            applied[index].isOn = override.isOn
            if let isRaid = override.isRaid {
                applied[index].isRaid = isRaid
            }
            applied[index].navOverride = override.navOverride
        }

        let orderLookup = Dictionary(state.order.enumerated().map { ($1, $0) },
                                     uniquingKeysWith: { first, _ in first })
        return applied.enumerated().sorted { lhs, rhs in
            switch (orderLookup[lhs.element.memberID], orderLookup[rhs.element.memberID]) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }
}
