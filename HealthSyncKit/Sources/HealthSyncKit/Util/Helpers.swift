import Foundation
import os

public enum Log {
    // Never log health values or tokens; counts and identifiers only.
    public static let sync = Logger(subsystem: "HealthSync", category: "sync")
    public static let google = Logger(subsystem: "HealthSync", category: "google")
    public static let health = Logger(subsystem: "HealthSync", category: "health")
}

extension Array {
    public func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Converts samples to spreadsheet rows.
public enum RowMapper {
    public static func row(for record: SampleRecord, syncedAt: Date, deleted: Bool = false) -> [CellValue] {
        let tz = record.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        return [
            .string(record.uuid),
            .string(isoString(record.start, timeZone: tz)),
            .string(isoString(record.end, timeZone: tz)),
        ] + record.values + [
            .string(record.sourceName),
            .string(record.sourceBundleID),
            .string(record.device),
            .string(tz.identifier),
            .string(isoString(syncedAt, timeZone: .current)),
            .bool(deleted),
        ]
    }

    /// ISO 8601 with the UTC offset, e.g. `2026-10-03T08:15:00+04:00`.
    public static func isoString(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
    }
}

/// A1 notation helpers for the Sheets API.
public enum A1 {
    /// Zero-based column index to letters: 0 → A, 25 → Z, 26 → AA.
    public static func columnLetter(_ index: Int) -> String {
        var n = index + 1
        var letters = ""
        while n > 0 {
            let rem = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + rem))) + letters
            n = (n - 1) / 26
        }
        return letters
    }

    /// Row span of a range like `Data!A2:K5` → 2...5, or `Data!A7` → 7...7.
    public static func rowSpan(of range: String) -> ClosedRange<Int>? {
        let cells = range.split(separator: "!").last ?? Substring(range)
        let rows = cells.split(separator: ":").compactMap { Int($0.filter(\.isNumber)) }
        guard let first = rows.first else { return nil }
        let last = rows.last ?? first
        return first <= last ? first...last : nil
    }
}

public enum DayKey {
    /// `yyyy-MM-dd` in the given calendar's time zone.
    public static func string(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

public enum IntervalMath {
    /// Total duration covered by the intervals, counting overlaps once
    /// (e.g. sleep recorded by both Apple Watch and iPhone).
    public static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in sorted {
            if let c = current, interval.start <= c.end {
                current = DateInterval(start: c.start, end: max(c.end, interval.end))
            } else {
                if let c = current { total += c.duration }
                current = interval
            }
        }
        if let c = current { total += c.duration }
        return total
    }
}

/// Carries a non-Sendable value (e.g. a framework completion handler) across a task boundary
/// when the API contract guarantees it is safe.
public struct UncheckedSendable<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
