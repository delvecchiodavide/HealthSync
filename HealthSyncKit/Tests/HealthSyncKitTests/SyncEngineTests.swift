import Foundation
import Testing
@testable import HealthSyncKit

@Suite struct SyncEngineTests {
    let google = FakeGoogle()
    let health = FakeHealth()
    let store: SyncStore
    let engine: SyncEngine
    var settings = SyncSettings()

    init() throws {
        store = SyncStore(modelContainer: try SyncStore.makeContainer(inMemory: true))
        let client = GoogleAPIClient(transport: google, tokens: StaticToken(), sleep: { _ in }, jitter: { 0 })
        engine = SyncEngine(health: health, drive: DriveService(client: client), sheets: SheetsService(client: client), store: store)
        settings.enabledMetricIDs = ["steps"]
        settings.folderID = "folder-1"
    }

    @Test func firstSyncCreatesSpreadsheetWithHeaderAndRows() async throws {
        health.add("steps", [sample("a"), sample("b")])
        let run = await engine.sync(settings: settings, trigger: .manual)

        #expect(run.status == .success)
        #expect(run.rowsUploaded == 2)
        let sheet = try #require(google.sheet(named: "HealthSync - Steps"))
        #expect(sheet.parents == ["folder-1"])
        #expect(sheet.rows.count == 3)
        #expect(sheet.rows[0] as? [String] == HealthMetric.metric(id: "steps")!.columns)
        #expect(sheet.rows[1][0] as? String == "a")
        #expect(google.sheet(named: DailySummary.sheetName) == nil)  // no summary data yet
        #expect(await store.lastSuccessfulSync() != nil)
    }

    @Test func secondSyncUploadsOnlyNewSamples() async throws {
        health.add("steps", [sample("a")])
        _ = await engine.sync(settings: settings, trigger: .manual)
        health.add("steps", [sample("b"), sample("a")])  // "a" re-delivered must not duplicate
        let run = await engine.sync(settings: settings, trigger: .manual)

        #expect(run.rowsUploaded == 1)
        #expect(google.sheet(named: "HealthSync - Steps")?.rows.count == 3)
        #expect(await store.uploadedCount(for: "steps") == 2)
    }

    @Test func pagesAreCheckpointedAndAllUploaded() async throws {
        health.add("steps", (0..<2_500).map { sample("s\($0)") })
        let run = await engine.sync(settings: settings, trigger: .manual)

        #expect(run.rowsUploaded == 2_500)
        #expect(google.sheet(named: "HealthSync - Steps")?.rows.count == 2_501)
        #expect(await store.anchor(for: "steps") == Data("2500".utf8))
    }

    @Test func deletionsMarkRowInsteadOfRemoving() async throws {
        health.add("steps", [sample("a"), sample("b")])
        _ = await engine.sync(settings: settings, trigger: .manual)
        health.delete("steps", "b")
        let run = await engine.sync(settings: settings, trigger: .manual)

        #expect(run.rowsDeleted == 1)
        let rows = try #require(google.sheet(named: "HealthSync - Steps")?.rows)
        let deletedColumn = HealthMetric.metric(id: "steps")!.deletedColumnIndex
        #expect(rows[1][deletedColumn] as? Bool == false)
        #expect(rows[2][deletedColumn] as? Bool == true)
    }

    @Test func lockedDeviceSkipsWithoutFailing() async {
        health.lockedError = true
        let run = await engine.sync(settings: settings, trigger: .backgroundRefresh)
        #expect(run.status == .skippedLocked)
        #expect(await store.consecutiveFailures() == 0)
    }

    @Test func missingFolderFails() async {
        var noFolder = settings
        noFolder.folderID = nil
        let run = await engine.sync(settings: noFolder, trigger: .manual)
        #expect(run.status == .failed)
        #expect(await store.consecutiveFailures() == 1)
    }

    @Test func deletedSpreadsheetIsRecreatedOnNextSync() async throws {
        health.add("steps", [sample("a")])
        _ = await engine.sync(settings: settings, trigger: .manual)
        google.markSpreadsheetDeleted(try #require(google.spreadsheetID(named: "HealthSync - Steps")))
        health.add("steps", [sample("b")])

        let failed = await engine.sync(settings: settings, trigger: .manual)
        #expect(failed.status != .success)
        let recovered = await engine.sync(settings: settings, trigger: .manual)
        #expect(recovered.status == .success)
        #expect(recovered.rowsUploaded == 2)  // everything re-uploaded into the new spreadsheet
    }

    @Test func dailySummaryAppendsThenUpdatesInPlace() async throws {
        health.summaries = [DailySummary(day: "2026-10-02", steps: 1_000), DailySummary(day: "2026-10-03", steps: 500)]
        _ = await engine.sync(settings: settings, trigger: .manual)
        health.summaries = [DailySummary(day: "2026-10-03", steps: 9_000), DailySummary(day: "2026-10-04", steps: 10)]
        _ = await engine.sync(settings: settings, trigger: .manual)

        let rows = try #require(google.sheet(named: DailySummary.sheetName)?.rows)
        #expect(rows.count == 4)
        #expect(rows.map { $0[0] as? String } == ["date", "2026-10-02", "2026-10-03", "2026-10-04"])
        #expect(rows[2][1] as? Double == 9_000)
    }

    @Test func concurrentSyncsShareOneRun() async {
        health.add("steps", [sample("a")])
        async let first = engine.sync(settings: settings, trigger: .manual)
        async let second = engine.sync(settings: settings, trigger: .healthKitUpdate)
        let (a, b) = await (first, second)
        #expect(a.rowsUploaded + b.rowsUploaded >= 1)
        #expect(google.sheet(named: "HealthSync - Steps")?.rows.count == 2)
    }

    @Test func runLogIsCapped() async {
        for _ in 0..<(SyncStore.maxRuns + 5) {
            await store.appendRun(SyncRunInfo(trigger: .manual, startedAt: Date(), finishedAt: Date(), rowsUploaded: 0,
                                              rowsDeleted: 0, status: .success, errors: []))
        }
        #expect(await store.recentRuns().count == SyncStore.maxRuns)
    }
}
