import SwiftUI
import Charts

struct ResourceHistoryView: View {
    let points: [ResourcePoint]
    let collection: String
    let omittedChunks: UInt32
    let loading: Bool
    @State private var metric = ResourceMetric.cpu
    @State private var selectedDate: Date?

    init(points: [ResourcePoint], collection: String, omittedChunks: UInt32, loading: Bool,
         metric: ResourceMetric = .cpu) {
        self.points = points; self.collection = collection
        self.omittedChunks = omittedChunks; self.loading = loading
        _metric = State(initialValue: metric)
    }

    var body: some View {
        let samples = metric.samples(from: points)
        let selected = selectedDate.flatMap { date in
            samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                .flatMap { abs($0.date.timeIntervalSince(date)) <= 30 ? $0 : nil }
        }
        let displayed = selectedDate == nil ? samples.last : selected
        VStack(alignment: .leading, spacing: 20) {
            Picker("Resource", selection: $metric) {
                ForEach(ResourceMetric.allCases) { metric in Text(metric.title).tag(metric) }
            }.pickerStyle(.segmented)

            if samples.isEmpty {
                ContentUnavailableView {
                    Label(loading || collection == "pending" ? "Collecting resource history" : "No measurements", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(loading || collection == "pending" ? "Measurements will appear once collected. Use Refresh to check again." : "No measurements are available for this resource in this session.")
                }.frame(minHeight: 260)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedDate == nil ? "Latest" : "Selected").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let displayed {
                                Text(displayed.value, format: .number.precision(.fractionLength(0...2)))
                                    .font(.system(.largeTitle, design: .rounded).weight(.semibold)).monospacedDigit()
                            } else { Text("—").font(.largeTitle) }
                            Text(metric.unit).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let date = selectedDate ?? displayed?.date {
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine)

                    historyChart(samples, selected: selected)
                        .frame(height: 240)

                    Text("Select a point on the chart to inspect a measurement.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        summary("Average", value: samples.reduce(0) { $0 + $1.value } / Double(samples.count))
                        Spacer()
                        summary("Peak", value: samples.map(\.value).max() ?? 0)
                    }
                }
                .padding(20).glass(in: RoundedRectangle(cornerRadius: 24))
            }
            Text(metric.explanation).font(.caption).foregroundStyle(.secondary)
            if omittedChunks > 0 {
                Label("Some older resource history was omitted.", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: metric) { selectedDate = nil }
        .onChange(of: points) { selectedDate = nil }
    }

    private func historyChart(_ samples: [ResourceChartSample], selected: ResourceChartSample?) -> some View {
        Chart {
            ForEach(samples) { sample in
                if metric.isIO {
                    BarMark(x: .value("Time", sample.date, unit: .minute), y: .value(metric.title, sample.value))
                        .foregroundStyle(Color.accentColor.gradient)
                        .accessibilityLabel(Text(sample.date, format: .dateTime.month(.abbreviated).day().hour().minute()))
                        .accessibilityValue(Text("\(sample.value.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)"))
                } else {
                    AreaMark(x: .value("Time", sample.date), y: .value(metric.title, sample.value), series: .value("Segment", sample.segment))
                        .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.18), .accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .accessibilityHidden(true)
                    LineMark(x: .value("Time", sample.date), y: .value(metric.title, sample.value), series: .value("Segment", sample.segment))
                        .foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 2))
                        .symbol(.circle).symbolSize(samples.count < 60 ? 12 : 3)
                        .accessibilityLabel(Text(sample.date, format: .dateTime.month(.abbreviated).day().hour().minute()))
                        .accessibilityValue(Text("\(sample.value.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)"))
                }
            }
            if let date = selected?.date ?? selectedDate {
                RuleMark(x: .value("Time", date)).foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).accessibilityHidden(true)
            }
            if let selected {
                PointMark(x: .value("Time", selected.date), y: .value(metric.title, selected.value))
                    .foregroundStyle(Color.accentColor).symbolSize(70).accessibilityHidden(true)
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: timeDomain)
        .chartYScale(domain: 0...max((samples.map(\.value).max() ?? 0) * 1.1, 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound) > 86_400
                             ? .dateTime.month(.abbreviated).day().hour()
                             : .dateTime.hour().minute())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel(Text(metric.title))
    }

    private var timeDomain: ClosedRange<Date> {
        let dates = points.map { Date(timeIntervalSince1970: Double($0.time) / 1000) }
        let first = dates.min() ?? .now
        let last = dates.max() ?? first
        return first.addingTimeInterval(-30)...max(last.addingTimeInterval(30), first.addingTimeInterval(60))
    }

    private func summary(_ title: LocalizedStringKey, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)")
                .font(.subheadline.weight(.medium)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

enum ResourceMetric: String, CaseIterable, Identifiable {
    case cpu, memory, read, write
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .read: String(localized: "Read")
        case .write: String(localized: "Write")
        }
    }
    var unit: String { self == .cpu ? String(localized: "cores") : isIO ? "MiB/min" : "MiB" }
    var isIO: Bool { self == .read || self == .write }
    var explanation: String {
        isIO ? String(localized: "Disk I/O totals per minute. Gaps indicate missing measurements.")
             : String(localized: "Minute averages. Gaps indicate missing measurements or a workspace restart.")
    }
    func samples(from points: [ResourcePoint]) -> [ResourceChartSample] {
        var samples: [ResourceChartSample] = []
        var previous: ResourcePoint?
        var segment = 0
        for (index, point) in points.sorted(by: { $0.time < $1.time }).enumerated() {
            let raw: Double?
            switch self {
            case .cpu: raw = point.cpuCores
            case .memory: raw = point.memoryBytes
            case .read: raw = point.readBytes
            case .write: raw = point.writeBytes
            }
            guard let raw, raw.isFinite, raw >= 0 else { segment += 1; previous = nil; continue }
            if let previous, previous.runId != point.runId || point.time - previous.time > 60_000 { segment += 1 }
            samples.append(ResourceChartSample(id: index, date: Date(timeIntervalSince1970: Double(point.time) / 1000),
                                               value: raw / (self == .cpu ? 1 : 1_048_576), segment: segment))
            previous = point
        }
        return samples
    }
}

struct ResourceChartSample: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let segment: Int
}

#if DEBUG
private var resourcePreviewPoints: [ResourcePoint] {
    var points: [ResourcePoint] = []
    for minute in 0..<90 {
        let time: Int64 = 1_794_737_400_000 + Int64(minute) * 60_000
        let cpu: Double? = minute == 35 ? nil : 0.3 + abs(sin(Double(minute) / 8.0)) * 1.8
        let memory: Double = Double(450 + minute * 3) * 1_048_576.0
        let read: Double = Double(minute % 12) * 1_048_576.0
        let write: Double = Double(minute % 4) * 524_288.0
        points.append(ResourcePoint(time: time, cpuCores: cpu, memoryBytes: memory,
                    readBytes: read, writeBytes: write,
                    runId: minute < 60 ? "first" : "restarted"))
    }
    return points
}

#Preview("Resource history") {
    ScrollView {
        ResourceHistoryView(points: resourcePreviewPoints, collection: "complete",
                            omittedChunks: 1, loading: false).padding()
    }.frame(width: 375, height: 700)
}

#Preview("Collecting resources") {
    ResourceHistoryView(points: [], collection: "pending", omittedChunks: 0, loading: false).padding()
}

#endif
