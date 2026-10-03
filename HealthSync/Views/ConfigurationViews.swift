import HealthSyncKit
import SwiftUI

struct FolderPickerView: View {
    @Environment(AppModel.self) private var model
    var onPicked: () -> Void = {}

    @State private var folders: [DriveFile] = []
    @State private var newFolderName = "HealthSync"
    @State private var loading = false
    @State private var error: String?
    @State private var pendingFolder: DriveFile?

    var body: some View {
        List {
            Section {
                TextField("Folder name", text: $newFolderName)
                Button("Create New Folder") {
                    Task { await createFolder() }
                }
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            } header: {
                Text("New folder")
            }

            Section {
                if loading && folders.isEmpty {
                    ProgressView()
                } else if folders.isEmpty {
                    Text("No HealthSync folders yet.").foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    Button {
                        choose(folder)
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            if folder.id == model.settings.folderID {
                                Image(systemName: "checkmark").accessibilityLabel("Selected")
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Existing folders")
            } footer: {
                Text("For your privacy, HealthSync can only see folders and files it created itself. Folders you made in Google Drive won't appear here.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Drive Folder")
        .task { await loadFolders() }
        .refreshable { await loadFolders() }
        .confirmationDialog("Change folder?", isPresented: Binding(get: { pendingFolder != nil }, set: { if !$0 { pendingFolder = nil } }),
                            titleVisibility: .visible) {
            Button("Change and Re-upload Everything", role: .destructive) {
                if let folder = pendingFolder { Task { await select(folder) } }
            }
        } message: {
            Text("All your selected Health data will be uploaded again into new spreadsheets in the new folder. The old spreadsheets are left untouched.")
        }
    }

    private func choose(_ folder: DriveFile) {
        if let current = model.settings.folderID, current != folder.id {
            pendingFolder = folder
        } else {
            Task { await select(folder) }
        }
    }

    private func loadFolders() async {
        loading = true
        defer { loading = false }
        do {
            folders = try await model.listFolders()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createFolder() async {
        loading = true
        defer { loading = false }
        do {
            let folder = try await model.createFolder(named: newFolderName.trimmingCharacters(in: .whitespaces))
            folders.append(folder)
            choose(folder)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func select(_ folder: DriveFile) async {
        do {
            try await model.selectFolder(folder)
            onPicked()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DataTypesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(HealthMetric.all) { metric in
                    Toggle(metric.displayName, isOn: model.isEnabled(metric))
                }
            } footer: {
                Text("Each type is saved to its own spreadsheet, plus a Daily Summary spreadsheet. If a type stays empty, check that HealthSync is allowed to read it in Settings → Health → Data Access & Devices.")
            }
        }
        .navigationTitle("Data to Sync")
        .onDisappear {
            // Ask for any newly enabled types that weren't authorized yet.
            Task { try? await model.requestHealthAuthorization() }
        }
    }
}

struct FrequencyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let interval = model.settings.interval
        Form {
            Section {
                Stepper(value: model.binding(\.interval.value), in: 1...999) {
                    Text("\(interval.value)")
                        .font(.title2.monospacedDigit())
                        .accessibilityLabel("Interval value \(interval.value)")
                }
                Picker("Unit", selection: model.binding(\.interval.unit)) {
                    ForEach(IntervalUnit.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Sync \(interval.displayText.lowercased())")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if interval.isBelowMinimum {
                        Text("The minimum is 15 minutes, so HealthSync will use every 15 minutes.")
                            .foregroundStyle(.orange)
                    }
                    SchedulingNote()
                }
            }
        }
        .navigationTitle("Sync Frequency")
    }
}
