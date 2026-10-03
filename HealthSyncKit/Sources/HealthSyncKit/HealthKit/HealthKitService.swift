import Foundation
import HealthKit

public protocol HealthDataSource: Sendable {
    /// One page of samples added/deleted since `anchor`, limited to samples starting on or after `since`.
    func changes(for metric: HealthMetric, anchor: Data?, since: Date?, limit: Int) async throws -> HealthChanges
    /// One summary per calendar day in `[start, end)`, ascending.
    func dailySummaries(from start: Date, to end: Date) async throws -> [DailySummary]
}

/// Reads Apple Health data on this device. Read-only: the app never writes to HealthKit.
public final class HealthKitService: HealthDataSource, @unchecked Sendable {
    public let healthStore = HKHealthStore()
    private let lock = NSLock()
    private var observerQueries: [HKObserverQuery] = []

    public init() {}

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Authorization

    public func requestAuthorization(for metrics: [HealthMetric]) async throws {
        guard Self.isAvailable else { throw SyncError.healthKitUnavailable }
        let types = Set(metrics.flatMap(Self.readTypes(for:)))
        try await healthStore.requestAuthorization(toShare: [], read: types)
    }

    static func readTypes(for metric: HealthMetric) -> [HKObjectType] {
        switch metric.kind {
        case .quantity(let id, _):
            return [HKQuantityType(HKQuantityTypeIdentifier(rawValue: id))]
        case .category(let id):
            return [HKCategoryType(HKCategoryTypeIdentifier(rawValue: id))]
        case .sleep:
            return [HKCategoryType(.sleepAnalysis)]
        case .workout:
            // Heart rate is needed for the workout's average heart rate.
            return [HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        case .bloodPressure:
            // Correlation types can't be requested directly; request their components.
            return [HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)]
        }
    }

    /// The type observed for background delivery.
    static func observedType(for metric: HealthMetric) -> HKSampleType {
        switch metric.kind {
        case .quantity(let id, _): HKQuantityType(HKQuantityTypeIdentifier(rawValue: id))
        case .category(let id): HKCategoryType(HKCategoryTypeIdentifier(rawValue: id))
        case .sleep: HKCategoryType(.sleepAnalysis)
        case .workout: HKObjectType.workoutType()
        case .bloodPressure: HKQuantityType(.bloodPressureSystolic)
        }
    }

    // MARK: Background delivery

    /// Registers observer queries and background delivery. Call on every launch,
    /// before `didFinishLaunching` returns, so HealthKit can wake the app.
    public func startObserving(_ metrics: [HealthMetric], frequency: BackgroundFrequency,
                               onUpdate: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = observerQueries
        observerQueries = []
        lock.unlock()
        previous.forEach(healthStore.stop)

        let hkFrequency: HKUpdateFrequency = switch frequency {
        case .immediate: .immediate
        case .hourly: .hourly
        case .daily: .daily
        }

        healthStore.disableAllBackgroundDelivery { _, _ in }
        var queries: [HKObserverQuery] = []
        for type in Set(metrics.map(Self.observedType(for:))) {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if let error {
                    Log.health.error("Observer query failed: \(error.localizedDescription, privacy: .public)")
                    completion()
                    return
                }
                // HealthKit requires the completion handler to be called once the work is done.
                let done = UncheckedSendable(completion)
                Task {
                    await onUpdate()
                    done.value()
                }
            }
            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: type, frequency: hkFrequency) { _, error in
                if let error {
                    Log.health.error("Background delivery failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            queries.append(query)
        }
        lock.lock()
        observerQueries = queries
        lock.unlock()
    }

    // MARK: Anchored changes

    public func changes(for metric: HealthMetric, anchor: Data?, since: Date?, limit: Int) async throws -> HealthChanges {
        let queryAnchor = try anchor.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate) }

        let added: [SampleRecord]
        let deleted: [HKDeletedObject]
        let newAnchor: HKQueryAnchor

