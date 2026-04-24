import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var dataService: DataService

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if let data = dataService.data {
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
        } else {
            placeholderCard("See main dashboard for usage breakdown.")
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
}
