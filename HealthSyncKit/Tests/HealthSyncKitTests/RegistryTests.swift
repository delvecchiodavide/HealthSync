import HealthKit
import Testing
@testable import HealthSyncKit

@Suite struct RegistryTests {
    @Test func everyQuantityUnitIsCompatibleWithItsType() {
        for metric in HealthMetric.all {
            guard case .quantity(let id, let unit) = metric.kind else { continue }
            let type = HKQuantityType(HKQuantityTypeIdentifier(rawValue: id))
            #expect(type.is(compatibleWith: HKUnit(from: unit)), "\(metric.id): \(unit) is not compatible")
        }
    }

    @Test func idsAndSheetNamesAreUnique() {
        #expect(Set(HealthMetric.all.map(\.id)).count == HealthMetric.all.count)
        #expect(Set(HealthMetric.all.map(\.sheetName)).count == HealthMetric.all.count)
    }

    @Test func originalIDsAndDefaultsAreUnchanged() {
        // These IDs are persisted in users' settings and sync state; they must never change.
        let original: Set = ["steps", "active_energy", "resting_energy", "heart_rate", "resting_heart_rate", "hrv", "sleep",
                             "body_mass", "workouts", "walking_running_distance", "dietary_energy", "water", "blood_oxygen",
                             "respiratory_rate", "vo2_max", "flights_climbed", "mindful_minutes", "blood_pressure", "body_fat"]
        #expect(original.isSubset(of: Set(HealthMetric.all.map(\.id))))
        #expect(HealthMetric.defaultEnabledIDs == ["steps", "active_energy", "resting_energy", "heart_rate", "resting_heart_rate",
                                                   "hrv", "sleep", "body_mass", "workouts", "walking_running_distance",
                                                   "dietary_energy", "water"])
    }

    @Test func everyCategoryHasMetricsAndEveryTypeHasReadPermission() {
        for category in MetricCategory.allCases {
            #expect(!category.metrics.isEmpty, "\(category) is empty")
        }
        for metric in HealthMetric.all {
            #expect(!HealthKitService.readTypes(for: metric).isEmpty)
        }
    }

    @Test func categoryValueLabels() {
        #expect(CategoryValueSet.severity.label(for: 4) == "severe")
        #expect(CategoryValueSet.menstrualFlow.label(for: 3) == "medium")
        #expect(CategoryValueSet.event.label(for: 0) == "event")
        #expect(CategoryValueSet.testResult.label(for: 99) == "value_99")
    }

    @Test func eventRowsMatchColumns() throws {
        let headache = try #require(HealthMetric.metric(id: "headache"))
        var record = sample("h1")
        record.values = [.string("mild"), .number(30)]
        #expect(RowMapper.row(for: record, syncedAt: Date()).count == headache.columns.count)
        #expect(headache.columns[3...4] == ["value", "duration_min"])
    }
}
