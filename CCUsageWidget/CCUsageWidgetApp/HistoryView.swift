import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var dataService: DataService

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if let data = dataService.data {
                    weeklyUsageChart(data)
                    costHistoryChart(data)
                    modelMix(data)
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
            Text("History")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Weekly Usage Chart

    @ViewBuilder
    private func weeklyUsageChart(_ data: WidgetData) -> some View {
        if let entries = data.dailyEntries, !entries.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("WEEKLY USAGE")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(Theme.textTertiary)

                    let maxVal = entries.map(\.usage).max() ?? 1
                    let barHeight: CGFloat = 120

                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            VStack(spacing: 4) {
                                Text("\(Int(entry.usage.rounded()))%")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(barColor(entry.usage))
                                    .frame(height: max(4, barHeight * CGFloat(entry.usage / max(maxVal, 1))))

                                Text(dayLabel(entry.date))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: barHeight + 40)

                    Divider().overlay(Theme.cardBorder)

                    // Summary row
                    HStack {
                        summaryItem(
                            label: "Active Days",
                            value: "\(entries.filter { $0.usage > 0 }.count)/\(entries.count)"
                        )
                        Spacer()
                        summaryItem(
                            label: "Daily Avg",
                            value: "\(Int((entries.map(\.usage).reduce(0, +) / Double(entries.count)).rounded()))%"
                        )
                        Spacer()
                        summaryItem(
                            label: "Peak",
                            value: peakDay(entries)
                        )
                    }
                }
            }
        } else {
            placeholderCard("Update CCUsage on your Mac for history data")
        }
    }

    // MARK: - Cost History

    @ViewBuilder
    private func costHistoryChart(_ data: WidgetData) -> some View {
        if let costs = data.dailyCosts, !costs.isEmpty {
            let weekTotal = costs.map(\.cost).reduce(0, +)
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("COST HISTORY")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text(String(format: "$%.2f", weekTotal))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(Theme.costPurple)
                    }

                    let maxVal = costs.map(\.cost).max() ?? 1
                    let barHeight: CGFloat = 80

                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(costs.enumerated()), id: \.offset) { _, entry in
                            VStack(spacing: 4) {
                                Text(entry.cost >= 1 ? String(format: "$%.0f", entry.cost) : String(format: "$%.2f", entry.cost))
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.costPurple.opacity(0.8))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.costPurple.opacity(0.6))
                                    .frame(height: max(4, barHeight * CGFloat(entry.cost / max(maxVal, 0.01))))

                                Text(dayLabel(entry.date))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: barHeight + 36)
                }
            }
        }
    }

    // MARK: - Model Mix

    @ViewBuilder
    private func modelMix(_ data: WidgetData) -> some View {
        let opusPct = data.opusUtilization ?? 0
        let sonnetPct = data.sonnetUtilization ?? 0
        let haikuPct = data.haikuUtilization ?? 0
        let total = opusPct + sonnetPct + haikuPct
        let modelCount = [opusPct, sonnetPct, haikuPct].filter { $0 > 0 }.count

        if total > 0, modelCount >= 2 {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("MODEL MIX")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(Theme.textTertiary)

                    modelBar(name: "Opus", pct: opusPct, total: total, color: Theme.opus)
                    modelBar(name: "Sonnet", pct: sonnetPct, total: total, color: Theme.sonnet)
                    modelBar(name: "Haiku", pct: haikuPct, total: total, color: Theme.haiku)
                }
            }
        }
    }

    private func modelBar(name: String, pct: Double, total: Double, color: Color) -> some View {
        let fraction = total > 0 ? pct / total : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Placeholder

    private func placeholderCard(_ message: String) -> some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(Theme.textTertiary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private var noDataView: some View {
        placeholderCard("Connect to your Mac to see usage history.")
    }

    // MARK: - Helpers

    private func barColor(_ usage: Double) -> Color {
        if usage >= 80 { return Theme.red }
        if usage >= 50 { return Theme.orange }
        return Theme.green
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

    private func dayLabel(_ dateString: String) -> String {
        guard let date = Self.dateParser.date(from: dateString) else {
            return String(dateString.suffix(2))
        }
        return Self.dayFormatter.string(from: date)
    }

    private func peakDay(_ entries: [DailyEntryData]) -> String {
        guard let peak = entries.max(by: { $0.usage < $1.usage }) else { return "--" }
        return dayLabel(peak.date)
    }

    private func summaryItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
