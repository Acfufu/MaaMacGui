//
//  StageCatalogTests.swift
//  MAA
//
//  P05.1: 关卡目录单一判定源 —— 固定样本（真实 StageActivityV2 裁剪）驱动的
//  游戏日边界/切服/活动结束/MinimumRequired/全开放/离线缓存一致性断言。
//

import Foundation

@main
struct StageCatalogTests {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fatalError("usage: stage-catalog-tests <StageActivitySample.json>")
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])

        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date { formatter.date(from: value)! }

        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // MARK: 离线缓存解码（真实文件 IO）

        guard let activities = StageActivityCache.loadActivities(from: fixtureURL) else {
            fatalError("fixture decode failed: \(fixtureURL.path)")
        }
        checks += 1
        let official = activities["Official"]
        check(official != nil, "Official entry missing")
        check(activities["YoStarEN"] != nil, "YoStarEN entry missing")
        check(official?.miniGame.isEmpty == false, "Official miniGame lost")
        check(official?.sideStoryStage?.count == 2, "Official sideStoryStage groups mismatch")
        check(official?.resourceCollection?.interval != nil, "resourceCollection window unparsed")
        let yw = official?.sideStoryStage?["YW"]
        check(yw?.MinimumRequired == "v6.17.0", "YW MinimumRequired not decoded")
        check(yw?.Stages?.first?.Display == "YW-8", "stage Display not decoded")
        check(yw?.Stages?.first?.Drop == "31103", "stage Drop not decoded")
        check(yw?.Activity?.StageName == "昨日海", "Activity StageName not decoded")

        // MARK: 区服键映射（切服口径）

        check(MAAClientChannel.Bilibili.stageActivityKey == "Official", "Bilibili must reuse Official data")

        func catalog(_ channel: MAAClientChannel, activities: MAAStageActivity?, version: String? = "v6.21.2") -> StageCatalog {
            StageCatalog(context: .init(channel: channel, activities: activities), appVersion: version)
        }

        // MARK: 活动窗口与游戏日边界（03:59→04:00）

        let officialCatalog = catalog(.Official, activities: official)
        check(
            officialCatalog.activityEntries(at: date("2026-10-15T12:00:00+08:00"))
                .contains { $0.code == "YW-8" && $0.isOpen },
            "YW-8 must be open mid-window")
        check(
            officialCatalog.activityEntries(at: date("2026-10-08T23:00:00+08:00"))
                .first { $0.code == "YW-8" }?.isOpen == false,
            "YW-8 must be closed before activity start")
        check(
            officialCatalog.activityEntries(at: date("2026-10-23T03:59:58+08:00"))
                .first { $0.code == "YW-8" }?.isOpen == true,
            "YW-8 must stay open at 03:59:58 of the expire game day")
        check(
            officialCatalog.activityEntries(at: date("2026-10-23T04:00:00+08:00"))
                .first { $0.code == "YW-8" }?.isOpen == false,
            "YW-8 must be closed right after the 04:00 game-day reset")
        check(
            officialCatalog.activityEntries(at: date("2026-10-23T03:59:59+08:00"))
                .first { $0.code == "YW-8" }?.isOpen == false,
            "YW-8 must be closed at the exact expire instant (left-closed/right-open rule, same as medicineWindow)")
        check(
            officialCatalog.activityEntries(at: date("2026-11-04T12:00:00+08:00"))
                .first { $0.code == "YW-8" }?.isOpen == false,
            "YW-8 must be closed after activity end")
        check(
            catalog(.YoStarEN, activities: activities["YoStarEN"])
                .activityEntries(at: date("2026-10-15T12:00:00+08:00")).isEmpty,
            "EN server must not inherit Official sideStory groups")

        // MARK: MinimumRequired 版本门槛

        let oldCatalog = catalog(.Official, activities: official, version: "v6.14.0")
        check(
            !oldCatalog.entries(at: date("2026-10-15T12:00:00+08:00")).contains { $0.code == "YW-8" },
            "group above app version must be hidden")
        check(
            oldCatalog.entries(at: date("2026-08-25T12:00:00+08:00")).contains { $0.code == "AT-8" },
            "group at app version must stay visible")
        check(
            StageVersionGate.isSatisfied(minimum: nil, current: nil),
            "missing minimum must pass")
        check(
            StageVersionGate.isSatisfied(minimum: "garbage", current: "v6.21.2"),
            "unparsable minimum must fail open")
        check(
            StageVersionGate.isSatisfied(minimum: "v6.17.0", current: nil),
            "missing current must fail open")
        check(
            !StageVersionGate.isSatisfied(minimum: "v6.30.0", current: "v6.21.2"),
            "newer requirement must block")
        check(
            StageVersionGate.isSatisfied(minimum: "v6.21.0-beta.2", current: "v6.21.2"),
            "prerelease minimum must pass for release build")

        // MARK: 资源收集：星期表 × 全开放覆盖

        // 2026-10-05 是周一：CE-6（[二,四,六,日]）与 CA-5（[二,三,五,日]）常态关闭。
        check(
            catalog(.Official, activities: nil)
                .resourceEntries(at: date("2026-10-05T12:00:00+08:00"))
                .first { $0.code == "CE-6" }?.isOpen == false,
            "CE-6 must follow the weekday table without activity data")
        check(
            officialCatalog.isResourceCollectionAllOpen(at: date("2026-10-05T12:00:00+08:00")),
            "resourceCollection window must read as all-open")
        check(
            officialCatalog.resourceEntries(at: date("2026-10-05T12:00:00+08:00"))
                .first { $0.code == "CE-6" }?.isOpen == true,
            "all-open window must override the weekday table (CE-6)")
        check(
            officialCatalog.resourceEntries(at: date("2026-10-05T12:00:00+08:00"))
                .first { $0.code == "CA-5" }?.isOpen == true,
            "all-open window must override the weekday table (CA-5)")
        check(
            !officialCatalog.isResourceCollectionAllOpen(at: date("2026-11-04T12:00:00+08:00")),
            "all-open window must expire")
        check(
            officialCatalog.resourceEntries(at: date("2026-11-04T12:00:00+08:00"))
                .first { $0.code == "CE-6" }?.isOpen == false,
            "CE-6 must return to weekday rules after the all-open window")

        // EN 服独立窗口（07/30–08/20, UTC-7）：同日 Official 无窗口仍按星期表。
        let enCatalog = catalog(.YoStarEN, activities: activities["YoStarEN"])
        check(
            enCatalog.resourceEntries(at: date("2026-08-03T12:00:00-07:00"))
                .first { $0.code == "CE-6" }?.isOpen == true,
            "EN all-open window must override its own weekday table")
        check(
            catalog(.Official, activities: nil)
                .resourceEntries(at: date("2026-08-03T12:00:00-07:00"))
                .first { $0.code == "CE-6" }?.isOpen == false,
            "EN window must not leak into Official")

        // MARK: 提示与可选目录同谓词

        for sample in ["2026-10-05T12:00:00+08:00", "2026-10-15T12:00:00+08:00", "2026-11-04T12:00:00+08:00"] {
            let at = date(sample)
            let tips = Set(officialCatalog.tips(at: at).map(\.code))
            let open = officialCatalog.openEntries(at: at)
            let selectable = Set(
                open.filter { $0.group == .activity || $0.group == .resourceCollection }
                    .map(\.code))
            // 常驻材料关：提示与可选一一对应
            for code in ["CE-6", "AP-5", "CA-5", "LS-6", "SK-5"] {
                check(
                    tips.contains(code) == selectable.contains(code),
                    "supplies tip/selectable mismatch for \(code) at \(sample)")
            }
            // 芯片关：提示为合并行（PR-x-y/z），目录为逐级条目，两侧谓词一致
            for base in ["PR-A", "PR-B", "PR-C", "PR-D"] {
                let tipOpen = tips.contains { $0.hasPrefix(base) }
                let levels = open.filter { $0.code.hasPrefix(base) && $0.group == .resourceCollection }
                check(
                    tipOpen == !levels.isEmpty && levels.allSatisfy(\.isOpen),
                    "chip tip/selectable mismatch for \(base) at \(sample)")
            }
            // 活动关：开放中的活动关必须全部出现在提示里
            let openActivity = Set(
                open.filter { $0.group == .activity }.map(\.code))
            check(
                openActivity.isSubset(of: tips),
                "open activity stages must appear in tips at \(sample)")
        }

        // MARK: F04 存量选择的关闭处理

        check(officialCatalog.isSelectable("YW-8", at: date("2026-10-15T12:00:00+08:00")), "open activity stage selectable")
        check(!officialCatalog.isSelectable("YW-8", at: date("2026-11-04T12:00:00+08:00")), "closed activity stage not selectable")
        check(!officialCatalog.isSelectable("CE-6", at: date("2026-11-04T12:00:00+08:00")), "weekday-closed stage not selectable")
        check(officialCatalog.isSelectable("1-7", at: date("2026-11-04T12:00:00+08:00")), "mainline stays manual-input")
        check(officialCatalog.isSelectable("AveMujica-8", at: date("2026-11-04T12:00:00+08:00")), "special navigation codes stay allowed")
        check(officialCatalog.isSelectable("", at: date("2026-11-04T12:00:00+08:00")), "current/last always selectable")
        check(officialCatalog.isSelectable("Annihilation", at: date("2026-11-04T12:00:00+08:00")), "annihilation always selectable")

        // MARK: 解码容错（坏数据不拖垮目录）

        let tolerantJSON = """
        {"Official": {
            "miniGame": [{"Value": "MG@X"}],
            "sideStoryStage": {"BROKEN": {"Stages": [{"Value": "X-1"}]}},
            "resourceCollection": {"UtcStartTime": "not-a-date", "UtcExpireTime": "2026/10/20 03:59:59", "TimeZone": 8}
        }}
        """
        let tolerant = try! JSONDecoder().decode([String: MAAStageActivity].self, from: Data(tolerantJSON.utf8))
        let tolerantCatalog = catalog(.Official, activities: tolerant["Official"])
        check(tolerant["Official"]?.sideStoryStage?["BROKEN"] != nil, "malformed group must still decode")
        check(tolerantCatalog.activityEntries(at: date("2026-10-15T12:00:00+08:00")).isEmpty, "group without period must be filtered")
        check(tolerant["Official"]?.resourceCollection?.interval == nil, "malformed all-open window must not parse")
        check(tolerant["Official"]?.miniGame.first?.Value == "MG@X", "miniGame must survive bad activity data")

        print("stage-catalog: \(checks) assertions passed")
    }
}
