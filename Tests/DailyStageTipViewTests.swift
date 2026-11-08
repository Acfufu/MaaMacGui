//
//  DailyStageTipViewTests.swift
//  MAA
//
//  P05.2: 今日提示视图数据面断言 —— tipRows 与关卡目录同谓词、全开放提示、
//  Drop 物品 ID→名称映射（注入物品表）；不挂载 SwiftUI 运行时。
//

import Foundation
import SwiftUI

// 单文件编译桩（同 FightConfigurationTests 模式）：不链 MaaCore，
// StageActivityContext 用真实实现（本壳编译 StageActivity.swift）。
typealias MAATaskConfiguration = Codable & Hashable & Sendable

enum MAATaskType: String {
    case Fight
    var description: String { rawValue }
}

enum MAATask {
    case fight(FightConfiguration)
}

@main
struct DailyStageTipViewTests {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fatalError("usage: daily-stage-tip-tests <StageActivitySample.json>")
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])

        MainActor.assumeIsolated {
            let formatter = ISO8601DateFormatter()
            func date(_ value: String) -> Date { formatter.date(from: value)! }

            var checks = 0
            func check(_ condition: Bool, _ message: String) {
                precondition(condition, message)
                checks += 1
            }

            guard let activities = StageActivityCache.loadActivities(from: fixtureURL) else {
                fatalError("fixture decode failed: \(fixtureURL.path)")
            }
            checks += 1

            // MARK: StageDropLabel 映射口径

            check(StageDropLabel.text("代理1~8关") == "代理1~8关", "non-numeric drop must pass through")
            check(StageDropLabel.text("") == "", "empty drop must pass through")
            check(StageDropLabel.text("31093") == "31093", "numeric drop without loaded table must stay raw")
            FightConfiguration.dropItems = [
                (id: "31093", item: DropItem(classifyType: nil, description: nil, icon: "", name: "聚合剂", sortId: 0, usage: nil, formula: nil)),
                (id: "30053", item: DropItem(classifyType: nil, description: nil, icon: "", name: "固源岩组", sortId: 1, usage: nil, formula: nil)),
            ]
            check(StageDropLabel.text("31093") == "聚合剂", "numeric drop must map via loaded item table")
            check(StageDropLabel.text("30053") == "固源岩组", "second id must map")
            check(StageDropLabel.text("99999") == "99999", "unknown id must stay raw, never invented")

            // MARK: tipRows 与 StageCatalog 同谓词

            let view = DailyStageTipView(channel: .Official, activities: activities["Official"])
            let rawCatalog = StageCatalog(
                context: .init(channel: .Official, activities: activities["Official"]))

            let inWindow = date("2026-10-15T12:00:00+08:00")
            let expected = rawCatalog.tips(at: inWindow).map {
                (code: $0.code, drop: StageDropLabel.text($0.drop))
            }
            check(view.tipRows(at: inWindow).map(\.code) == expected.map(\.code),
                  "tip rows must match catalog tips codes")
            check(view.tipRows(at: inWindow).map(\.drop) == expected.map(\.drop),
                  "tip rows must match catalog tips with drop mapping applied")
            check(view.tipRows(at: inWindow).contains { $0.code == "YW-8" },
                  "in-window activity stage must appear in tips")

            let afterEnd = date("2026-11-04T12:00:00+08:00")
            check(!view.tipRows(at: afterEnd).contains { $0.code == "YW-8" },
                  "ended activity stage must not appear in tips")

            // MARK: 全开放提示与数据缺失口径

            check(view.isResourceCollectionAllOpen(at: date("2026-10-05T12:00:00+08:00")),
                  "all-open hint must be active inside the window")
            check(!view.isResourceCollectionAllOpen(at: afterEnd),
                  "all-open hint must expire after the window")

            let dataless = DailyStageTipView(channel: .Official, activities: nil)
            check(!dataless.isResourceCollectionAllOpen(at: inWindow),
                  "no activity data means no all-open hint")
            check(
                dataless.tipRows(at: date("2026-10-05T12:00:00+08:00")).map(\.code)
                    == StageCatalog(context: .init(channel: .Official, activities: nil))
                        .tips(at: date("2026-10-05T12:00:00+08:00")).map(\.code),
                "dataless rows must equal the activities:nil fallback catalog")
            check(
                !dataless.tipRows(at: date("2026-10-05T12:00:00+08:00")).contains { $0.code.hasPrefix("YW") },
                "dataless rows must not show activity stages")

            print("daily-stage-tip: \(checks) assertions passed")
        }
    }
}
