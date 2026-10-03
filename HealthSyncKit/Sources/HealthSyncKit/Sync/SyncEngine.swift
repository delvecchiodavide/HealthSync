import Foundation

/// Uploads new and deleted Health samples to Google Sheets. Only one sync runs at a time;
/// concurrent callers join the run in progress.
public actor SyncEngine {
    /// Samples per HealthKit page; one page becomes one append request and one checkpoint.
    public static let pageSize = SheetsService.maxRowsPerRequest
    /// Roll over to a new spreadsheet well below Google's 10M-cell limit.
    public static let maxCellsPerSpreadsheet = 5_000_000
    /// Days of the Daily Summary recomputed on every sync (late-arriving data, e.g. sleep).
    public static let summaryRefreshDays = 3
    public static let summaryBackfillDays = 365

    private let health: any HealthDataSource
    private let drive: DriveService
    private let sheets: SheetsService
    private let store: SyncStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var running: Task<SyncRunInfo, Never>?

    public init(health: any HealthDataSource, drive: DriveService, sheets: SheetsService, store: SyncStore,
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.health = health
        self.drive = drive
        self.sheets = sheets
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    public var isRunning: Bool { running != nil }

    /// Runs a sync, or waits for the one already in progress. Cancelling the calling task
    /// (e.g. a background task expiring) stops the run after the current page.
    public func sync(settings: SyncSettings, trigger: SyncTrigger) async -> SyncRunInfo {
        if let running {
            return await running.value
        }
        let task = Task { await self.perform(settings: settings, trigger: trigger) }
        running = task
        let info = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        running = nil
        return info
    }

    // MARK: - Run

    private func perform(settings: SyncSettings, trigger: SyncTrigger) async -> SyncRunInfo {
        let startedAt = now()
        var uploaded = 0
        var deleted = 0
        var errors: [String] = []
        var failedSteps = 0
        var status = SyncRunStatus.success
        let metrics = settings.enabledMetrics
        Log.sync.info("Sync started (\(trigger.rawValue, privacy: .public)), \(metrics.count) types")

        do {
            guard let folderID = settings.folderID else { throw SyncError.noDriveFolder }
            let since = settings.historyRange.startDate(now: startedAt, calendar: calendar)

            for metric in metrics {
                try Task.checkCancellation()
                do {
                    let result = try await syncMetric(metric, folderID: folderID, since: since)
                    uploaded += result.uploaded
                    deleted += result.deleted
                } catch let error where Self.abortsRun(error) {
                    throw error
                } catch {
                    failedSteps += 1
                    errors.append("\(metric.displayName): \(try await handleStepError(error, metricID: metric.id))")
                }
            }

            if !metrics.isEmpty {
                try Task.checkCancellation()
                do {
                    try await syncDailySummary(folderID: folderID, historyStart: since)
                } catch let error where Self.abortsRun(error) {
                    throw error
                } catch {
                    failedSteps += 1
                    errors.append("Daily Summary: \(try await handleStepError(error, metricID: DailySummary.metricID))")
                }
            }

            if failedSteps > 0 {
                status = failedSteps >= metrics.count + 1 ? .failed : .partial
            }
        } catch is CancellationError {
            status = .expired
        } catch SyncError.healthDataLocked {
            status = .skippedLocked
        } catch {
            status = .failed
            errors.append(error.localizedDescription)
        }

        let info = SyncRunInfo(trigger: trigger, startedAt: startedAt, finishedAt: now(), rowsUploaded: uploaded,
                               rowsDeleted: deleted, status: status, errors: errors)
        await store.appendRun(info)
        Log.sync.info("Sync finished: \(status.rawValue, privacy: .public), \(uploaded) rows uploaded, \(deleted) deleted")
        return info
    }

    /// Errors that make continuing with other metrics pointless.
    private static func abortsRun(_ error: Error) -> Bool {
        error is CancellationError
            || error as? SyncError == .healthDataLocked
            || error as? GoogleAPIError == .unauthorized
    }

    /// Records a per-metric failure and returns its message. A missing spreadsheet (deleted by
    /// the user) resets that metric so the next sync re-creates and re-fills it.
    private func handleStepError(_ error: Error, metricID: String) async throws -> String {
        if let apiError = error as? GoogleAPIError, apiError.isNotFound {
            try await store.resetMetric(metricID)
            return "Spreadsheet not found; it will be re-created on the next sync."
        }
        let message = error.localizedDescription
        await store.recordMetricError(metricID, message: message)
        return message
    }

    // MARK: - Samples

    private func syncMetric(_ metric: HealthMetric, folderID: String, since: Date?) async throws -> (uploaded: Int, deleted: Int) {
        var anchor = await store.anchor(for: metric.id)
        var uploaded = 0
        var deleted = 0

        while true {
            try Task.checkCancellation()
            let changes = try await health.changes(for: metric, anchor: anchor, since: since, limit: Self.pageSize)

            // Deduplicate against the local index and within the page.
            let existing = await store.existingUUIDs(in: changes.added.map(\.uuid))
            var seen = existing
            let newSamples = changes.added.filter { seen.insert($0.uuid).inserted }

            var uploadedRows: [UploadedRow] = []
            if !newSamples.isEmpty {
                let sheet = try await spreadsheet(metricID: metric.id, name: metric.sheetName, columns: metric.columns,
                                                  folderID: folderID, addingRows: newSamples.count)
                let syncedAt = now()
                let rowNumbers = try await sheets.append(spreadsheetID: sheet.id,
                                                         rows: newSamples.map { RowMapper.row(for: $0, syncedAt: syncedAt) })
                uploadedRows = zip(newSamples, rowNumbers).map { UploadedRow(uuid: $0.uuid, spreadsheetID: sheet.id, row: $1) }
            }

            let locations = await store.locations(of: changes.deletedUUIDs)
            for (spreadsheetID, rows) in Dictionary(grouping: locations, by: \.spreadsheetID) {
                try await sheets.markDeleted(spreadsheetID: spreadsheetID, rows: rows.map(\.row),
                                             deletedColumnIndex: metric.deletedColumnIndex)
            }

            try await store.commitPage(metricID: metric.id, anchor: changes.newAnchor, uploaded: uploadedRows,
                                       deletedUUIDs: locations.map(\.key), at: now())
            uploaded += uploadedRows.count
            deleted += locations.count
            anchor = changes.newAnchor

            if !changes.hasMore { break }
        }
        return (uploaded, deleted)
    }

    /// The spreadsheet to append to, creating the first one or the next part when the current one is full.
    private func spreadsheet(metricID: String, name: String, columns: [String], folderID: String,
                             addingRows count: Int) async throws -> SpreadsheetInfo {
        let current = await store.currentSpreadsheet(for: metricID)
        if let current, (current.rowCount + count) * current.columnCount <= Self.maxCellsPerSpreadsheet {
            return current
        }
        let part = (current?.part ?? 0) + 1
        let fileName = part == 1 ? name : "\(name) (\(part))"
        let file = try await drive.createSpreadsheet(named: fileName, inFolder: folderID)
        try await sheets.prepare(spreadsheetID: file.id, headers: columns)
        // Header row plus the one spare grid row left by `prepare`.
        let info = SpreadsheetInfo(id: file.id, metricID: metricID, part: part, name: fileName, rowCount: 2, columnCount: columns.count)
        try await store.addSpreadsheet(info)
        Log.sync.info("Created spreadsheet part \(part) for \(metricID, privacy: .public)")
        return info
    }

    // MARK: - Daily summary

    private func syncDailySummary(folderID: String, historyStart: Date?) async throws {
        let today = calendar.startOfDay(for: now())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return }

        let start: Date
        if await store.hasSummaryRows() {
            start = calendar.date(byAdding: .day, value: -(Self.summaryRefreshDays - 1), to: today) ?? today
        } else {
            let earliest = calendar.date(byAdding: .day, value: -(Self.summaryBackfillDays - 1), to: today) ?? today
            start = max(historyStart.map { calendar.startOfDay(for: $0) } ?? earliest, earliest)
        }

        let summaries = try await health.dailySummaries(from: start, to: tomorrow)
        guard !summaries.isEmpty else { return }
        let existing = await store.summaryRows(for: summaries.map(\.day))
        let updatedAt = now()

        let updates = summaries.compactMap { summary in existing[summary.day].map { ($0, summary.row(updatedAt: updatedAt)) } }
        for (spreadsheetID, rows) in Dictionary(grouping: updates, by: { $0.0.spreadsheetID }) {
            try await sheets.updateRows(spreadsheetID: spreadsheetID, rows: rows.map { (row: $0.0.row, values: $0.1) })
        }

        let newSummaries = summaries.filter { existing[$0.day] == nil }
        for batch in newSummaries.chunked(into: SheetsService.maxRowsPerRequest) {
            try Task.checkCancellation()
            let sheet = try await spreadsheet(metricID: DailySummary.metricID, name: DailySummary.sheetName,
                                              columns: DailySummary.columns, folderID: folderID, addingRows: batch.count)
            let rowNumbers = try await sheets.append(spreadsheetID: sheet.id, rows: batch.map { $0.row(updatedAt: updatedAt) })
            try await store.addSummaryRows(zip(batch, rowNumbers).map {
                RowLocation(key: $0.day, spreadsheetID: sheet.id, row: $1)
            })
        }
    }
}
