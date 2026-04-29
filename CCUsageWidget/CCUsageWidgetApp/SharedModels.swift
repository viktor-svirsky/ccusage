import Foundation

struct WidgetData: Codable {
    let fiveHourUtilization: Double
    let sevenDayUtilization: Double
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    let fiveHourResetsAt: TimeInterval?
    let sevenDayResetsAt: TimeInterval?
    let updatedAt: TimeInterval
    let extraUsageEnabled: Bool?
    let depletionSeconds: Double?
    let activeSessionCount: Int?
    // v3 fields
    let opusUtilization: Double?
    let sonnetUtilization: Double?
    let haikuUtilization: Double?
    let dailyEntries: [DailyEntryData]?
    let sessions: [SessionData]?
    let extraUsageUtilization: Double?

    static let placeholder = WidgetData(
        fiveHourUtilization: 45, sevenDayUtilization: 32,
        fiveHourPace: 1.0, sevenDayPace: 0.8,
        fiveHourResetsAt: Date().addingTimeInterval(14400).timeIntervalSince1970,
        sevenDayResetsAt: Date().addingTimeInterval(4 * 86400).timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970,
        extraUsageEnabled: nil, depletionSeconds: nil, activeSessionCount: nil,
        opusUtilization: nil, sonnetUtilization: nil, haikuUtilization: nil,
        dailyEntries: nil, sessions: nil, extraUsageUtilization: nil
    )
}

struct DailyEntryData: Codable {
    let date: String
    let usage: Double
}

struct SessionData: Codable {
    let project: String
    let model: String?
    let tokens: Int?
    let durationSeconds: Int?
    let contextTokens: Int?
    let contextWindowMax: Int?
}
