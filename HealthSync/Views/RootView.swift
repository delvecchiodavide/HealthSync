import HealthSyncKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.settings.onboardingComplete {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.appBecameActive() }
            case .background: model.appEnteredBackground()
            default: break
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            NavigationStack { DataView() }
                .tabItem { Label("Data", systemImage: "heart.text.square") }
            NavigationStack { SyncLogView() }
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Shown wherever scheduling is configured, so expectations match what iOS actually does.
struct SchedulingNote: View {
    var body: some View {
        Text("iOS decides exactly when background syncs run, based on battery, usage and network. **Health data can't be read while your iPhone is locked, due to an Apple limitation**, so a sync may wait until you next unlock it. Opening the app always syncs if one is due.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

extension SyncRunStatus {
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .partial: "exclamationmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skippedLocked: "lock.fill"
        case .expired: "clock.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .success: .green
        case .partial, .expired: .orange
        case .failed: .red
        case .skippedLocked: .secondary
        }
    }
}
