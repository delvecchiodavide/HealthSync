import Foundation

public enum SyncTrigger: String, Codable, Sendable {
    case manual, appLaunch, backgroundRefresh, backgroundProcessing, healthKitUpdate, firstSync

    public var displayName: String {
        switch self {
        case .manual: "Manual"
        case .appLaunch: "App opened"
        case .backgroundRefresh: "Background refresh"
        case .backgroundProcessing: "Background processing"
        case .healthKitUpdate: "New Health data"
        case .firstSync: "First sync"
        }
    }
}

public enum SyncRunStatus: String, Codable, Sendable {
    case success, partial, failed, skippedLocked, expired

    public var displayName: String {
        switch self {
        case .success: "Succeeded"
        case .partial: "Partially succeeded"
        case .failed: "Failed"
        case .skippedLocked: "Skipped (iPhone locked)"
        case .expired: "Stopped by iOS (will resume)"
        }
    }

    /// Whether this counts as a failure for the consecutive-failure notification.
    public var isFailure: Bool { self == .failed }
}

public struct SyncRunInfo: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var trigger: SyncTrigger
    public var startedAt: Date
    public var finishedAt: Date
    public var rowsUploaded: Int
    public var rowsDeleted: Int
    public var status: SyncRunStatus
    public var errors: [String]

    public init(id: UUID = UUID(), trigger: SyncTrigger, startedAt: Date, finishedAt: Date, rowsUploaded: Int,
                rowsDeleted: Int, status: SyncRunStatus, errors: [String]) {
        self.id = id
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rowsUploaded = rowsUploaded
        self.rowsDeleted = rowsDeleted
        self.status = status
        self.errors = errors
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

public struct MetricStatus: Sendable, Hashable {
    public var metricID: String
    public var totalRows: Int
    public var lastSyncAt: Date?
    public var lastError: String?
}

public enum SyncError: Error, LocalizedError, Sendable, Equatable {
    case healthDataLocked
    case noDriveFolder
    case healthKitUnavailable

    public var errorDescription: String? {
        switch self {
        case .healthDataLocked: "Health data is unavailable while the iPhone is locked."
        case .noDriveFolder: "No Google Drive folder selected."
        case .healthKitUnavailable: "Apple Health is not available on this device."
        }
    }
}
