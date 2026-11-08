//
//  StageActivity.swift
//  MAA
//
//  Created by hguandl on 2026/9/11.
//

import Foundation

struct StageActivityContext {
    let channel: MAAClientChannel
    let activities: MAAStageActivity?
}

extension StageActivityContext {
    func resourceCollectionStageIsOpen(at date: Date, in weekdays: [Int]?) -> Bool {
        // 资源全开放窗口（IsResourceCollection）内无视星期表。
        if activities?.resourceCollection?.contains(date) == true {
            return true
        }
        if let weekdays, !weekdays.contains(channel.calendar.weekday(for: date)) {
            return false
        }
        return true
    }
}

extension StageActivityContext {
    enum MedicineWindow: Equatable {
        case inactive
        case unavailable
        case extended(days: Int)
    }

    func medicineWindow(at date: Date, enabled: Bool) -> MedicineWindow {
        guard enabled else { return .inactive }
        guard let groups = activities?.sideStoryStage else { return .unavailable }

        var activeEnds: [Date] = []
        var validGroups = 0
        for group in groups.values {
            // Only grouped SideStory stages are known to describe a farming
            // activity. Mini-games and resource-all-open periods are excluded.
            guard let stages = group.Stages, !stages.isEmpty,
                stages.allSatisfy({ !($0.Value ?? "").isEmpty }),
                let period = group.Activity, let range = period.interval
            else { continue }  // One malformed group must not hide valid peers.
            validGroups += 1
            if period.contains(date) {
                activeEnds.append(range.end)
            }
        }
        // A non-empty payload whose groups all failed to parse means the
        // remote data is broken; an empty payload has no activity at all.
        if !groups.isEmpty, validGroups == 0 { return .unavailable }
        guard let end = activeEnds.min(), end.timeIntervalSince(date) < 48 * 3600 else { return .inactive }
        return .extended(days: channel.calendar.medicineExpiryDaysUntilWeekEnd(at: date))
    }
}

extension MAAStageActivity {
    struct SideStoryStage: Decodable, Hashable {
        let Activity: ActivityPeriod?
        let Stages: [SideStoryStageItem]?
        let MinimumRequired: String?
    }

    struct SideStoryStageItem: Decodable, Hashable {
        let Value: String?
        let Display: String?
        let Drop: String?
    }

    struct ActivityPeriod: Decodable, Hashable {
        let UtcStartTime: String?
        let UtcExpireTime: String?
        let TimeZone: Double?
        let Tip: String?
        let StageName: String?

        /// 统一开闭口径：左闭右开 [start, end)，与 medicineWindow 既有语义一致。
        /// Foundation 的 DateInterval.contains 端点闭区间，不能直接复用。
        /// 与 WPF IsActivityOpen 闭区间 [start, end] 存在 ExpireTime 瞬间 ±1s 的端点差
        /// （评审 P12-1-R3 低6，实义可忽略）。
        func contains(_ date: Date) -> Bool {
            guard let interval else { return false }
            return interval.start <= date && date < interval.end
        }

        var interval: DateInterval? {
            guard let offset = TimeZone, offset.isFinite, (-12...14).contains(offset),
                let timeZone = Foundation.TimeZone(secondsFromGMT: Int(offset * 3600)),
                let startText = UtcStartTime, let endText = UtcExpireTime
            else { return nil }
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .gregorian)
            parser.timeZone = timeZone
            parser.dateFormat = "yyyy/MM/dd HH:mm:ss"
            parser.isLenient = false
            guard let start = parser.date(from: startText), let end = parser.date(from: endText),
                parser.string(from: start) == startText, parser.string(from: end) == endText, start < end
            else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}

extension MAAClientChannel {
    var stageActivityKey: String { self == .Bilibili ? MAAClientChannel.Official.rawValue : rawValue }
}

/// P17-[e]（快照 82 清单②裁定：随 WPF 对齐，2026-11-09）：OTA 小游戏条目的
/// 版本门 Tip。`MiniGame.MinimumRequired` 自 P17.1 起解码未消费（Maa.swift
/// 解码面在），WPF `StageManager.cs:560-582` 的消费形态为**条目 Tip 警示、
/// 非硬门禁**：MinimumRequired 不可解析 → 直接以原文警示；当前版本可解析且
/// 低于需求 → 警示；当前版本不可解析 → 不警示（WPF `curVerParsed` 门同）。
/// WPF `isDebugVersion` 豁免在 Mac 无对应渠道概念，恒生效。
enum StageActivityVersionGate {
    /// 解析 "v?X.Y.Z?"（WPF SemVersionStyles.AllowLowerV | OptionalPatch）：
    /// 可选 v/V 前缀、patch 段可选（缺省 0）。不可解析返回 nil。
    static func parseVersion(_ text: String) -> (major: Int, minor: Int, patch: Int)? {
        var body = text
        if let first = body.first, first == "v" || first == "V" {
            body.removeFirst()
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        let patch = numbers.count == 3 ? numbers[2] : 0
        return (numbers[0], numbers[1], patch)
    }

    /// 版本门判定：返回 Tip 文案（「版本过低\n最低需求: <ver>」，WPF
    /// :571-581 组装同构）或 nil（无需警示）。
    static func lowVersionTip(minimumRequired: String?, currentVersion: String) -> String? {
        guard let minimumRequired, !minimumRequired.isEmpty else { return nil }
        let required = String(localized: "最低需求:")
        guard let minReq = parseVersion(minimumRequired) else {
            // WPF :569-573：需求版本不可解析同样警示（附原文）。
            return String(localized: "版本过低") + "\n" + required + " " + minimumRequired
        }
        guard let current = parseVersion(currentVersion) else { return nil }
        let unsupported = (current.major, current.minor, current.patch) < (minReq.major, minReq.minor, minReq.patch)
        guard unsupported else { return nil }
        return String(localized: "版本过低") + "\n" + required + " " + minimumRequired
    }
}
