import BackgroundTasks
import Foundation
import HealthSyncKit
import UserNotifications

/// BGTaskScheduler wiring. iOS decides when tasks actually run; `earliestBeginDate` is only a lower bound.
enum BackgroundScheduler {
    static let refreshID = "com.healthsync.app.refresh"
    static let processingID = "com.healthsync.app.processing"

    /// Must be called before `application(_:didFinishLaunchingWithOptions:)` returns.
    @MainActor
    static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task, trigger: .backgroundRefresh, model: model)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            handle(task, trigger: .backgroundProcessing, model: model)
        }
    }

    private static func handle(_ task: BGTask, trigger: SyncTrigger, model: AppModel) {
        let bgTask = UncheckedSendable(task)
        let work = Task { @MainActor in
            // Processing tasks exist to finish large backfills, so they run regardless of the interval.
            let run: SyncRunInfo?
            if trigger == .backgroundProcessing {
                run = await model.sync(trigger: trigger)
            } else {
                run = await model.syncIfDue(trigger: trigger)
            }
            if run == nil {
                scheduleRefresh(after: model.nextSyncDate)
            }
            return run.map { $0.status != .failed } ?? true
        }
        task.expirationHandler = {
            Log.sync.info("Background task expired; cancelling sync")
            work.cancel()
        }
        Task {
            let success = await work.value
            bgTask.value.setTaskCompleted(success: success)
        }
    }

    static func scheduleRefresh(after date: Date) {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = date
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.sync.error("Couldn't schedule refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Longer-running task (usually while charging) used to finish big uploads.
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.sync.error("Couldn't schedule processing: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Local notification after repeated failures.
enum FailureNotifier {
    static let threshold = 3

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Notifies exactly once per failure streak, when it reaches the threshold.
    static func notifyIfNeeded(consecutiveFailures: Int, message: String?) async {
        guard consecutiveFailures == threshold else { return }
        let content = UNMutableNotificationContent()
        content.title = "HealthSync can't sync"
        content.body = message ?? "The last \(threshold) syncs failed. Open HealthSync to check."
        let request = UNNotificationRequest(identifier: "sync-failures", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