        switch metric.kind {
        case .quantity(let id, let unitString):
            let unit = HKUnit(from: unitString)
            let result = try await anchored(.quantitySample(type: HKQuantityType(HKQuantityTypeIdentifier(rawValue: id)), predicate: predicate),
                                            anchor: queryAnchor, limit: limit)
            added = result.added.map { sample in
                var value = sample.quantity.doubleValue(for: unit)
                if unit == .percent() { value *= 100 }
                return Self.record(sample, values: [.rounded(value, places: 4), .string(unitString)])
            }
            (deleted, newAnchor) = (result.deleted, result.anchor)

        case .category(let id):
            let result = try await anchored(.categorySample(type: HKCategoryType(HKCategoryTypeIdentifier(rawValue: id)), predicate: predicate),
                                            anchor: queryAnchor, limit: limit)
            added = result.added.map { sample in
                Self.record(sample, values: [.rounded(sample.endDate.timeIntervalSince(sample.startDate) / 60, places: 2), .string("min")])
            }
            (deleted, newAnchor) = (result.deleted, result.anchor)

        case .sleep:
            let result = try await anchored(.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate),
                                            anchor: queryAnchor, limit: limit)
            added = result.added.map { sample in
                Self.record(sample, values: [
                    .string(Self.sleepStageName(sample.value)),
                    .rounded(sample.endDate.timeIntervalSince(sample.startDate) / 60, places: 2),
                    .string("min"),
                ])
            }
            (deleted, newAnchor) = (result.deleted, result.anchor)

