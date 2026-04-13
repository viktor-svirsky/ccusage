import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Data Model

struct WidgetData: Codable {
    let fiveHourUtilization: Double
    let sevenDayUtilization: Double
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    let fiveHourResetsAt: TimeInterval?
    let sevenDayResetsAt: TimeInterval?
    let updatedAt: TimeInterval
    // v2 fields — optional for backward compatibility
    let extraUsageEnabled: Bool?
    let depletionSeconds: Double?
    let todayCost: Double?
    let activeSessionCount: Int?
    // v3 fields
    let opusUtilization: Double?
    let sonnetUtilization: Double?
    let haikuUtilization: Double?
    let dailyEntries: [DailyEntryData]?
    let dailyCosts: [DailyCostData]?
    let sessions: [SessionData]?
    let extraUsageUtilization: Double?

    static let placeholder = WidgetData(
        fiveHourUtilization: 45,
        sevenDayUtilization: 32,
        fiveHourPace: 1.0,
        sevenDayPace: 0.8,
        fiveHourResetsAt: Date().addingTimeInterval(14400).timeIntervalSince1970,
        sevenDayResetsAt: Date().addingTimeInterval(4 * 86400).timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970,
        extraUsageEnabled: true,
        depletionSeconds: nil,
        todayCost: 2.50,
        activeSessionCount: 2,
        opusUtilization: 60,
        sonnetUtilization: 25,
        haikuUtilization: 15,
        dailyEntries: nil,
        dailyCosts: nil,
        sessions: [
            SessionData(project: "my-project", model: "opus", tokens: 5200, durationSeconds: 720),
            SessionData(project: "other-proj", model: "sonnet", tokens: 1100, durationSeconds: 180)
        ],
        extraUsageUtilization: 12
    )
}

struct DailyEntryData: Codable {
    let date: String
    let usage: Double
}

struct DailyCostData: Codable {
    let date: String
    let cost: Double
}

struct SessionData: Codable {
    let project: String
    let model: String?
    let tokens: Int?
    let durationSeconds: Int?
}

// MARK: - Shared Config

private let appGroupID = "group.com.viktorsvirsky.ccusage"
private let widgetURLKey = "widgetURL"

// MARK: - Keychain (shared with app — works when App Group doesn't)

private enum KeychainHelper {
    private static let service = "com.viktorsvirsky.ccusage.shared"

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
private let staleThreshold: TimeInterval = 600     // 10 minutes
private let veryStaleThreshold: TimeInterval = 3600 // 1 hour

// MARK: - Helpers

private func usageColor(_ pct: Double, pace: Double?) -> Color {
    let effective = pace.map { max(pct, pct * $0) } ?? pct
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

private func isStale(_ ts: TimeInterval) -> Bool {
    Date().timeIntervalSince1970 - ts > staleThreshold
}

private func isVeryStale(_ ts: TimeInterval) -> Bool {
    Date().timeIntervalSince1970 - ts > veryStaleThreshold
}

private func staleUpdatedLabel(_ ts: TimeInterval) -> String {
    if isVeryStale(ts) { return "offline" }
    if isStale(ts) { return "\(updatedLabel(ts)) ?" }
    return updatedLabel(ts)
}

private func staleOpacity(_ ts: TimeInterval) -> Double {
    isStale(ts) ? 0.5 : 1.0
}

private func formatTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
    return "\(tokens)"
}

private func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h >= 1 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func modelColor(_ model: String) -> Color {
    let lower = model.lowercased()
    if lower.contains("opus") { return Color(red: 167/255, green: 139/255, blue: 250/255) }
    if lower.contains("sonnet") { return Color(red: 34/255, green: 211/255, blue: 238/255) }
    if lower.contains("haiku") { return Color(red: 148/255, green: 163/255, blue: 184/255) }
    return .secondary
}

private let extraPurple = Color(red: 168/255, green: 85/255, blue: 247/255)

// MARK: - Widget Intent (configurable URL fallback)

struct CCUsageIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Claude Usage"
    static var description = IntentDescription("Configure your Claude Code usage widget.")

    @Parameter(title: "Widget URL", description: "Paste from CCUsage Mac menu bar → Share to iPhone. Only needed if widget shows No Data.")
    var widgetURL: String?
}

// MARK: - Provider

struct CCUsageEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
}

