import Foundation

/// A single spreadsheet cell value, written with `valueInputOption=RAW`.
public enum CellValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case empty

    /// Rounds to a fixed number of decimal places so sheets don't show float noise.
    public static func rounded(_ value: Double?, places: Int = 3) -> CellValue {
        guard let value, value.isFinite else { return .empty }
        let factor = pow(10, Double(places))
        return .number((value * factor).rounded() / factor)
    }

    /// JSON-serializable representation for request bodies.
    var jsonValue: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .empty: ""
        }
    }
}

/// A HealthKit sample flattened to plain values, independent of HealthKit types.
public struct SampleRecord: Sendable, Hashable {
    public var uuid: String
    public var start: Date
    public var end: Date
    /// Values for `MetricKind.valueColumns`, in order.
    public var values: [CellValue]
    public var sourceName: String
    public var sourceBundleID: String
    public var device: String
    /// IANA identifier from `HKMetadataKeyTimeZone`, when the sample has one.
    public var timeZoneID: String?

    public init(uuid: String, start: Date, end: Date, values: [CellValue], sourceName: String,
                sourceBundleID: String, device: String, timeZoneID: String? = nil) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.values = values
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.device = device
        self.timeZoneID = timeZoneID
    }
}

/// One page of changes from an anchored HealthKit query.
public struct HealthChanges: Sendable {
    public var added: [SampleRecord]
    public var deletedUUIDs: [String]
    /// Archived `HKQueryAnchor` to persist after this page is uploaded.
    public var newAnchor: Data?
    /// True when the page was full and more changes may be waiting.
    public var hasMore: Bool

    public init(added: [SampleRecord], deletedUUIDs: [String], newAnchor: Data?, hasMore: Bool) {
        self.added = added
        self.deletedUUIDs = deletedUUIDs
        self.newAnchor = newAnchor
        self.hasMore = hasMore
    }
}

/// One row of the Daily Summary spreadsheet.
public struct DailySummary: Sendable, Hashable {
    public var day: String
    public var steps: Double?
    public var activeEnergyKcal: Double?
    public var restingHeartRate: Double?
    public var averageHRV: Double?
    public var sleepHours: Double?
    public var weightKg: Double?
    public var workoutCount: Int?

    public init(day: String, steps: Double? = nil, activeEnergyKcal: Double? = nil, restingHeartRate: Double? = nil,
                averageHRV: Double? = nil, sleepHours: Double? = nil, weightKg: Double? = nil, workoutCount: Int? = nil) {
        self.day = day
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.restingHeartRate = restingHeartRate
        self.averageHRV = averageHRV
        self.sleepHours = sleepHours
        self.weightKg = weightKg
        self.workoutCount = workoutCount
    }

    public static let sheetName = "HealthSync - Daily Summary"
    public static let metricID = "daily_summary"
    public static let columns = ["date", "steps", "active_kcal", "resting_hr_bpm", "avg_hrv_ms",
                                 "sleep_hours", "weight_kg", "workouts", "updated_at"]

    public func row(updatedAt: Date) -> [CellValue] {
        [
            .string(day),
            .rounded(steps, places: 0),
            .rounded(activeEnergyKcal, places: 1),
            .rounded(restingHeartRate, places: 1),
            .rounded(averageHRV, places: 1),
            .rounded(sleepHours, places: 2),
            .rounded(weightKg, places: 2),
            workoutCount.map { .number(Double($0)) } ?? .empty,
            .string(RowMapper.isoString(updatedAt, timeZone: .current)),
        ]
    }
}
