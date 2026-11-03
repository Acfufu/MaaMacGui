//
//  StageCatalog.swift
//  MAA
//
//  Created by acfufu on 2026/11/4.
//
//  P05: 关卡目录与游戏日历的单一判定源。今日提示与实际可选关卡共用
//  同一开放谓词；活动/全开放窗口来自 OTA 活动数据，资源收集沿用星期表。
//

import Foundation

struct StageCatalog {
    let context: StageActivityContext
    /// 当前 App 版本（CFBundleShortVersionString），用于活动组 MinimumRequired
    /// 门槛；测试可注入。nil 视为门槛放行。
    let appVersion: String?

    init(
        context: StageActivityContext,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) {
        self.context = context
        self.appVersion = appVersion
    }
}

extension StageCatalog {
    enum Group: String, CaseIterable {
        case currentAndLast
        case activity
        case resourceCollection
        case annihilation
    }

    struct Entry: Identifiable, Equatable {
        let code: String
        let name: String
        let drop: String?
        let group: Group
        let isOpen: Bool

        var id: String { code }
    }
}

extension StageCatalog {
    /// 完整目录（含关闭关卡）：当前/上次与剿灭常驻；主线经手输与特殊导航
    /// （F19），不入目录。
    func entries(at date: Date) -> [Entry] {
        [
            Entry(code: "", name: String(localized: "当前/上次"), drop: nil, group: .currentAndLast, isOpen: true),
            Entry(code: "Annihilation", name: String(localized: "剿灭模式"), drop: nil, group: .annihilation, isOpen: true),
        ]
            + activityEntries(at: date)
            + resourceEntries(at: date)
    }

    /// 可选目录：仅保留统一谓词判定开放的关卡（F04 隐藏当天关闭关卡）。
    func openEntries(at date: Date) -> [Entry] {
        entries(at: date).filter(\.isOpen)
    }

    /// 今日提示：与可选目录同一谓词（提示 ⊆ 可选，两侧同源评估）。
    func tips(at date: Date) -> [(code: String, drop: String)] {
        FightStage.tips(for: date, stageActivity: context)
            + activityEntries(at: date).filter(\.isOpen).compactMap { entry in
                entry.drop.map { (entry.code, $0) }
            }
    }

    /// 存量选择的可连性：目录外关卡（主线/手输/特殊关卡名）恒允许；
    /// 目录内关卡按统一谓词判定（F04 关闭后的选择处理）。
    func isSelectable(_ code: String, at date: Date) -> Bool {
        guard let entry = entries(at: date).first(where: { $0.code == code }) else {
            return true
        }
        return entry.isOpen
    }

    /// 资源全开放窗口（IsResourceCollection）当前是否生效。
    func isResourceCollectionAllOpen(at date: Date) -> Bool {
        context.activities?.resourceCollection?.contains(date) ?? false
    }
}

extension StageCatalog {
    /// 当期活动关卡：仅收录版本门槛满足且窗口可解析的组；是否开放由窗口
    /// 判定（未开始/已结束均为 false，但保留在目录里供 F04 提示）。
    func activityEntries(at date: Date) -> [Entry] {
        guard let groups = context.activities?.sideStoryStage, !groups.isEmpty else { return [] }
        return groups.values
            .filter { group in
                guard let period = group.Activity, period.interval != nil else { return false }
                return StageVersionGate.isSatisfied(minimum: group.MinimumRequired, current: appVersion)
            }
            .flatMap { group in
                (group.Stages ?? []).compactMap { item in
                    guard let code = item.Value, !code.isEmpty else { return nil }
                    return Entry(
                        code: code, name: item.Display ?? code, drop: item.Drop,
                        group: .activity,
                        isOpen: group.Activity?.contains(date) ?? false)
                }
            }
    }

    /// 常驻资源收集：开放日由星期表（含全开放覆盖）统一判定。
    func resourceEntries(at date: Date) -> [Entry] {
        (FightStage.supplies + FightStage.chips).map { stage in
            Entry(
                code: stage.code, name: stage.name ?? stage.code, drop: stage.drop,
                group: .resourceCollection,
                isOpen: stage.isOpen(at: date, stageActivity: context))
        }
    }
}

/// 活动数据组的版本门槛。仅比较数字段，预发布后缀（v6.21.0-beta.2）折入
/// 前段数字；任一侧缺失或不可解析时放行——门槛故障不得隐藏本可展示的数据。
enum StageVersionGate {
    static func isSatisfied(minimum: String?, current: String?) -> Bool {
        guard let minimum else { return true }
        guard let required = numericComponents(minimum), let present = current.flatMap(numericComponents) else {
            return true
        }
        let count = max(required.count, present.count)
        let lhs = required + Array(repeating: 0, count: count - required.count)
        let rhs = present + Array(repeating: 0, count: count - present.count)
        for index in 0..<count where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index]
        }
        return true
    }

    private static func numericComponents(_ text: String) -> [Int]? {
        let components = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return components.isEmpty ? nil : components
    }
}

/// OTA 活动数据的离线回退读取：网络失败时使用上次成功下载的缓存副本。
enum StageActivityCache {
    static func loadActivities(from url: URL) -> [String: MAAStageActivity]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: MAAStageActivity].self, from: data)
    }
}
