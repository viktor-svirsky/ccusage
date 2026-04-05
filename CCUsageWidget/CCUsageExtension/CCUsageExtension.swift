import WidgetKit
import SwiftUI

// MARK: - Data Model

struct WidgetData: Codable {
    let fiveHourUtilization: Double
    let sevenDayUtilization: Double
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    let fiveHourResetsAt: TimeInterval?
    let sevenDayResetsAt: TimeInterval?
    let updatedAt: TimeInterval

    static let placeholder = WidgetData(
        fiveHourUtilization: 45,
        sevenDayUtilization: 32,
        fiveHourPace: 1.0,
        sevenDayPace: 0.8,
        fiveHourResetsAt: Date().addingTimeInterval(14400).timeIntervalSince1970,
        sevenDayResetsAt: Date().addingTimeInterval(4 * 86400).timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970
    )
}

// MARK: - Shared Config

private let appGroupID = "group.com.viktorsvirsky.ccusage"
private let widgetURLKey = "widgetURL"

// MARK: - Helpers

private func usageColor(_ pct: Double, pace: Double?) -> Color {
    let effective = (pace ?? 1.0) * pct
    if effective >= 80 { return .red }
    if effective >= 50 { return Color(red: 1, green: 0.55, blue: 0) }
    return .green
}

private func paceSymbol(_ pace: Double?) -> String {
    guard let p = pace else { return "●" }
    if p > 1.2 { return "▲" }
    if p < 0.8 { return "▼" }
    return "●"
}

private func resetLabel(_ ts: TimeInterval?) -> String {
    guard let ts else { return "" }
    let secs = ts - Date().timeIntervalSince1970
    guard secs > 0 else { return "resetting" }
    let h = Int(secs) / 3600
    let m = (Int(secs) % 3600) / 60
    if h >= 48 { return "\(h / 24)d" }
    if h >= 1  { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func updatedLabel(_ ts: TimeInterval) -> String {
    let ago = Int(Date().timeIntervalSince1970 - ts)
    if ago < 60    { return "just now" }
    if ago < 3600  { return "\(ago / 60)m ago" }
    if ago < 86400 { return "\(ago / 3600)h ago" }
    return "\(ago / 86400)d ago"
}

// MARK: - Provider

struct CCUsageEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
}

struct CCUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CCUsageEntry {
        CCUsageEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CCUsageEntry) -> Void) {
        if context.isPreview {
            completion(CCUsageEntry(date: Date(), data: .placeholder))
            return
        }
        fetchData { data in
            completion(CCUsageEntry(date: Date(), data: data ?? .placeholder))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CCUsageEntry>) -> Void) {
        fetchData { data in
            let entry = CCUsageEntry(date: Date(), data: data)
            let next = Calendar.current.date(byAdding: .minute, value: 2, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private static let cachedDataKey = "cachedWidgetData"
    private static let cachedDataTimestampKey = "cachedWidgetDataTimestamp"
    private static let cacheMaxAge: TimeInterval = 90 // 1.5 minutes

    private func fetchData(completion: @escaping (WidgetData?) -> Void) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let urlString = defaults.string(forKey: widgetURLKey),
              let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        // Return cached data if fresh enough
        let cachedTimestamp = defaults.double(forKey: Self.cachedDataTimestampKey)
        if cachedTimestamp > 0,
           Date().timeIntervalSince1970 - cachedTimestamp < Self.cacheMaxAge,
           let cachedData = defaults.data(forKey: Self.cachedDataKey),
           let cached = try? JSONDecoder().decode(WidgetData.self, from: cachedData) {
            completion(cached)
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) else {
                // Fall back to stale cache on network failure
                if let cachedData = defaults.data(forKey: Self.cachedDataKey),
                   let cached = try? JSONDecoder().decode(WidgetData.self, from: cachedData) {
                    completion(cached)
                } else {
                    completion(nil)
                }
                return
            }
            defaults.set(data, forKey: Self.cachedDataKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.cachedDataTimestampKey)
            completion(decoded)
        }.resume()
    }
}

// MARK: - Small Widget View

private struct SmallView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)
            usageRow(pct: data.fiveHourUtilization, pace: data.fiveHourPace,
                     label: "5h", reset: data.fiveHourResetsAt)
            Spacer(minLength: 8)
            usageRow(pct: data.sevenDayUtilization, pace: data.sevenDayPace,
                     label: "7d", reset: data.sevenDayResetsAt)
            Spacer(minLength: 6)

            Text(updatedLabel(data.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    @ViewBuilder
    private func usageRow(pct: Double, pace: Double?, label: String, reset: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(pct.rounded()))%")
                    .font(.title3).fontWeight(.bold)
                    .foregroundStyle(usageColor(pct, pace: pace))
                Text(paceSymbol(pace))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(label)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ProgressView(value: min(pct / 100, 1))
                .tint(usageColor(pct, pace: pace))
                .scaleEffect(x: 1, y: 0.8, anchor: .center)
        }
    }
}

// MARK: - Medium Widget View

private struct MediumView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Usage")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text(updatedLabel(data.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            usageRow(label: "5-HOUR",
                     pct: data.fiveHourUtilization,
                     pace: data.fiveHourPace,
                     reset: data.fiveHourResetsAt)
            usageRow(label: "7-DAY",
                     pct: data.sevenDayUtilization,
                     pace: data.sevenDayPace,
                     reset: data.sevenDayResetsAt)
        }
        .padding(14)
    }

    @ViewBuilder
    private func usageRow(label: String, pct: Double, pace: Double?, reset: TimeInterval?) -> some View {
        let resetStr = resetLabel(reset)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                if !resetStr.isEmpty {
                    Text(resetStr)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Text("\(Int(pct.rounded()))%")
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(usageColor(pct, pace: pace))
                    .frame(width: 46, alignment: .leading)
                ProgressView(value: min(pct / 100, 1))
                    .tint(usageColor(pct, pace: pace))
                Text(paceSymbol(pace))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 14)
            }
        }
    }
}

// MARK: - No-data View

private struct NoDataView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2).foregroundStyle(.secondary)
            Text("No data")
                .font(.caption).foregroundStyle(.secondary)
            Text("Open CCUsage app to connect")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Entry View

struct CCUsageEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: CCUsageEntry

    var body: some View {
        Group {
            if let d = entry.data {
                switch family {
                case .systemSmall: SmallView(data: d)
                default:           MediumView(data: d)
                }
            } else {
                NoDataView()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

@main
struct CCUsageExtensionBundle: Widget {
    let kind = "CCUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CCUsageProvider()) { entry in
            CCUsageEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code limits synced from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