        case .workout:
            let result = try await anchored(.workout(predicate), anchor: queryAnchor, limit: limit)
            added = result.added.map { workout in
                let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
                let distance = workout.allStatistics
                    .first { $0.key.identifier.hasPrefix("HKQuantityTypeIdentifierDistance") }?
                    .value.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo))
                let heartRate = workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?
                    .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                return Self.record(workout, values: [
                    .string(Self.activityName(workout.workoutActivityType)),
                    .rounded(workout.duration / 60, places: 2),
                    .rounded(energy, places: 1),
                    .rounded(distance, places: 3),
                    .rounded(heartRate, places: 1),
                ])
            }
            (deleted, newAnchor) = (result.deleted, result.anchor)

        case .bloodPressure:
            let result = try await anchored(.correlation(type: HKCorrelationType(.bloodPressure), predicate: predicate),
                                            anchor: queryAnchor, limit: limit)
            let mmHg = HKUnit.millimeterOfMercury()
            added = result.added.map { correlation in
                let systolic = (correlation.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg)
                let diastolic = (correlation.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg)
                return Self.record(correlation, values: [.rounded(systolic, places: 0), .rounded(diastolic, places: 0)])
            }
            (deleted, newAnchor) = (result.deleted, result.anchor)
        }

        let anchorData = try NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
        Log.health.debug("\(metric.id, privacy: .public): \(added.count) added, \(deleted.count) deleted")
        return HealthChanges(added: added, deletedUUIDs: deleted.map(\.uuid.uuidString), newAnchor: anchorData,
                             hasMore: added.count + deleted.count >= limit)
    }

    private func anchored<S: HKSample>(_ predicate: HKSamplePredicate<S>, anchor: HKQueryAnchor?, limit: Int)
        async throws -> (added: [S], deleted: [HKDeletedObject], anchor: HKQueryAnchor) {
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [predicate], anchor: anchor, limit: limit)
        do {
            let result = try await descriptor.result(for: healthStore)
            return (result.addedSamples, result.deletedObjects, result.newAnchor)
        } catch {
            throw Self.mapError(error)
        }
    }

    static func record(_ sample: HKSample, values: [CellValue]) -> SampleRecord {
        SampleRecord(
            uuid: sample.uuid.uuidString,
            start: sample.startDate,
            end: sample.endDate,
            values: values,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
            device: sample.device?.name ?? sample.sourceRevision.productType ?? "",
            timeZoneID: sample.metadata?[HKMetadataKeyTimeZone] as? String
        )
    }

    static func mapError(_ error: Error) -> Error {
        if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible {
            return SyncError.healthDataLocked
        }
        return error
    }

    // MARK: Daily summary

    public func dailySummaries(from start: Date, to end: Date) async throws -> [DailySummary] {
        let calendar = Calendar.current
        do {
            let steps = try await dailyStatistics(.stepCount, .cumulativeSum, .count(), start, end)
            let energy = try await dailyStatistics(.activeEnergyBurned, .cumulativeSum, .kilocalorie(), start, end)
            let restingHR = try await dailyStatistics(.restingHeartRate, .discreteAverage, HKUnit.count().unitDivided(by: .minute()), start, end)
            let hrv = try await dailyStatistics(.heartRateVariabilitySDNN, .discreteAverage, .secondUnit(with: .milli), start, end)
            let weight = try await dailyStatistics(.bodyMass, .mostRecent, .gramUnit(with: .kilo), start, end)
            let sleep = try await dailySleepHours(start, end, calendar)
            let workouts = try await dailyWorkoutCounts(start, end, calendar)

            var summaries: [DailySummary] = []
            var day = calendar.startOfDay(for: start)
            while day < end {
                let key = DayKey.string(for: day, calendar: calendar)
                summaries.append(DailySummary(day: key, steps: steps[key], activeEnergyKcal: energy[key], restingHeartRate: restingHR[key],
                                              averageHRV: hrv[key], sleepHours: sleep[key], weightKg: weight[key],
                                              workoutCount: workouts[key] ?? 0))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return summaries
        } catch {
            throw Self.mapError(error)
        }
    }

    private func dailyStatistics(_ id: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions, _ unit: HKUnit,
                                 _ start: Date, _ end: Date) async throws -> [String: Double] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: options,
            anchorDate: Calendar.current.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: healthStore)
        var values: [String: Double] = [:]
        for statistics in collection.statistics() {
            let quantity: HKQuantity? = if options.contains(.cumulativeSum) {
                statistics.sumQuantity()
            } else if options.contains(.mostRecent) {
                statistics.mostRecentQuantity()
            } else {
                statistics.averageQuantity()
            }
            if let quantity {
                values[DayKey.string(for: statistics.startDate)] = quantity.doubleValue(for: unit)
            }
        }
        return values
    }

    /// Sleep is attributed to the day you woke up; overlapping sources are counted once.
    private func dailySleepHours(_ start: Date, _ end: Date, _ calendar: Calendar) async throws -> [String: Double] {
        let predicate = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-86_400), end: end)
        let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                 sortDescriptors: [])
        let asleep = try await descriptor.result(for: healthStore).filter { Self.isAsleep($0.value) && $0.endDate >= start && $0.endDate < end }
        let byDay = Dictionary(grouping: asleep) { DayKey.string(for: $0.endDate, calendar: calendar) }
        return byDay.mapValues { samples in
            IntervalMath.mergedDuration(samples.map { DateInterval(start: $0.startDate, end: $0.endDate) }) / 3_600
        }
    }

    private func dailyWorkoutCounts(_ start: Date, _ end: Date, _ calendar: Calendar) async throws -> [String: Int] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [])
        let workouts = try await descriptor.result(for: healthStore)
        return Dictionary(grouping: workouts) { DayKey.string(for: $0.startDate, calendar: calendar) }.mapValues(\.count)
    }

    // MARK: Names

    static func isAsleep(_ value: Int) -> Bool {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: value) else { return false }
        return HKCategoryValueSleepAnalysis.allAsleepValues.contains(stage)
    }

    static func sleepStageName(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: "in_bed"
        case .asleepUnspecified: "asleep"
        case .awake: "awake"
        case .asleepCore: "core"
        case .asleepDeep: "deep"
        case .asleepREM: "rem"
        default: "unknown_\(value)"
        }
    }

    static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "running"
        case .walking: "walking"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .hiking: "hiking"
        case .yoga: "yoga"
        case .functionalStrengthTraining: "functional_strength"
        case .traditionalStrengthTraining: "strength"
        case .highIntensityIntervalTraining: "hiit"
        case .elliptical: "elliptical"
        case .rowing: "rowing"
        case .stairClimbing: "stair_climbing"
        case .pilates: "pilates"
        case .dance: "dance"
        case .coreTraining: "core_training"
        case .mixedCardio: "mixed_cardio"
        case .tennis: "tennis"
        case .soccer: "soccer"
        case .basketball: "basketball"
        case .golf: "golf"
        case .crossTraining: "cross_training"
        case .cooldown: "cooldown"
        case .flexibility: "flexibility"
        case .boxing: "boxing"
        case .martialArts: "martial_arts"
        default: "other_\(type.rawValue)"
        }
    }
}
