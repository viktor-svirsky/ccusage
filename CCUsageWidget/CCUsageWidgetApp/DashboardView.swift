import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var dataService: DataService

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if let data = dataService.data {
                    staleBanner(data)
                    utilizationCards(data)
                    depletionBanner(data)
                    modelBreakdown(data)
                    quickStats(data)
                    weeklyActivityCard(data)
                    activeSessions(data)
                } else {
                    noDataView
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .refreshable { await dataService.fetch() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Dashboard")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let data = dataService.data {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.green)
                        .frame(width: 8, height: 8)
                    Text(updatedLabel(data.updatedAt))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Stale Banner

    @ViewBuilder
    private func staleBanner(_ data: WidgetData) -> some View {
        if Theme.isStale(data.updatedAt) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(Theme.isVeryStale(data.updatedAt) ? Theme.red : Theme.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Data may be outdated")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Last updated \(updatedLabel(data.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(14)
            .background((Theme.isVeryStale(data.updatedAt) ? Theme.red : Theme.orange).opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke((Theme.isVeryStale(data.updatedAt) ? Theme.red : Theme.orange).opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Utilization Cards

    private func utilizationCards(_ data: WidgetData) -> some View {
        HStack(spacing: 12) {
            utilizationCard(
                label: "5-Hour",
                pct: data.fiveHourUtilization,
                pace: data.fiveHourPace,
                resetsAt: data.fiveHourResetsAt
            )
            utilizationCard(
                label: "7-Day",
                pct: data.sevenDayUtilization,
                pace: data.sevenDayPace,
                resetsAt: data.sevenDayResetsAt
            )
        }
        .opacity(Theme.isStale(data.updatedAt) ? 0.6 : 1.0)
    }

    private func utilizationCard(label: String, pct: Double, pace: Double?, resetsAt: TimeInterval?) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(label.uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(Theme.textTertiary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.usageColor(pct, pace: pace))
                    Text(Theme.paceSymbol(pace))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Text(Theme.paceLabel(pace))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                ProgressView(value: min(pct / 100, 1))
                    .tint(Theme.usageColor(pct, pace: pace))

                let reset = Theme.resetLabel(resetsAt)
                if !reset.isEmpty {
                    Text("Resets in \(reset)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Depletion Banner

    @ViewBuilder
    private func depletionBanner(_ data: WidgetData) -> some View {
        if let dep = data.depletionSeconds, dep > 0, dep < 7200 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Depletion Warning")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Usage depletes in \(Theme.depletionLabel(dep))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.orange.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Model Breakdown

    @ViewBuilder
    private func modelBreakdown(_ data: WidgetData) -> some View {
        let opusPct = data.opusUtilization ?? 0
        let sonnetPct = data.sonnetUtilization ?? 0
        let haikuPct = data.haikuUtilization ?? 0
        let total = opusPct + sonnetPct + haikuPct
        let modelCount = [opusPct, sonnetPct, haikuPct].filter { $0 > 0 }.count

        if total > 0, modelCount >= 2 {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MODEL BREAKDOWN")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(Theme.textTertiary)

                    // Stacked bar
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            if opusPct > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.opus)
                                    .frame(width: geo.size.width * CGFloat(opusPct / total))
                            }
                            if sonnetPct > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.sonnet)
                                    .frame(width: geo.size.width * CGFloat(sonnetPct / total))
                            }
                            if haikuPct > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.haiku)
                                    .frame(width: geo.size.width * CGFloat(haikuPct / total))
                            }
                        }
                    }
                    .frame(height: 10)

                    // Legend
                    HStack(spacing: 16) {
                        modelLegend(color: Theme.opus, name: "Opus", pct: opusPct)
                        modelLegend(color: Theme.sonnet, name: "Sonnet", pct: sonnetPct)
                        modelLegend(color: Theme.haiku, name: "Haiku", pct: haikuPct)
                    }
                }
            }
        }
    }

    private func modelLegend(color: Color, name: String, pct: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(name) \(Int(pct.rounded()))%")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Quick Stats

    private func quickStats(_ data: WidgetData) -> some View {
        HStack(spacing: 10) {
            statCard(
                icon: "dollarsign.circle.fill",
                color: Theme.costPurple,
                value: data.todayCost.map { String(format: "$%.2f", $0) } ?? "--",
                label: "Today"
            )
            statCard(
                icon: "bolt.fill",
                color: Theme.green,
                value: "\(data.activeSessionCount ?? data.sessions?.count ?? 0)",
                label: "Sessions"
            )
            statCard(
                icon: "arrow.up.right",
                color: data.extraUsageEnabled == true ? Theme.green : Theme.textTertiary,
                value: data.extraUsageEnabled == true ? "On" : "Off",
                label: "Extra"
            )
        }
    }

    private func statCard(icon: String, color: Color, value: String, label: String) -> some View {
        GlassCard {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(value)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Weekly Activity (Usage % + Cost $)

    @ViewBuilder
    private func weeklyActivityCard(_ data: WidgetData) -> some View {
        let entries = data.dailyEntries ?? []
        let costs = data.dailyCosts ?? []
        let hasData = !entries.isEmpty || !costs.isEmpty
        if hasData {
            let costByDate: [String: Double] = Dictionary(uniqueKeysWithValues: costs.map { ($0.date, $0.cost) })
            let dates = mergedDates(entries: entries, costs: costs)
            let maxUsage = max(entries.map(\.usage).max() ?? 1, 1)
            let maxCost = max(costs.map(\.cost).max() ?? 0.01, 0.01)
            let weekCost = costs.map(\.cost).reduce(0, +)
            let barHeight: CGFloat = 90

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("WEEKLY ACTIVITY")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if weekCost > 0 {
                            Text(String(format: "$%.2f", weekCost))
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(Theme.costPurple)
                        }
                    }

                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                            let usage = entries.first(where: { $0.date == date })?.usage ?? 0
                            let cost = costByDate[date] ?? 0
                            VStack(spacing: 3) {
                                // Stack labels vertically so each gets full column width — side-by-side
                                // HStack caused "$389" to wrap into "$38 / 9" on narrow 7-day layout.
                                Text(usage > 0 ? "\(Int(usage.rounded()))%" : " ")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity)
                                Text(cost > 0 ? Self.costLabel(cost) : " ")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.costPurple.opacity(0.85))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity)
                                HStack(alignment: .bottom, spacing: 2) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Self.barColor(usage))
                                        .frame(width: 8, height: usage > 0 ? max(2, barHeight * CGFloat(usage / maxUsage)) : 2)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Theme.costPurple.opacity(0.65))
                                        .frame(width: 8, height: cost > 0 ? max(2, barHeight * CGFloat(cost / maxCost)) : 2)
                                }
                                .frame(maxWidth: .infinity, minHeight: barHeight, alignment: .bottom)
                                Text(Self.dayLabel(date))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Divider().overlay(Theme.cardBorder)

                    HStack {
                        miniStat(label: "Active", value: "\(entries.filter { $0.usage > 0 }.count)/\(dates.count)")
                        Spacer()
                        miniStat(
                            label: "Daily Avg",
                            value: entries.isEmpty
                                ? "--"
                                : "\(Int((entries.map(\.usage).reduce(0, +) / Double(entries.count)).rounded()))%"
                        )
                        Spacer()
                        miniStat(label: "Peak", value: peakDay(entries))
                    }
                }
            }
        }
    }

    private func mergedDates(entries: [DailyEntryData], costs: [DailyCostData]) -> [String] {
        var set = Set<String>()
        entries.forEach { set.insert($0.date) }
        costs.forEach { set.insert($0.date) }
        return set.sorted()
    }

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static func dayLabel(_ s: String) -> String {
        guard let d = dateParser.date(from: s) else { return String(s.suffix(2)) }
        return dayFormatter.string(from: d)
    }

    private static func costLabel(_ cost: Double) -> String {
        if cost >= 1000 { return String(format: "$%.1fk", cost / 1000) }
        if cost >= 1 { return String(format: "$%.0f", cost) }
        return String(format: "$%.2f", cost)
    }

    private static func barColor(_ usage: Double) -> Color {
        if usage >= 80 { return Theme.red }
        if usage >= 50 { return Theme.orange }
        return Theme.green
    }

    private func peakDay(_ entries: [DailyEntryData]) -> String {
        guard let peak = entries.max(by: { $0.usage < $1.usage }), peak.usage > 0 else { return "--" }
        return Self.dayLabel(peak.date)
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.caption).fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
            Text(label).font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Active Sessions

    @ViewBuilder
    private func activeSessions(_ data: WidgetData) -> some View {
        if let sessions = data.sessions, !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTIVE SESSIONS")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(Theme.textTertiary)

                ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                    sessionCard(session)
                }
            }
        }
    }

    private func sessionCard(_ session: SessionData) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.project)
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.green.opacity(0.15))
                        .clipShape(Capsule())
                }
                HStack(spacing: 12) {
                    if let model = session.model {
                        Label(model, systemImage: "cpu")
                            .font(.caption2)
                            .foregroundStyle(modelColor(model))
                    }
                    if let tokens = session.tokens {
                        Label(formatTokens(tokens), systemImage: "number")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let dur = session.durationSeconds {
                        Label(formatDuration(dur), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - No Data

    private var noDataView: some View {
        GlassCard {
            VStack(spacing: 16) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.textTertiary)
                Text("No Data Yet")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Connect to your Mac running CCUsage to see live usage data.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Helpers

    private func updatedLabel(_ ts: TimeInterval) -> String {
        let ago = Int(Date().timeIntervalSince1970 - ts)
        if ago < 60 { return "just now" }
        if ago < 3600 { return "\(ago / 60)m ago" }
        if ago < 86400 { return "\(ago / 3600)h ago" }
        return "\(ago / 86400)d ago"
    }

    private func modelColor(_ model: String) -> Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return Theme.opus }
        if lower.contains("sonnet") { return Theme.sonnet }
        if lower.contains("haiku") { return Theme.haiku }
        return Theme.textSecondary
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
}
