import HealthSyncKit
import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, health, google, folder, dataTypes, frequency, firstSync
    }

    @Environment(AppModel.self) private var model
    @State private var step = Step.welcome
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar {
                    if step != .welcome {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back") { move(-1) }
                        }
                    }
                }
                .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(error ?? "")
                }
        }
    }

    private var title: String {
        switch step {
        case .welcome: "HealthSync"
        case .health: "Apple Health"
        case .google: "Google Account"
        case .folder: "Drive Folder"
        case .dataTypes: "Data to Sync"
        case .frequency: "Sync Frequency"
        case .firstSync: "First Sync"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            StepPage(symbol: "heart.text.square.fill",
                     text: "HealthSync copies your Apple Health data from this iPhone into Google Sheets in your own Google Drive. Nothing goes anywhere else: there is no HealthSync server.",
                     buttonTitle: "Get Started") { move(1) }

        case .health:
            StepPage(symbol: "heart.fill",
                     text: "Allow HealthSync to read the Health data you want to sync. You can choose individual types on the next screen and change them later in the Health app.",
                     buttonTitle: "Allow Health Access", working: working) {
                await run {
                    try await model.requestHealthAuthorization()
                    move(1)
                }
            }

        case .google:
            if let email = model.auth.email {
                StepPage(symbol: "person.crop.circle.badge.checkmark", text: "Signed in as \(email).", buttonTitle: "Continue") { move(1) }
            } else {
                StepPage(symbol: "person.crop.circle",
                         text: "Sign in with Google. HealthSync asks only for access to the files it creates in your Drive and to Google Sheets. Your password is never shared with the app.",
                         buttonTitle: "Sign in with Google", working: working) {
                    await run {
                        try await model.auth.signIn()
                        move(1)
                    }
                }
            }

        case .folder:
            FolderPickerView { move(1) }

        case .dataTypes:
            DataTypesView()
                .safeAreaInset(edge: .bottom) {
                    ContinueButton(title: "Continue", disabled: model.settings.enabledMetricIDs.isEmpty) { move(1) }
                }

        case .frequency:
            FrequencyView()
                .safeAreaInset(edge: .bottom) {
                    ContinueButton(title: "Continue") { move(1) }
                }

        case .firstSync:
            Form {
                Section {
                    Picker("History to upload", selection: model.binding(\.historyRange)) {
                        ForEach(HistoryRange.allCases) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text("Large histories upload in batches and may continue in the background over several syncs.")
                }
                Section {
                    Toggle("Notify me if syncing keeps failing", isOn: model.binding(\.notifyOnFailures))
                }
            }
            .safeAreaInset(edge: .bottom) {
                ContinueButton(title: "Start First Sync") {
                    if model.settings.notifyOnFailures {
                        await FailureNotifier.requestAuthorization()
                    }
                    model.completeOnboarding()
                }
            }
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation { step = next }
    }

    private func run(_ action: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await action()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StepPage: View {
    let symbol: String
    let text: String
    let buttonTitle: String
    var working = false
    let action: () async -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 72))
                .foregroundStyle(.pink)
                .accessibilityHidden(true)
            Text(text)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            ContinueButton(title: buttonTitle, working: working, action: action)
        }
    }
}

struct ContinueButton: View {
    let title: String
    var working = false
    var disabled = false
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Group {
                if working {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(working || disabled)
        .padding()
        .background(.bar)
    }
}
