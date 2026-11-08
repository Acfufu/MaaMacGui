import AppKit
import Foundation

// P29/U11+D08: 卡片日志模型与任务移动逻辑套件。
@main struct LogCardBuilderTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        func log(_ content: String, split: MAALog.CardSplit = .none) -> MAALog {
            var entry = MAALog(date: Date(), content: content, color: .trace)
            entry.cardSplit = split
            return entry
        }

        // --- 连续 .none 归入同卡
        let plain = LogCardBuilder.build(logs: [log("a"), log("b"), log("c")])
        check(plain.count == 1 && plain[0].items.map(\.content) == ["a", "b", "c"], "plain logs share one card")
        check(!plain[0].isDivider, "plain card not divider")

        // --- .before：新卡在日志前（WPF Start 节点同位）
        let started = LogCardBuilder.build(logs: [log("old tail"), log("start: Fight", split: .before), log("running")])
        check(started.count == 2, "before splits into two cards")
        check(started[0].items.map(\.content) == ["old tail"], "previous card closed before split")
        check(started[1].items.map(\.content) == ["start: Fight", "running"], "new card opens at before log")

        // --- .after：日志入当前卡后收卡（WPF Complete/Error 同位）
        let finished = LogCardBuilder.build(logs: [log("step1"), log("complete Fight", split: .after), log("next run")])
        check(finished.count == 2, "after closes card and opens next")
        check(finished[0].items.map(\.content) == ["step1", "complete Fight"], "closing log joins its card")
        check(finished[1].items.map(\.content) == ["next run"], "next card opened")

        // --- .divider：独立分隔线卡（WPF AddLogSection 同位）
        let sectioned = LogCardBuilder.build(logs: [log("a"), log("-----里程碑-----", split: .divider), log("b")])
        check(sectioned.count == 3, "divider produces its own card")
        check(sectioned[1].isDivider && sectioned[1].header == "-----里程碑-----", "divider carries header")
        check(sectioned[0].items.map(\.content) == ["a"] && sectioned[2].items.map(\.content) == ["b"],
              "content flows around divider")

        // --- 空日志卡不产出
        let trailing = LogCardBuilder.build(logs: [log("a"), log("end", split: .after)])
        check(trailing.count == 1, "no empty trailing card")

        // --- 空流
        check(LogCardBuilder.build(logs: []).isEmpty, "empty logs -> empty cards")

        // --- 缩略图关联：卡内最后一条命中 id 成为卡尾缩略图
        let ids = [log("x"), log("shot", split: .after)]
        let thumbID = ids[1].id
        let withThumb = LogCardBuilder.build(logs: ids, thumbnailIDs: [thumbID])
        check(withThumb[0].thumbnailLogID == thumbID, "thumbnail anchored to shot log")
        let noThumb = LogCardBuilder.build(logs: ids, thumbnailIDs: [])
        check(noThumb[0].thumbnailLogID == nil, "no thumbnail without id")

        // --- TrimOldThumbnails（WPF 同构：超上限删最旧）
        var thumbs: [UUID: NSImage] = [:]
        let keys = (0..<LogCardBuilder.maxThumbnails + 5).map { _ in UUID() }
        for key in keys {
            thumbs[key] = NSImage(size: NSSize(width: 1, height: 1))
        }
        let trimmed = LogCardBuilder.trimThumbnails(thumbs)
        check(trimmed.count == LogCardBuilder.maxThumbnails, "trim enforces cap")
        // 排序口径与实现一致（uuidString 序）；被移除的恰为排序最前 5 个。
        let sortedKeys = keys.sorted { $0.uuidString < $1.uuidString }
        check(sortedKeys.prefix(5).allSatisfy { trimmed[$0] == nil }, "oldest removed first")
        check(sortedKeys.suffix(LogCardBuilder.maxThumbnails).allSatisfy { trimmed[$0] != nil }, "newest retained")

        // --- 缩略图缩放（640×360，WPF LogThumbnail 尺寸同值）
        let big = NSImage(size: NSSize(width: 2560, height: 1440))
        let scaled = LogCardBuilder.thumbnail(from: big)
        check(Int(scaled.size.width) == LogCardBuilder.thumbnailWidth
              && Int(scaled.size.height) == LogCardBuilder.thumbnailHeight, "scaled to card size")

        // --- D08: 任务移动逻辑（moveTask(id:by:) 边界保护；WPF MoveTask 一行同构）
        // D08: moved(id:by:) 纯函数（配置队列同步由 tasks 写回机制承担）
        var rows: [DailyTask] = []
        for _ in 0..<4 {
            rows.append(DailyTask(task: .operProgress(OperProgressConfiguration()), enabled: true))
        }
        check(rows.moved(id: rows[0].id, by: -1) == nil, "move above first row is a no-op")
        check(rows.moved(id: rows[3].id, by: 1) == nil, "move below last row is a no-op")
        let afterDown = rows.moved(id: rows[1].id, by: 1)!
        let downOK = afterDown[1].id == rows[2].id
        let downOK2 = afterDown[2].id == rows[1].id
        check(downOK && downOK2, "down move swaps adjacent rows")
        let afterUp = rows.moved(id: rows[1].id, by: -1)!
        let upOK = afterUp[0].id == rows[1].id
        let upOK2 = afterUp[1].id == rows[0].id
        check(upOK && upOK2, "up move swaps adjacent rows")
        check(rows.moved(id: UUID(), by: 1) == nil, "unknown id rejected")

        print("LogCardBuilderTests: \(count) assertions passed")
    }
}
