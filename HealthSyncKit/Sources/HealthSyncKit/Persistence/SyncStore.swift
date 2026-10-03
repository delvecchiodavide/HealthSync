import Foundation
import SwiftData

// MARK: - Entities

@Model final class UploadedSampleEntity {
    @Attribute(.unique) var uuid: String
    var metricID: String
    var spreadsheetID: String
    var row: Int
    var deleted: Bool

    init(uuid: String, metricID: String, spreadsheetID: String, row: Int) {
        self.uuid = uuid
        self.metricID = metricID
        self.spreadsheetID = spreadsheetID
        self.row = row
        self.deleted = false
    }
}

@Model final class SpreadsheetEntity {
    @Attribute(.unique) var spreadsheetID: String
    var metricID: String
    var part: Int
    var name: String
    var rowCount: Int
    var columnCount: Int

    init(spreadsheetID: String, metricID: String, part: Int, name: String, rowCount: Int, columnCount: Int) {
        self.spreadsheetID = spreadsheetID
        self.metricID = metricID
        self.part = part
        self.name = name
        self.rowCount = rowCount
        self.columnCount = columnCount
    }
}

@Model final class AnchorEntity {
    @Attribute(.unique) var metricID: String
    var data: Data

    init(metricID: String, data: Data) {
        self.metricID = metricID
        self.data = data
    }
}

@Model final class SummaryRowEntity {
    @Attribute(.unique) var day: String
    var spreadsheetID: String
    var row: Int

    init(day: String, spreadsheetID: String, row: Int) {
        self.day = day
        self.spreadsheetID = spreadsheetID
        self.row = row
    }
}

@Model final class SyncRunEntity {
    @Attribute(.unique) var id: UUID
    var trigger: String
    var startedAt: Date
    var finishedAt: Date
    var rowsUploaded: Int
    var rowsDeleted: Int
    var status: String
    var errors: [String]

    init(_ info: SyncRunInfo) {
        id = info.id
        trigger = info.trigger.rawValue
        startedAt = info.startedAt
        finishedAt = info.finishedAt
        rowsUploaded = info.rowsUploaded
        rowsDeleted = info.rowsDeleted
        status = info.status.rawValue
        errors = info.errors
    }

    var info: SyncRunInfo {
        SyncRunInfo(id: id, trigger: SyncTrigger(rawValue: trigger) ?? .manual, startedAt: startedAt,
                    finishedAt: finishedAt, rowsUploaded: rowsUploaded, rowsDeleted: rowsDeleted,
                    status: SyncRunStatus(rawValue: status) ?? .failed, errors: errors)
    }
}

@Model final class MetricStatusEntity {
    @Attribute(.unique) var metricID: String
    var totalRows: Int
    var lastSyncAt: Date?
    var lastError: String?

    init(metricID: String) {
        self.metricID = metricID
        self.totalRows = 0
    }
}

// MARK: - Value types crossing the actor boundary

public struct SpreadsheetInfo: Sendable, Hashable {
    public var id: String
    public var metricID: String
    public var part: Int
    public var name: String
    public var rowCount: Int
    public var columnCount: Int

    public init(id: String, metricID: String, part: Int, name: String, rowCount: Int, columnCount: Int) {
        self.id = id
        self.metricID = metricID
        self.part = part
        self.name = name
        self.rowCount = rowCount
        self.columnCount = columnCount
    }
}

public struct UploadedRow: Sendable, Hashable {
    public var uuid: String
    public var spreadsheetID: String
    public var row: Int
}

public struct RowLocation: Sendable, Hashable {
    public var key: String
    public var spreadsheetID: String
    public var row: Int
}

// MARK: - Store

