import Foundation
import os

// 作战日报按日文件存储（WPF DailyReportStore 同构）：
// <userDirectory>/DailyReport/<yyyy-MM-dd>.json，一天一个文件，历史文件不可变。
// 日期为游戏日（各服时区 + 每日 04:00 刷新），由调用方（Collector/ViewModel）经 HGCalendar 取得。

/// WPF 用 Newtonsoft 序列化 DateTimeOffset（带小数秒的 ISO8601），这里编解码两侧都
/// 走自定义格式：编码统一带 3 位小数秒 + 时区，解码兼容有小数/无小数两种形态。
enum DailyReportDateTranscoder {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        if let date = formatter.date(from: string) {
            return date
        }

        if let date = plainFormatter.date(from: string) {
            return date
        }

        // WPF Newtonsoft 写 7 位小数秒（.1234567），Apple 解析器只认 3 位：截断后重试。
        if let range = string.range(of: #"\.\d{4,}"#, options: .regularExpression) {
            let fraction = string[range]
            let trimmed = string.replacingCharacters(in: range, with: fraction.prefix(4))
            return formatter.date(from: trimmed)
        }

        return nil
    }
}

enum DailyReportStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MAA", category: "DailyReportStore")

    /// 加载单日数据，并告知能否安全写入当日文件。
    /// 崩溃遗留的无结束时刻记录保持 nil（展示侧按未结束处理），不虚构停机时长；
    /// 无法读取或解析的文件改名为 .bak 留存，避免随后的保存用空数据覆盖原内容。
    static func load(_ day: Date, calendar: HGCalendar, directory: URL) -> (data: DailyReportDayData?, writable: Bool) {
        let filePath = filePath(for: day, calendar: calendar, directory: directory)
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return (nil, true)
        }

        do {
            let raw = try Data(contentsOf: filePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                guard let date = DailyReportDateTranscoder.date(from: string) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(string)")
                }
                return date
            }
            let data = try decoder.decode(DailyReportDayData.self, from: raw)
            return (data, true)
        } catch {
            logger.error("Failed to load daily report: \(error.localizedDescription)")
            return (nil, backupCorrupted(filePath))
        }
    }

    private static func backupCorrupted(_ filePath: URL) -> Bool {
        let backupPath = filePath.appendingPathExtension("bak")
        do {
            try? FileManager.default.removeItem(at: backupPath)
            try FileManager.default.moveItem(at: filePath, to: backupPath)
            logger.warning("Corrupted daily report moved to \(backupPath.path)")
            return true
        } catch {
            logger.error("Failed to back up corrupted daily report: \(error.localizedDescription)")
            return false
        }
    }

    /// 保存单日数据（全量覆盖写当日文件，历史文件不受影响）。
    /// 先写临时文件再替换，写入中途崩溃或断电时原文件保持完整。
    static func save(_ day: Date, _ data: DailyReportDayData, calendar: HGCalendar, directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filePath = filePath(for: day, calendar: calendar, directory: directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(DailyReportDateTranscoder.string(from: date))
            }
            let raw = try encoder.encode(data)
            let tempPath = filePath.appendingPathExtension("tmp")
            try raw.write(to: tempPath)
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tempPath)
        } catch {
            logger.error("Failed to save daily report: \(error.localizedDescription)")
        }
    }

    /// 列出全部已存在的游戏日（升序）。
    static func listDays(directory: URL) -> [Date] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { Self.dayFromString($0.deletingPathExtension().lastPathComponent) }
            .sorted()
    }

    /// 加载日期范围内的全部日数据（周/月/年视图的数据源），缺日跳过。
    static func loadRange(from: Date, to: Date, calendar: HGCalendar, directory: URL) -> [(day: Date, data: DailyReportDayData)] {
        listDays(directory: directory)
            .filter { day in
                guard let start = startOfDay(from, calendar: calendar), let end = startOfDay(to, calendar: calendar) else {
                    return false
                }
                let this = startOfDay(day, calendar: calendar)
                guard let this else { return false }
                return this >= start && this <= end
            }
            .compactMap { day in
                let (data, _) = load(day, calendar: calendar, directory: directory)
                return data.map { (day, $0) }
            }
    }

    /// 按保留档位删除超期日文件（WPF Prune 同构：近 N 档保留最近 N 个游戏日含今日）。
    static func prune(_ retention: DailyReportRetention, today: Date, calendar: HGCalendar, directory: URL) {
        guard let cutoff = listPrunableDays(retention, today: today, calendar: calendar, directory: directory), !cutoff.isEmpty else {
            return
        }

        for day in cutoff {
            try? FileManager.default.removeItem(at: filePath(for: day, calendar: calendar, directory: directory))
        }
    }

    /// 列出按保留档位将被删除的游戏日（升序）；不限制档位为 nil，供切换档位前确认。
    static func listPrunableDays(_ retention: DailyReportRetention, today: Date, calendar: HGCalendar, directory: URL) -> [Date]? {
        guard let keepDays = retention.keepDays else {
            return nil
        }

        guard let todayStart = startOfDay(today, calendar: calendar) else {
            return []
        }
        guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -(keepDays - 1), to: todayStart) else {
            return []
        }

        return listDays(directory: directory).filter { day in
            guard let start = startOfDay(day, calendar: calendar) else { return false }
            return start < cutoff
        }
    }

    /// 游戏日在文件名里的形态（yyyy-MM-dd，服务器时区 + 04:00 界）。
    static func dayString(for day: Date, calendar: HGCalendar) -> String {
        let shifted = calendar.gameDayComponents(for: day)
        return String(format: "%04d-%02d-%02d", shifted.year ?? 0, shifted.month ?? 0, shifted.day ?? 0)
    }

    static func dayFromString(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }

        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        // 游戏日标识只参与比较与文件名，锚在 UTC 当日 00:00（展示层统一经 HGCalendar 换算）
        return Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: parts[0], month: parts[1], day: parts[2]))
    }

    static func filePath(for day: Date, calendar: HGCalendar, directory: URL) -> URL {
        directory.appendingPathComponent(dayString(for: day, calendar: calendar) + ".json")
    }

    static func startOfDay(_ day: Date, calendar: HGCalendar) -> Date? {
        calendar.startOfGameDay(for: day)
    }
}
