import AppKit
import Foundation

// P29/U11: 卡片日志模型（WPF LogCardItemViewModel/LogCardSplitMode 同构）。

struct LogCard: Identifiable, Hashable {
    let id = UUID()
    var isDivider: Bool
    var header: String?
    var items: [MAALog]
    /// 卡尾缩略图（挂在产生截图的那条日志的 id 上；nil=未挂载）。
    var thumbnailLogID: UUID?
}

enum LogCardBuilder {
    /// WPF LogThumbnailWidth/Height 同值。
    static let thumbnailWidth = 640
    static let thumbnailHeight = 360
    /// WPF GuiSettings.MaxNumberOfLogThumbnails 同缺省。
    static let maxThumbnails = 100

    /// 日志流 → 卡片流。.before=新卡在日志前；.after=日志入当前卡后收卡；
    /// .divider=独立分隔线卡。空日志卡不产出（微差：WPF 初始空卡渲染为空白）。
    /// thumbnailIDs=已挂载缩略图的日志 id：卡内最后一条命中者成为卡尾缩略图。
    static func build(logs: [MAALog], thumbnailIDs: Set<UUID> = []) -> [LogCard] {
        var cards: [LogCard] = []
        var current = LogCard(isDivider: false, header: nil, items: [], thumbnailLogID: nil)
        var hasCurrent = false

        func flush() {
            if hasCurrent, !current.items.isEmpty {
                cards.append(current)
            }
            current = LogCard(isDivider: false, header: nil, items: [], thumbnailLogID: nil)
            hasCurrent = false
        }

        for log in logs {
            switch log.cardSplit {
            case .none:
                current.items.append(log)
                hasCurrent = true
            case .before:
                flush()
                current.items.append(log)
                hasCurrent = true
            case .after:
                current.items.append(log)
                hasCurrent = true
                flush()
            case .divider:
                flush()
                cards.append(LogCard(isDivider: true, header: log.content, items: [], thumbnailLogID: nil))
            }
        }
        flush()
        return cards.map { card in
            guard let anchor = card.items.last(where: { thumbnailIDs.contains($0.id) })?.id else {
                return card
            }
            var annotated = card
            annotated.thumbnailLogID = anchor
            return annotated
        }
    }

    /// WPF TrimOldThumbnails 同构（低1/P29-2-R3）：超上限按**挂载时序**移除最旧。
    /// 原实现按 uuidString 排序删除——UUID v4 随机序与挂载时序零相关，探针实证
    /// 时间最旧者反被保留（WPF TrimOldThumbnails 按卡片集合序删时间最旧，
    /// TaskQueueViewModel.cs:459-473）；order 由 MAAViewModel 挂载面维护。
    static func staleThumbnailIDs(insertionOrder: [UUID], limit: Int = maxThumbnails) -> [UUID] {
        guard insertionOrder.count > limit else { return [] }
        return Array(insertionOrder.prefix(insertionOrder.count - limit))
    }

    /// WPF CreateBgrBitmapSourceScaled 同构：截图缩至 640×360 卡片缩略图。
    static func thumbnail(from image: NSImage) -> NSImage {
        let size = NSSize(width: thumbnailWidth, height: thumbnailHeight)
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        scaled.unlockFocus()
        return scaled
    }
}
