//
//  HGCalendar.swift
//  MAA
//
//  Created by hguandl on 2026/9/11.
//

import Foundation

public struct HGCalendar: Sendable {
    let calendar: Calendar
    let resetTime: DateComponents
    private let resetOffset: DateComponents

    private func shifted(_ date: Date) -> Date {
        calendar.date(byAdding: resetOffset, to: date)!
    }

    public func isDate(_ date1: Date, inSameDayAs date2: Date) -> Bool {
        calendar.isDate(shifted(date1), inSameDayAs: shifted(date2))
    }

    public func isDate(_ date1: Date, inSameWeekAs date2: Date) -> Bool {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let fields: Set<Calendar.Component> = [.yearForWeekOfYear, .weekOfYear]
        return iso.dateComponents(fields, from: shifted(date1)) == iso.dateComponents(fields, from: shifted(date2))
    }

    public func weekday(for date: Date) -> Int {
        calendar.component(.weekday, from: shifted(date)) - 1
    }

    public func weekdaySymbol(for date: Date) -> String {
        calendar.weekdaySymbols[weekday(for: date)]
    }

    /// F06 周计划 UI：按游戏日星期序号（0=周日…6=周六，weekday(for:) 同一口径）
    /// 取本地化星期名，不依赖具体日期。
    public func weekdaySymbol(at index: Int) -> String {
        calendar.weekdaySymbols[index]
    }

    /// Core medicine expiry counts include the current partial day. The week
    /// ends at the next Monday reset, independent of the host calendar/locale.
    public func medicineExpiryDaysUntilWeekEnd(at date: Date) -> Int {
        let weekday = weekday(for: date)
        return weekday == 0 ? 1 : 8 - weekday
    }

    public func nextReset(after date: Date) -> Date {
        calendar.nextDate(after: date, matching: resetTime, matchingPolicy: .nextTime)!
    }

    /// 游戏日的年月日分量（服务器时区 + 每日 04:00 界；作战日报归档口径）。
    public func gameDayComponents(for date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: shifted(date))
    }

    /// date 在游戏日内的小时（0 起，游戏日 04:00 记 0；作战日报按小时分桶口径）。
    public func gameDayHour(for date: Date) -> Int {
        calendar.component(.hour, from: shifted(date))
    }

    /// 游戏日的规范锚点：该游戏日标签在 UTC 下的当日 00:00。
    /// 仅用于文件名、排序与区间比较，不参与本地时刻展示。
    public func startOfGameDay(for date: Date) -> Date {
        var components = gameDayComponents(for: date)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}

extension MAAClientChannel {
    var calendar: HGCalendar {
        switch self {
        case .Official, .Bilibili, .txwy:
            HGCalendar(timeZone: .utc(hours: 8), resetTime: resetTime)
        case .YoStarEN:
            // EN server time stays at UTC-7 year-round; do not use Pacific daylight-saving rules.
            // Official winter schedule: https://www.arknights.global/news/2116
            HGCalendar(timeZone: .utc(hours: -7), resetTime: resetTime)
        case .YoStarJP, .YoStarKR:
            HGCalendar(timeZone: .utc(hours: 9), resetTime: resetTime)
        }
    }
}

extension HGCalendar {
    fileprivate init(timeZone: TimeZone, resetTime: DateComponents) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.resetTime = resetTime
        resetOffset = .init(
            hour: -(resetTime.hour ?? 0),
            minute: -(resetTime.minute ?? 0),
            second: -(resetTime.second ?? 0))
    }
}

extension TimeZone {
    fileprivate static func utc(hours: Int) -> TimeZone {
        TimeZone(secondsFromGMT: hours * 3600)!
    }
}

private let resetTime = DateComponents(hour: 4, minute: 0, second: 0)
