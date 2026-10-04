import HealthSyncKit
import SwiftUI

/// The enabled data types, grouped by category, with what has been uploaded for each.
struct DataView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DataTypesView()
                } label: {
                    Label("Choose Data Types", systemImage: "checklist")
                }
                LabeledContent("Rows uploaded", value: totalRows.formatted())
            } footer: {
                Text("\(model.settings.enabledMetricIDs.count) of \(HealthMetric.all.count) data types selected.")
            }

            ForEach(categories) { category in
                Section {
                    ForEach(enabledMetrics(in: category)) { metric in
                        MetricStatusRow(metric: metric, status: model.metricStatuses[metric.id])
                    }
                } header: {
                    Label(category.displayName, systemImage: category.symbol)
                }
            }
        }
        .overlay {
            if model.settings.enabledMetricIDs.isEmpty {
                ContentUnavailableView("No data types selected", systemImage: "heart.text.square",
                                       description: Text("Tap Choose Data Types to pick what to sync."))
            }
        }
        .navigationTitle("Data")
        .refreshable { await model.refresh() }
    }

    private var categories: [MetricCategory] {
        MetricCategory.allCases.filter { !enabledMetrics(in: $0).isEmpty }
    }

    private func enabledMetrics(in category: MetricCategory) -> [HealthMetric] {
        category.metrics.filter { model.settings.enabledMetricIDs.contains($0.id) }
    }

    private var totalRows: Int {
        model.settings.enabledMetrics.reduce(0) { $0 + (model.metricStatuses[$1.id]?.totalRows ?? 0) }
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