struct CCUsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CCUsageEntry {
        CCUsageEntry(date: Date(), data: .placeholder)
    }

    func snapshot(for configuration: CCUsageIntent, in context: Context) async -> CCUsageEntry {
        if context.isPreview {
            return CCUsageEntry(date: Date(), data: .placeholder)
        }
        let data = await fetchData(intentURL: configuration.widgetURL)
        return CCUsageEntry(date: Date(), data: data ?? .placeholder)
    }

    func timeline(for configuration: CCUsageIntent, in context: Context) async -> Timeline<CCUsageEntry> {
        let data = await fetchData(intentURL: configuration.widgetURL)
        let entry = CCUsageEntry(date: Date(), data: data)
        let next = Calendar.current.date(byAdding: .minute, value: 2, to: Date())!
        return Timeline(entries: [entry], policy: .after(next))
    }

    private static let cachedDataKey = "cachedWidgetData"
    private static let cachedDataTimestampKey = "cachedWidgetDataTimestamp"
    private static let cacheMaxAge: TimeInterval = 300 // 5 minutes — app refreshes every 2min

    private func fetchData(intentURL: String?) async -> WidgetData? {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard

        // Prefer data written by the app via App Group — no network needed
        let cachedTimestamp = defaults.double(forKey: Self.cachedDataTimestampKey)
        if cachedTimestamp > 0,
           Date().timeIntervalSince1970 - cachedTimestamp < Self.cacheMaxAge,
           let cachedData = defaults.data(forKey: Self.cachedDataKey),
           let cached = try? JSONDecoder().decode(WidgetData.self, from: cachedData) {
            return cached
        }

        // Resolve URL: App Group → Keychain → intent configuration
        let urlString = defaults.string(forKey: widgetURLKey)
            ?? KeychainHelper.load(key: "widgetURL")
            ?? intentURL
        guard let urlString, let url = URL(string: urlString) else {
            return decodeCached(defaults)
        }

        // Network fetch
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) else {
                return decodeCached(defaults)
            }
            defaults.set(data, forKey: Self.cachedDataKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.cachedDataTimestampKey)
            return decoded
        } catch {
            return decodeCached(defaults)
        }
    }

    private func decodeCached(_ defaults: UserDefaults) -> WidgetData? {
        guard let data = defaults.data(forKey: Self.cachedDataKey),
              let cached = try? JSONDecoder().decode(WidgetData.self, from: data) else {
            return nil
        }
        return cached
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

            Spacer(minLength: 4)
            usageRow(pct: data.fiveHourUtilization, pace: data.fiveHourPace,
                     label: "5h", reset: data.fiveHourResetsAt)
            Spacer(minLength: 6)
            usageRow(pct: data.sevenDayUtilization, pace: data.sevenDayPace,
                     label: "7d", reset: data.sevenDayResetsAt)

            // Extra usage row
            if let extraPct = data.extraUsageUtilization, extraPct > 0 {
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(extraPct.rounded()))%")
                            .font(.caption).fontWeight(.bold)
                            .foregroundStyle(extraPurple)
                        Spacer()
                        Text("Ex")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    ProgressView(value: min(extraPct / 100, 1))
                        .tint(extraPurple)
                        .scaleEffect(x: 1, y: 0.7, anchor: .center)
                }
            }

            Spacer(minLength: 4)

            Text(staleUpdatedLabel(data.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .opacity(staleOpacity(data.updatedAt))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude Usage")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text(staleUpdatedLabel(data.updatedAt))
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

            // Stats row: cost, sessions, extra usage
            Divider()
            HStack(spacing: 0) {
                // Today's cost
                HStack(spacing: 3) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(extraPurple)
                    Text(data.todayCost.map { String(format: "$%.2f", $0) } ?? "--")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)

                // Active sessions
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("\(data.activeSessionCount ?? data.sessions?.count ?? 0)")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text("sessions")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                // Extra usage
                HStack(spacing: 3) {
                    Text("Ex")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let extraPct = data.extraUsageUtilization, extraPct > 0 {
                        Text("\(Int(extraPct.rounded()))%")
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(extraPurple)
                    } else if data.extraUsageEnabled == true {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("Off")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(staleOpacity(data.updatedAt))
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

// MARK: - Large Widget View

private struct LargeView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text(staleUpdatedLabel(data.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            // Utilization cards side by side
            HStack(spacing: 10) {
                largeUtilCard(label: "5-HOUR", pct: data.fiveHourUtilization,
                              pace: data.fiveHourPace, reset: data.fiveHourResetsAt)
                largeUtilCard(label: "7-DAY", pct: data.sevenDayUtilization,
                              pace: data.sevenDayPace, reset: data.sevenDayResetsAt)
            }

            // Model breakdown
            modelBreakdownSection

            // Quick stats row
            statsRow

            Divider()

            // Active sessions
            sessionsSection

            Spacer(minLength: 0)
        }
        .opacity(staleOpacity(data.updatedAt))
        .padding(14)
    }

    // MARK: Utilization Card

    private func largeUtilCard(label: String, pct: Double, pace: Double?, reset: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let r = resetLabel(reset)
                if !r.isEmpty {
                    Text(r)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(usageColor(pct, pace: pace))
                Text(paceSymbol(pace))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ProgressView(value: min(pct / 100, 1))
                .tint(usageColor(pct, pace: pace))
        }
        .padding(10)
        .background(.ultraThinMaterial.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Model Breakdown

    @ViewBuilder
    private var modelBreakdownSection: some View {
        let opusPct = data.opusUtilization ?? 0
        let sonnetPct = data.sonnetUtilization ?? 0
        let haikuPct = data.haikuUtilization ?? 0
        let total = opusPct + sonnetPct + haikuPct
        // Only show breakdown if 2+ models have data — a single model at 100% is misleading
        let modelCount = [opusPct, sonnetPct, haikuPct].filter { $0 > 0 }.count

        if total > 0, modelCount >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL BREAKDOWN")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    HStack(spacing: 2) {
                        if opusPct > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(modelColor("opus"))
                                .frame(width: geo.size.width * CGFloat(opusPct / total))
                        }
                        if sonnetPct > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(modelColor("sonnet"))
                                .frame(width: geo.size.width * CGFloat(sonnetPct / total))
                        }
                        if haikuPct > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(modelColor("haiku"))
                                .frame(width: geo.size.width * CGFloat(haikuPct / total))
                        }
                    }
                }
                .frame(height: 8)

                HStack(spacing: 12) {
                    legendDot(color: modelColor("opus"), text: "Opus \(Int(opusPct.rounded()))%")
                    legendDot(color: modelColor("sonnet"), text: "Son \(Int(sonnetPct.rounded()))%")
                    legendDot(color: modelColor("haiku"), text: "Hai \(Int(haikuPct.rounded()))%")
                }
            }
        }
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(extraPurple)
                Text(data.todayCost.map { String(format: "$%.2f", $0) } ?? "--")
                    .font(.caption2).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("\(data.activeSessionCount ?? data.sessions?.count ?? 0) sessions")
                    .font(.caption2).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 3) {
                Text("Ex")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let extraPct = data.extraUsageUtilization, extraPct > 0 {
                    Text("\(Int(extraPct.rounded()))%")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(extraPurple)
                } else if data.extraUsageEnabled == true {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("Off")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        if let sessions = data.sessions, !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIVE SESSIONS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                let shown = Array(sessions.prefix(2))
                ForEach(Array(shown.enumerated()), id: \.offset) { _, session in
                    HStack(spacing: 6) {
                        Text(session.project)
                            .font(.caption2).fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                        if let model = session.model {
                            Text(model)
                                .font(.system(size: 9))
                                .foregroundStyle(modelColor(model))
                        }
                        if let tokens = session.tokens {
                            Text(formatTokens(tokens))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        if let dur = session.durationSeconds {
                            Text(formatDuration(dur))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(.ultraThinMaterial.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if sessions.count > 2 {
                    Text("+\(sessions.count - 2) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
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

// MARK: - Lock Screen: Circular

@available(iOSApplicationExtension 16.0, *)
private struct AccessoryCircularView: View {
    let data: WidgetData

    private struct Ring: View {
        let pct: Double
        let lineWidth: CGFloat
        let color: Color

        var body: some View {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)
                .overlay(
                    Circle()
                        .trim(from: 0, to: min(pct / 100, 1))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                )
        }
    }

    var body: some View {
        ZStack {
            Ring(pct: data.sevenDayUtilization, lineWidth: 3, color: .white.opacity(0.4))
            Ring(pct: data.fiveHourUtilization, lineWidth: 2.5, color: .white)
                .padding(5)
            VStack(spacing: 0) {
                Text("\(Int(data.fiveHourUtilization.rounded()))")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("\(Int(data.sevenDayUtilization.rounded()))")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Lock Screen: Rectangular

@available(iOSApplicationExtension 16.0, *)
private struct AccessoryRectangularView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Claude")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(paceSymbol(data.fiveHourPace))\(paceSymbol(data.sevenDayPace))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Text("5h").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(Int(data.fiveHourUtilization.rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                HStack(spacing: 2) {
                    Text("7d").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(Int(data.sevenDayUtilization.rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                Spacer()
            }
            ProgressView(value: min(data.fiveHourUtilization / 100, 1))
                .scaleEffect(x: 1, y: 0.7, anchor: .center)
        }
    }
}

// MARK: - Lock Screen: Inline

@available(iOSApplicationExtension 16.0, *)
private struct AccessoryInlineView: View {
    let data: WidgetData

    var body: some View {
        Text("\(Image(systemName: "chart.bar.fill")) \(Int(data.fiveHourUtilization.rounded()))\(paceSymbol(data.fiveHourPace)) · \(Int(data.sevenDayUtilization.rounded()))\(paceSymbol(data.sevenDayPace))")
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
                case .systemMedium: MediumView(data: d)
                case .systemLarge: LargeView(data: d)
                default:
                    if #available(iOSApplicationExtension 16.0, *) {
                        switch family {
                        case .accessoryCircular: AccessoryCircularView(data: d)
                        case .accessoryRectangular: AccessoryRectangularView(data: d)
                        case .accessoryInline: AccessoryInlineView(data: d)
                        default: SmallView(data: d)
                        }
                    } else {
                        SmallView(data: d)
                    }
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
        AppIntentConfiguration(kind: kind, intent: CCUsageIntent.self, provider: CCUsageProvider()) { entry in
            CCUsageEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code limits synced from your Mac.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}
