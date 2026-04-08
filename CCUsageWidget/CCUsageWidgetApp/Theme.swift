import SwiftUI

enum Theme {
    // MARK: - Background

    static let backgroundTop = Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255)
    static let backgroundBottom = Color(red: 30 / 255, green: 41 / 255, blue: 59 / 255)
    static let backgroundGradient = LinearGradient(
        colors: [backgroundTop, backgroundBottom],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: - Card

    static let cardBackground = Color.white.opacity(0.04)
    static let cardBorder = Color.white.opacity(0.06)
    static let accentCardBackground = Color.white.opacity(0.06)
    static let accentCardBorder = Color.white.opacity(0.08)

    // MARK: - Status Colors

    static let green = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)       // #4ade80
    static let orange = Color(red: 251 / 255, green: 146 / 255, blue: 60 / 255)       // #fb923c
    static let red = Color(red: 244 / 255, green: 62 / 255, blue: 94 / 255)           // #f43e5e

    // MARK: - Model Colors

    static let opus = Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255)        // #a78bfa
    static let sonnet = Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255)       // #22d3ee
    static let haiku = Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)       // #94a3b8

    // MARK: - Cost

    static let costPurple = Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255)   // #a855f7

    // MARK: - Text Hierarchy

    static let textPrimary = Color(red: 226 / 255, green: 232 / 255, blue: 240 / 255)     // #e2e8f0
    static let textSecondary = Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)   // #94a3b8
    static let textTertiary = Color(red: 100 / 255, green: 116 / 255, blue: 139 / 255)    // #64748b
    static let textQuaternary = Color(red: 71 / 255, green: 85 / 255, blue: 105 / 255)    // #475569

    // MARK: - Usage Color

    static func usageColor(_ pct: Double, pace: Double? = nil) -> Color {
        let effective = pace.map { max(pct, pct * $0) } ?? pct
        if effective >= 80 { return red }
        if effective >= 50 { return orange }
        return green
    }

    // MARK: - Pace Helpers

    static func paceLabel(_ pace: Double?) -> String {
        guard let p = pace else { return "Unknown" }
        if p > 1.2 { return "Fast" }
        if p < 0.8 { return "Slow" }
        return "Steady"
    }

    static func paceSymbol(_ pace: Double?) -> String {
        guard let p = pace else { return "●" }
        if p > 1.2 { return "▲" }
        if p < 0.8 { return "▼" }
        return "●"
    }

    // MARK: - Reset Label

    static func resetLabel(_ ts: TimeInterval?) -> String {
        guard let ts else { return "" }
        let secs = ts - Date().timeIntervalSince1970
        guard secs > 0 else { return "resetting" }
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h >= 48 { return "\(h / 24)d" }
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: - Depletion Label

    static func depletionLabel(_ seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "" }
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h >= 1 { return "~\(h)h \(m)m" }
        return "~\(m)m"
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(16)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
    }
}
