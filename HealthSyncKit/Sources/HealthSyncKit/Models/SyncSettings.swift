import Foundation

public enum IntervalUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case minutes, hours, days
    public var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        }
    }
}

/// HealthKit background delivery frequency, mirrored so it can be computed without HealthKit.
public enum BackgroundFrequency: Sendable, Equatable {
    case immediate, hourly, daily
}

/// How often the user wants data synced. iOS treats this as a target, not a guarantee.
public struct SyncInterval: Codable, Hashable, Sendable {
    public var value: Int
    public var unit: IntervalUnit

    public static let minimumSeconds: TimeInterval = 15 * 60
    /// Background tasks may fire slightly before the nominal time; treat that as due.
    static let tolerance: TimeInterval = 60

    public init(value: Int, unit: IntervalUnit) {
        self.value = value
        self.unit = unit
    }

    /// The effective interval, clamped to the 15-minute minimum.
    public var seconds: TimeInterval {
        max(Double(max(value, 1)) * unit.seconds, Self.minimumSeconds)
    }

    public var isBelowMinimum: Bool {
        Double(value) * unit.seconds < Self.minimumSeconds
    }

    public func isDue(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= seconds - Self.tolerance
    }

    public func nextDate(after lastSuccess: Date?, now: Date) -> Date {
        guard let lastSuccess else { return now }
        return max(lastSuccess.addingTimeInterval(seconds), now)
    }

    public var backgroundFrequency: BackgroundFrequency {
        if seconds < 3_600 { return .immediate }
        if seconds < 86_400 { return .hourly }
        return .daily
    }

    public var displayText: String {
        let unitName = value == 1 ? String(unit.rawValue.dropLast()) : unit.rawValue
        return "Every \(value) \(unitName)"
    }
}

/// How far back the first sync reaches.
public enum HistoryRange: String, Codable, CaseIterable, Sendable, Identifiable {
    case week, month, year, all
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .year: "Last year"
        case .all: "All history"
        }
    }

    public func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -7, to: today)
        case .month: return calendar.date(byAdding: .day, value: -30, to: today)
        case .year: return calendar.date(byAdding: .year, value: -1, to: today)
        case .all: return nil
        }
    }
}

/// User configuration, persisted as JSON in UserDefaults by the app.
public struct SyncSettings: Codable, Sendable, Equatable {
    public var enabledMetricIDs: Set<String> = HealthMetric.defaultEnabledIDs
    public var interval = SyncInterval(value: 1, unit: .hours)
    public var folderID: String?
    public var folderName: String?
    public var historyRange: HistoryRange = .month
    public var onboardingComplete = false
    public var notifyOnFailures = true

    public init() {}

    public var enabledMetrics: [HealthMetric] {
        HealthMetric.all.filter { enabledMetricIDs.contains($0.id) }
    }
}
