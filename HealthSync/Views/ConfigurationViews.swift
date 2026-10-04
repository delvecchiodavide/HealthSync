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
    @State private var search = ""
    @State private var expanded: Set<MetricCategory> = []

    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    LabeledContent("Selected", value: "\(model.settings.enabledMetricIDs.count) of \(HealthMetric.all.count)")
                    HStack {
                        Button("Select All") { model.setAllMetrics(enabled: true) }
                            .disabled(model.settings.enabledMetricIDs.count == HealthMetric.all.count)
                        Spacer()
                        Button("Deselect All", role: .destructive) { model.setAllMetrics(enabled: false) }
                            .disabled(model.settings.enabledMetricIDs.isEmpty)
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text("Turn on a whole category with its switch, or expand it to choose individual types.")
                }
                Section {
                    ForEach(MetricCategory.allCases) { category in
                        CategoryRow(category: category, isExpanded: expandedBinding(category))
                        if expanded.contains(category) {
                            let allOn = model.isEnabled(category)
                            Button(allOn.wrappedValue ? "Deselect All" : "Select All") {
                                allOn.wrappedValue.toggle()
                            }
                            .padding(.leading, 44)
                            ForEach(category.metrics) { metric in
                                Toggle(metric.displayName, isOn: model.isEnabled(metric))
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                Section {
                } footer: {
                    Text("Each type is saved to its own spreadsheet, created the first time it has data, plus a Daily Summary spreadsheet. If a type stays empty, check that HealthSync may read it in Settings → Health → Data Access & Devices.")
                }
            } else {
                Section {
                    ForEach(searchResults) { metric in
                        Toggle(isOn: model.isEnabled(metric)) {
                            VStack(alignment: .leading) {
                                Text(metric.displayName)
                                Text(metric.category.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .overlay {
                    if searchResults.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
        }
        .navigationTitle("Data to Sync")
        .searchable(text: $search, prompt: "Search data types")
        .onDisappear {
            // Ask for any newly enabled types that weren't authorized yet.
            Task { try? await model.requestHealthAuthorization() }
        }
    }

    private var searchResults: [HealthMetric] {
        HealthMetric.all.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.category.displayName.localizedCaseInsensitiveContains(search)
        }
    }

    private func expandedBinding(_ category: MetricCategory) -> Binding<Bool> {
        Binding(get: { expanded.contains(category) },
                set: { open in withAnimation { if open { expanded.insert(category) } else { expanded.remove(category) } } })
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: MetricCategory
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: category.symbol)
                        .foregroundStyle(.pink)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.displayName).font(.headline)
                        Text("\(model.enabledCount(in: category)) of \(category.metrics.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category.displayName), \(model.enabledCount(in: category)) of \(category.metrics.count) selected")
            .accessibilityHint(isExpanded ? "Collapse" : "Expand to choose individual types")

            Toggle("All \(category.displayName)", isOn: model.isEnabled(category))
                .labelsHidden()
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
