import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var dataService: DataService

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let data = dataService.data {
                    syncRow(data)
                    staleBanner(data)
                    utilizationCards(data)
                    depletionBanner(data)
                    modelBreakdown(data)
                    weeklyActivityCard(data)
                    activeSessions(data)
                } else {
                    noDataView
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await dataService.fetch() }
    }

    /// Inline sync indicator at the top of the scroll content. Kept out of the
    /// toolbar because iOS wraps toolbar items in button chrome that truncated
    /// "just now" to "ju…" and made the timestamp look like a tappable pill.
    private func syncRow(_ data: WidgetData) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.syncDotColor(data.updatedAt))
                .frame(width: 7, height: 7)
            Text(updatedLabel(data.updatedAt))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                resetsAt: data.fiveHourResetsAt,
                extraChip: nil
            )
            utilizationCard(
                label: "7-Day",
                pct: data.sevenDayUtilization,
                pace: data.sevenDayPace,
                resetsAt: data.sevenDayResetsAt,
                extraChip: extraChipText(data)
            )
        }
        .opacity(Theme.isStale(data.updatedAt) ? 0.6 : 1.0)
    }

    /// Extra usage is a 7-day-window concept (it kicks in once the 7d budget is exhausted),
    /// so its indicator lives inside the 7-Day card rather than as a top-level stat.
    /// Hidden when the user hasn't enabled extra usage at all.
    private func extraChipText(_ data: WidgetData) -> String? {
        guard data.extraUsageEnabled == true else { return nil }
        if let pct = data.extraUsageUtilization, pct > 0 {
            return "Extra \(Int(pct.rounded()))%"
        }
        return "Extra"
    }

    private func utilizationCard(label: String, pct: Double, pace: Double?, resetsAt: TimeInterval?, extraChip: String?) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label.uppercased())
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let extraChip {
                        Text(extraChip)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(Theme.extraPurple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.extraPurple.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.usageColor(pct, pace: pace))
                    Text(Theme.paceSymbol(pace))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 6) {
                    Text(Theme.paceLabel(pace))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    if let trajectory = Theme.trajectoryLabel(pace) {
                        Text(trajectory)
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(Theme.usageColor(pct, pace: pace))
                    }
                }

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


    // MARK: - Weekly Activity (Usage %)

    @ViewBuilder
    private func weeklyActivityCard(_ data: WidgetData) -> some View {
        let entries = data.dailyEntries ?? []
        if !entries.isEmpty {
            let dates = entries.map(\.date).sorted()
            let maxUsage = max(entries.map(\.usage).max() ?? 1, 1)
            let barHeight: CGFloat = 96
            let dailyAvg = entries.map(\.usage).reduce(0, +) / Double(entries.count)

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("WEEKLY ACTIVITY")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text("Daily Avg \(Int(dailyAvg.rounded()))%")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                            let usage = entries.first(where: { $0.date == date })?.usage ?? 0
                            VStack(spacing: 6) {
                                Text(usage > 0 ? "\(Int(usage.rounded()))%" : " ")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Self.barColor(usage))
                                    .frame(width: 12, height: usage > 0 ? max(6, barHeight * CGFloat(usage / maxUsage)) : 4)
                                    .frame(maxWidth: .infinity, minHeight: barHeight, alignment: .bottom)
                                Text(Self.dayLabel(date))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
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

    private static func barColor(_ usage: Double) -> Color {
        if usage >= 80 { return Theme.red }
        if usage >= 50 { return Theme.orange }
        return Theme.green
    }

    // MARK: - Active Sessions

    @ViewBuilder
    private func activeSessions(_ data: WidgetData) -> some View {
        if let sessions = data.sessions, !sessions.isEmpty {
            // Hide model chip when all sessions share one model — chip becomes noise.
            let uniqueModels = Set(sessions.compactMap { $0.model?.lowercased() })
            let showModel = uniqueModels.count > 1

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("ACTIVE SESSIONS")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(Theme.textTertiary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(sessions.count)")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                    sessionCard(session, showModel: showModel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sessionCard(_ session: SessionData, showModel: Bool) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.project)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 14) {
                    if showModel, let model = session.model {
                        Label(modelDisplayName(model), systemImage: "cpu")
                            .font(.caption2)
                            .foregroundStyle(modelColor(model))
                    }
                    if let ctx = session.contextTokens, let ctxMax = session.contextWindowMax, ctxMax > 0 {
                        Label("\(formatTokens(ctx))/\(formatTokens(ctxMax)) ctx", systemImage: "rectangle.compress.vertical")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let tokens = session.tokens {
                        Label("\(formatTokens(tokens)) tok", systemImage: "circle.grid.2x2")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let dur = session.durationSeconds {
                        Label(formatDuration(dur), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modelDisplayName(_ model: String) -> String {
        // claude-opus-4-7 → Opus 4.7
        let parts = model.lowercased().split(separator: "-")
        let families = ["opus", "sonnet", "haiku"]
        guard let idx = parts.firstIndex(where: { families.contains(String($0)) }) else { return model }
        let family = String(parts[idx]).capitalized
        let version = parts.dropFirst(idx + 1).prefix(2).compactMap { p -> String? in
            let digits = p.prefix(while: { $0.isNumber })
            return digits.isEmpty ? nil : String(digits)
        }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
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
