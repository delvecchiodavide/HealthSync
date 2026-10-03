import HealthSyncKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false
    @State private var confirmingDisconnect = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Google account") {
                if let email = model.auth.email {
                    LabeledContent("Signed in as", value: email)
                    Button("Sign Out") { model.auth.signOut() }
                    Button("Disconnect and Revoke Access", role: .destructive) { confirmingDisconnect = true }
                } else {
                    Button("Sign in with Google") {
                        Task { await perform { try await model.auth.signIn() } }
                    }
                }
            }

            Section("Google Drive") {
                NavigationLink {
                    FolderPickerView()
                } label: {
                    LabeledContent("Folder", value: model.settings.folderName ?? "Not selected")
                }
            }

            Section {
                NavigationLink {
                    DataTypesView()
                } label: {
                    LabeledContent("Data types", value: "\(model.settings.enabledMetricIDs.count) selected")
                }
                NavigationLink {
                    FrequencyView()
                } label: {
                    LabeledContent("Frequency", value: model.settings.interval.displayText)
                }
                Picker("History range", selection: model.binding(\.historyRange)) {
                    ForEach(HistoryRange.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Notify after repeated failures", isOn: model.binding(\.notifyOnFailures))
            } header: {
                Text("Sync")
            } footer: {
                Text("History range applies to data types that haven't been synced yet, or after a reset.")
            }

            Section {
                Button("Reset Sync State", role: .destructive) { confirmingReset = true }
            } footer: {
                Text("Forgets what has been uploaded. The next sync creates new spreadsheets and uploads everything in the history range again. Existing spreadsheets are not deleted.")
            }

            Section("About background sync") {
                SchedulingNote()
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset sync state?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                Task { await perform { try await model.resetSyncState() } }
            }
        }
        .confirmationDialog("Disconnect Google account?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task { await perform { try await model.auth.disconnect() } }
            }
        } message: {
            Text("HealthSync will lose access to your Drive until you sign in again. Your spreadsheets stay in Drive.")
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
