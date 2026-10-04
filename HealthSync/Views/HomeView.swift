import HealthSyncKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if !model.auth.isSignedIn {
                Section {
                    Label("Not signed in to Google. Sign in from Settings to resume syncing.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Last successful sync") {
                    if let last = model.lastSuccess {
                        Text(last, style: .relative) + Text(" ago")
                    } else {
                        Text("Never")
                    }
                }
                LabeledContent("Next sync (approx.)") {
                    Text(model.nextSyncDate, format: .dateTime.hour().minute().weekday(.abbreviated))
                }
                LabeledContent("Frequency", value: model.settings.interval.displayText)
                if let last = model.runs.first {
                    LabeledContent("Last attempt") {
                        HStack(spacing: 4) {
                            Image(systemName: last.status.symbol)
                            Text(last.status.displayName)
                        }
                        .foregroundStyle(last.status.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
            }

            Section {
                VStack(spacing: 14) {
                    Button {
                        Task { await model.sync(trigger: .manual) }
                    } label: {
                        HStack(spacing: 10) {
                            if model.isSyncing {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(model.isSyncing ? "Syncing…" : "Sync Now")
                        }
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: 260)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.pink)
                    .disabled(model.isSyncing)

                    if let folderID = model.settings.folderID {
                        Link(destination: DriveService.folderURL(id: folderID)) {
                            Label("Open folder in Google Drive", systemImage: "folder")
                                .font(.subheadline)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section("Data types") {
                ForEach(model.settings.enabledMetrics) { metric in
                    MetricStatusRow(metric: metric, status: model.metricStatuses[metric.id])
                }
            }

            Section {
                SchedulingNote()
            }
        }
        .navigationTitle("HealthSync")
        .refreshable { await model.refresh() }
    }
}

private struct MetricStatusRow: View {
    let metric: HealthMetric
    let status: MetricStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.displayName)
                Spacer()
                Text("\(status?.totalRows ?? 0) rows")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let error = status?.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let date = status?.lastSyncAt {
                Text("Updated \(date, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SyncLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.runs) { run in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(run.status.displayName, systemImage: run.status.symbol)
                        .foregroundStyle(run.status.tint)
                    Spacer()
                    Text(run.trigger.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(run.startedAt, format: .dateTime.day().month().hour().minute().second())
                    .font(.subheadline)
                Text("\(run.rowsUploaded) rows uploaded · \(run.rowsDeleted) marked deleted · \(run.duration, format: .number.precision(.fractionLength(1))) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(run.errors, id: \.self) { error in
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .overlay {
            if model.runs.isEmpty {
                ContentUnavailableView("No syncs yet", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Sync Log")
        .refreshable { await model.refresh() }
    }
}