/// Local sync state: anchors, the index of uploaded samples, spreadsheets and the run log.
@ModelActor
public actor SyncStore {
    public static let maxRuns = 100

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([UploadedSampleEntity.self, SpreadsheetEntity.self, AnchorEntity.self,
                             SummaryRowEntity.self, SyncRunEntity.self, MetricStatusEntity.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    // MARK: Anchors & index

    public func anchor(for metricID: String) -> Data? {
        try? modelContext.fetch(FetchDescriptor<AnchorEntity>(predicate: #Predicate { $0.metricID == metricID })).first?.data
    }

    public func existingUUIDs(in uuids: [String]) -> Set<String> {
        guard !uuids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<UploadedSampleEntity>(predicate: #Predicate { uuids.contains($0.uuid) })
        return Set(((try? modelContext.fetch(descriptor)) ?? []).map(\.uuid))
    }

    /// Where not-yet-deleted samples were written.
    public func locations(of uuids: [String]) -> [RowLocation] {
        guard !uuids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<UploadedSampleEntity>(predicate: #Predicate { uuids.contains($0.uuid) && !$0.deleted })
        return ((try? modelContext.fetch(descriptor)) ?? []).map { RowLocation(key: $0.uuid, spreadsheetID: $0.spreadsheetID, row: $0.row) }
    }

    public func uploadedCount(for metricID: String) -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<UploadedSampleEntity>(predicate: #Predicate { $0.metricID == metricID }))) ?? 0
    }

    /// Records one uploaded page and advances the anchor in a single save, so a crash
    /// mid-sync resumes from the last fully committed page.
    public func commitPage(metricID: String, anchor: Data?, uploaded: [UploadedRow], deletedUUIDs: [String], at date: Date) throws {
        for row in uploaded {
            modelContext.insert(UploadedSampleEntity(uuid: row.uuid, metricID: metricID, spreadsheetID: row.spreadsheetID, row: row.row))
        }
        for (spreadsheetID, rows) in Dictionary(grouping: uploaded, by: \.spreadsheetID) {
            spreadsheet(id: spreadsheetID)?.rowCount += rows.count
        }
        if !deletedUUIDs.isEmpty {
            let descriptor = FetchDescriptor<UploadedSampleEntity>(predicate: #Predicate { deletedUUIDs.contains($0.uuid) })
            for entity in try modelContext.fetch(descriptor) { entity.deleted = true }
        }
        if let anchor {
            if let existing = try modelContext.fetch(FetchDescriptor<AnchorEntity>(predicate: #Predicate { $0.metricID == metricID })).first {
                existing.data = anchor
            } else {
                modelContext.insert(AnchorEntity(metricID: metricID, data: anchor))
            }
        }
        let status = metricStatus(metricID)
        status.totalRows += uploaded.count
        status.lastSyncAt = date
        status.lastError = nil
        try modelContext.save()
    }

    // MARK: Spreadsheets

    public func currentSpreadsheet(for metricID: String) -> SpreadsheetInfo? {
        var descriptor = FetchDescriptor<SpreadsheetEntity>(predicate: #Predicate { $0.metricID == metricID },
                                                            sortBy: [SortDescriptor(\.part, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first.map {
            SpreadsheetInfo(id: $0.spreadsheetID, metricID: $0.metricID, part: $0.part, name: $0.name,
                            rowCount: $0.rowCount, columnCount: $0.columnCount)
        }
    }

    public func addSpreadsheet(_ info: SpreadsheetInfo) throws {
        modelContext.insert(SpreadsheetEntity(spreadsheetID: info.id, metricID: info.metricID, part: info.part,
                                              name: info.name, rowCount: info.rowCount, columnCount: info.columnCount))
        try modelContext.save()
    }

    private func spreadsheet(id: String) -> SpreadsheetEntity? {
        try? modelContext.fetch(FetchDescriptor<SpreadsheetEntity>(predicate: #Predicate { $0.spreadsheetID == id })).first
    }

    // MARK: Daily summary rows

    public func hasSummaryRows() -> Bool {
        ((try? modelContext.fetchCount(FetchDescriptor<SummaryRowEntity>())) ?? 0) > 0
    }

    public func summaryRows(for days: [String]) -> [String: RowLocation] {
        let descriptor = FetchDescriptor<SummaryRowEntity>(predicate: #Predicate { days.contains($0.day) })
        let entities = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(entities.map { ($0.day, RowLocation(key: $0.day, spreadsheetID: $0.spreadsheetID, row: $0.row)) },
                          uniquingKeysWith: { first, _ in first })
    }

    public func addSummaryRows(_ rows: [RowLocation]) throws {
        for row in rows {
            modelContext.insert(SummaryRowEntity(day: row.key, spreadsheetID: row.spreadsheetID, row: row.row))
        }
        for (spreadsheetID, group) in Dictionary(grouping: rows, by: \.spreadsheetID) {
            spreadsheet(id: spreadsheetID)?.rowCount += group.count
        }
        try modelContext.save()
    }

    // MARK: Status

    private func metricStatus(_ metricID: String) -> MetricStatusEntity {
        if let existing = try? modelContext.fetch(FetchDescriptor<MetricStatusEntity>(predicate: #Predicate { $0.metricID == metricID })).first {
            return existing
        }
        let entity = MetricStatusEntity(metricID: metricID)
        modelContext.insert(entity)
        return entity
    }

    public func recordMetricError(_ metricID: String, message: String) {
        metricStatus(metricID).lastError = message
        try? modelContext.save()
    }

    public func metricStatuses() -> [String: MetricStatus] {
        let entities = (try? modelContext.fetch(FetchDescriptor<MetricStatusEntity>())) ?? []
        return Dictionary(entities.map {
            ($0.metricID, MetricStatus(metricID: $0.metricID, totalRows: $0.totalRows, lastSyncAt: $0.lastSyncAt, lastError: $0.lastError))
        }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Run log

    public func appendRun(_ info: SyncRunInfo) {
        modelContext.insert(SyncRunEntity(info))
        // Save first: fetchOffset doesn't apply to unsaved inserts, which would delete the new run.
        try? modelContext.save()
        var stale = FetchDescriptor<SyncRunEntity>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        stale.fetchOffset = Self.maxRuns
        for entity in (try? modelContext.fetch(stale)) ?? [] { modelContext.delete(entity) }
        try? modelContext.save()
    }

    public func recentRuns(limit: Int = maxRuns) -> [SyncRunInfo] {
        var descriptor = FetchDescriptor<SyncRunEntity>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.info)
    }

    public func lastSuccessfulSync() -> Date? {
        let success = SyncRunStatus.success.rawValue
        var descriptor = FetchDescriptor<SyncRunEntity>(predicate: #Predicate { $0.status == success },
                                                        sortBy: [SortDescriptor(\.finishedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.finishedAt
    }

    /// Failed runs since the last non-failed one (locked/expired runs don't count either way).
    public func consecutiveFailures() -> Int {
        var count = 0
        for run in recentRuns(limit: 20) {
            if run.status.isFailure { count += 1 } else if run.status == .success || run.status == .partial { break }
        }
        return count
    }

    // MARK: Reset

    /// Forgets everything about one metric so the next sync re-uploads it into a new spreadsheet.
    public func resetMetric(_ metricID: String) throws {
        try modelContext.delete(model: UploadedSampleEntity.self, where: #Predicate { $0.metricID == metricID })
        try modelContext.delete(model: SpreadsheetEntity.self, where: #Predicate { $0.metricID == metricID })
        try modelContext.delete(model: AnchorEntity.self, where: #Predicate { $0.metricID == metricID })
        try modelContext.delete(model: MetricStatusEntity.self, where: #Predicate { $0.metricID == metricID })
        if metricID == DailySummary.metricID {
            try modelContext.delete(model: SummaryRowEntity.self)
        }
        try modelContext.save()
    }

    /// Clears all sync state. The run log is kept.
    public func resetAll() throws {
        try modelContext.delete(model: UploadedSampleEntity.self)
        try modelContext.delete(model: SpreadsheetEntity.self)
        try modelContext.delete(model: AnchorEntity.self)
        try modelContext.delete(model: SummaryRowEntity.self)
        try modelContext.delete(model: MetricStatusEntity.self)
        try modelContext.save()
    }
}
