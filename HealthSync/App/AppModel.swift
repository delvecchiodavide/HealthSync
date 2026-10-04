import Foundation
import HealthSyncKit
import SwiftData
import SwiftUI
import UIKit

/// App-wide state and the entry point for every sync, foreground or background.
@MainActor
@Observable
final class AppModel {
    private(set) var settings: SyncSettings
    let auth = GoogleAuthService()
    let health = HealthKitService()
    let drive: DriveService
    private let store: SyncStore
    private let engine: SyncEngine

    private(set) var isSyncing = false
    private(set) var runs: [SyncRunInfo] = []
    private(set) var metricStatuses: [String: MetricStatus] = [:]
    private(set) var lastSuccess: Date?

    init() {
        settings = SettingsStore.load()
        let container: ModelContainer
        do {
            container = try SyncStore.makeContainer()
        } catch {
            fatalError("Couldn't open the local database: \(error)")
        }
        store = SyncStore(modelContainer: container)
        let client = GoogleAPIClient(tokens: GoogleTokenProvider())
        drive = DriveService(client: client)
        engine = SyncEngine(health: health, drive: drive, sheets: SheetsService(client: client), store: store)
    }

    var nextSyncDate: Date {
        settings.interval.nextDate(after: lastSuccess, now: .now)
    }

    // MARK: Settings

    func update(_ change: (inout SyncSettings) -> Void) {
        let old = settings
        change(&settings)
        guard settings != old else { return }
        SettingsStore.save(settings)
        if settings.interval != old.interval || settings.enabledMetricIDs != old.enabledMetricIDs {
            configureBackgroundWork()
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<SyncSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func isEnabled(_ metric: HealthMetric) -> Binding<Bool> {
        Binding(get: { self.settings.enabledMetricIDs.contains(metric.id) },
                set: { on in self.update { if on { $0.enabledMetricIDs.insert(metric.id) } else { $0.enabledMetricIDs.remove(metric.id) } } })
    }

    /// On when every type in the category is enabled; setting it enables or disables them all.
    func isEnabled(_ category: MetricCategory) -> Binding<Bool> {
        let ids = Set(category.metrics.map(\.id))
        return Binding(get: { ids.isSubset(of: self.settings.enabledMetricIDs) },
                       set: { on in self.update { if on { $0.enabledMetricIDs.formUnion(ids) } else { $0.enabledMetricIDs.subtract(ids) } } })
    }

    func setAllMetrics(enabled: Bool) {
        update { $0.enabledMetricIDs = enabled ? Set(HealthMetric.all.map(\.id)) : [] }
    }

    func enabledCount(in category: MetricCategory) -> Int {
        category.metrics.filter { settings.enabledMetricIDs.contains($0.id) }.count
    }

    // MARK: Lifecycle

    /// Called from `didFinishLaunching`, including background launches.
    func launch() {
        BackgroundScheduler.register(model: self)
        configureBackgroundWork()
        Task {
            await auth.restore()
            await refresh()
        }
    }

    func appBecameActive() async {
        await refresh()
        if !auth.isSignedIn { await auth.restore() }
        await syncIfDue(trigger: .appLaunch)
    }

    func appEnteredBackground() {
        guard settings.onboardingComplete else { return }
        BackgroundScheduler.scheduleRefresh(after: nextSyncDate)
    }

    func configureBackgroundWork() {
        guard settings.onboardingComplete else { return }
        health.startObserving(settings.enabledMetrics, frequency: settings.interval.backgroundFrequency) { [weak self] in
            _ = await self?.syncIfDue(trigger: .healthKitUpdate)
        }
        BackgroundScheduler.scheduleRefresh(after: nextSyncDate)
    }

    func completeOnboarding() {
        update { $0.onboardingComplete = true }
        configureBackgroundWork()
        // Lets iOS finish a large first upload later if the app is closed mid-sync.
        BackgroundScheduler.scheduleProcessing()
        Task { await sync(trigger: .firstSync) }
    }

    // MARK: Sync

    func refresh() async {
        runs = await store.recentRuns()
        metricStatuses = await store.metricStatuses()
        lastSuccess = await store.lastSuccessfulSync()
    }

    @discardableResult
    func syncIfDue(trigger: SyncTrigger) async -> SyncRunInfo? {
        guard settings.onboardingComplete else { return nil }
        let last = await store.lastSuccessfulSync()
        guard settings.interval.isDue(lastSuccess: last, now: .now) else { return nil }
        return await sync(trigger: trigger)
    }

    @discardableResult
    func sync(trigger: SyncTrigger) async -> SyncRunInfo {
        isSyncing = true
        defer { isSyncing = false }
        if !auth.isSignedIn { await auth.restore() }

        let settings = settings
        let engine = engine
        let work = Task { await engine.sync(settings: settings, trigger: trigger) }
        // Ask for extra time so a sync started in the foreground can finish if the app is closed.
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HealthSync sync") {
            work.cancel()
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        let run = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }

        await refresh()
        BackgroundScheduler.scheduleRefresh(after: nextSyncDate)
        if run.status == .expired {
            BackgroundScheduler.scheduleProcessing()
        }
        if run.status.isFailure && self.settings.notifyOnFailures {
            await FailureNotifier.notifyIfNeeded(consecutiveFailures: await store.consecutiveFailures(), message: run.errors.first)
        }
        return run
    }

    // MARK: Actions

    /// Asks only for the enabled types; iOS shows its permission sheet just for ones not asked before.
    func requestHealthAuthorization() async throws {
        try await health.requestAuthorization(for: settings.enabledMetrics)
    }

    func listFolders() async throws -> [DriveFile] {
        try await drive.listFolders()
    }

    func createFolder(named name: String) async throws -> DriveFile {
        try await drive.createFolder(named: name)
    }

    /// Selecting a different folder resets sync state so all data is re-uploaded there.
    func selectFolder(_ folder: DriveFile) async throws {
        if let current = settings.folderID, current != folder.id {
            try await store.resetAll()
        }
        update {
            $0.folderID = folder.id
            $0.folderName = folder.name
        }
        await refresh()
    }

    func resetSyncState() async throws {
        try await store.resetAll()
        await refresh()
    }
}

enum SettingsStore {
    private static let key = "syncSettings"

    static func load() -> SyncSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(SyncSettings.self, from: data) else {
            return SyncSettings()
        }
        return settings
    }

    static func save(_ settings: SyncSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
