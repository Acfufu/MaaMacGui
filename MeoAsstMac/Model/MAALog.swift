//
//  MAALog.swift
//  MAA
//
//  Created by hguandl on 16/4/2023.
//

import Foundation
import SwiftUI

struct MAALog: Identifiable, Hashable {
    enum LogColor {
        case trace
        case info
        case rare
        case warning
        case error
    }

    /// U11 卡片日志分段（WPF LogCardSplitMode 同位）：调用方在关键任务节点标注。
    enum CardSplit: Hashable {
        case none
        /// 在本条日志之前开新卡。
        case before
        /// 在本条日志之后收卡开新卡。
        case after
        /// 本条为分隔线卡（header 即正文）。
        case divider
    }

    let id = UUID()

    let date: Date
    let content: String
    let color: LogColor
    var cardSplit: CardSplit = .none
}

extension Date {
    private func maaLogFormatted(dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = dateFormat
        return formatter.string(from: self)
    }

    var maaGuiLogFormat: String {
        maaLogFormatted(dateFormat: "MM-dd HH:mm:ss")
    }

    var maaFileLogFormat: String {
        maaLogFormatted(dateFormat: "yyyy-MM-dd HH:mm:ss")
    }
}

extension MAALog.LogColor {
    var textColor: Color {
        switch self {
        case .trace:
            return .primary
        case .info:
            return Color("log.color.info")
        case .rare:
            return .orange
        case .warning:
            return .purple
        case .error:
            return .red
        }
    }
}
