import Foundation
import HealthKit

/// How a metric is read from HealthKit and which value columns it produces.
public enum MetricKind: Sendable, Hashable {
    /// A quantity type read in `unit` (an `HKUnit(from:)` string).
    case quantity(identifier: String, unit: String)
    /// A category type whose value is its duration in minutes (e.g. mindful sessions).
    case category(identifier: String)
    case sleep
    case workout
    case bloodPressure

    /// Kind-specific columns, placed between the common leading and trailing columns.
    public var valueColumns: [String] {
        switch self {
        case .quantity, .category: ["value", "unit"]
        case .sleep: ["sleep_stage", "value", "unit"]
        case .workout: ["activity_type", "duration_min", "energy_kcal", "distance_km", "avg_heart_rate_bpm"]
        case .bloodPressure: ["systolic_mmHg", "diastolic_mmHg"]
        }
    }
}

/// A Health data type that can be synced to its own spreadsheet.
public struct HealthMetric: Sendable, Hashable, Identifiable {
    /// Stable key used for persistence. Never change it once shipped.
    public let id: String
    public let displayName: String
    public let kind: MetricKind
    public let defaultEnabled: Bool

    public init(id: String, displayName: String, kind: MetricKind, defaultEnabled: Bool) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.defaultEnabled = defaultEnabled
    }

    public static let commonLeadingColumns = ["uuid", "start_date", "end_date"]
    public static let commonTrailingColumns = ["source_name", "source_bundle_id", "device", "timezone", "synced_at", "deleted"]

    public var sheetName: String { "HealthSync - \(displayName)" }
    public var columns: [String] { Self.commonLeadingColumns + kind.valueColumns + Self.commonTrailingColumns }
    /// Zero-based index of the `deleted` column (always last).
    public var deletedColumnIndex: Int { columns.count - 1 }
}

// MARK: - Registry

extension HealthMetric {
    /// Every supported metric. Adding a new type is one line here.
    public static let all: [HealthMetric] = [
        .quantity("steps", "Steps", .stepCount, "count", on: true),
        .quantity("active_energy", "Active Energy", .activeEnergyBurned, "kcal", on: true),
        .quantity("resting_energy", "Resting Energy", .basalEnergyBurned, "kcal", on: true),
        .quantity("heart_rate", "Heart Rate", .heartRate, "count/min", on: true),
        .quantity("resting_heart_rate", "Resting Heart Rate", .restingHeartRate, "count/min", on: true),
        .quantity("hrv", "Heart Rate Variability", .heartRateVariabilitySDNN, "ms", on: true),
        HealthMetric(id: "sleep", displayName: "Sleep", kind: .sleep, defaultEnabled: true),
        .quantity("body_mass", "Weight", .bodyMass, "kg", on: true),
        HealthMetric(id: "workouts", displayName: "Workouts", kind: .workout, defaultEnabled: true),
        .quantity("walking_running_distance", "Walking + Running Distance", .distanceWalkingRunning, "km", on: true),
        .quantity("dietary_energy", "Dietary Energy", .dietaryEnergyConsumed, "kcal", on: true),
        .quantity("water", "Water", .dietaryWater, "mL", on: true),
        .quantity("blood_oxygen", "Blood Oxygen", .oxygenSaturation, "%"),
        .quantity("respiratory_rate", "Respiratory Rate", .respiratoryRate, "count/min"),
        .quantity("vo2_max", "VO2 Max", .vo2Max, "ml/kg*min"),
        .quantity("flights_climbed", "Flights Climbed", .flightsClimbed, "count"),
        HealthMetric(id: "mindful_minutes", displayName: "Mindful Minutes",
                     kind: .category(identifier: HKCategoryTypeIdentifier.mindfulSession.rawValue), defaultEnabled: false),
        HealthMetric(id: "blood_pressure", displayName: "Blood Pressure", kind: .bloodPressure, defaultEnabled: false),
        .quantity("body_fat", "Body Fat Percentage", .bodyFatPercentage, "%"),
    ]

    public static let defaultEnabledIDs: Set<String> = Set(all.filter(\.defaultEnabled).map(\.id))

    public static func metric(id: String) -> HealthMetric? {
        all.first { $0.id == id }
    }

    static func quantity(_ id: String, _ name: String, _ type: HKQuantityTypeIdentifier, _ unit: String, on: Bool = false) -> HealthMetric {
        HealthMetric(id: id, displayName: name, kind: .quantity(identifier: type.rawValue, unit: unit), defaultEnabled: on)
    }
}
