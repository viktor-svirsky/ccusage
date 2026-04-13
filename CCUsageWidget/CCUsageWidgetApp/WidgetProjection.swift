import Foundation

func projectWidgetData(_ base: WidgetData, secondsAhead: TimeInterval) -> WidgetData {
    guard secondsAhead > 0 else { return base }

    func projectUtilization(current: Double, pace: Double?, resetsAt: TimeInterval?, windowDuration: TimeInterval) -> Double {
        guard let pace, let resetsAt else { return current }
        let remaining = resetsAt - base.updatedAt
        guard remaining > 0 else { return current }
        let elapsed = windowDuration - remaining
        guard elapsed > 0 else { return current }
        let ratePerSecond = (current / elapsed) * pace
        return min(current + ratePerSecond * secondsAhead, 100)
    }

    return WidgetData(
        fiveHourUtilization: projectUtilization(
            current: base.fiveHourUtilization,
            pace: base.fiveHourPace,
            resetsAt: base.fiveHourResetsAt,
            windowDuration: 5 * 3600
        ),
        sevenDayUtilization: projectUtilization(
            current: base.sevenDayUtilization,
            pace: base.sevenDayPace,
            resetsAt: base.sevenDayResetsAt,
            windowDuration: 7 * 86400
        ),
        fiveHourPace: base.fiveHourPace,
        sevenDayPace: base.sevenDayPace,
        fiveHourResetsAt: base.fiveHourResetsAt.map { $0 - secondsAhead },
        sevenDayResetsAt: base.sevenDayResetsAt.map { $0 - secondsAhead },
        updatedAt: base.updatedAt,
        extraUsageEnabled: base.extraUsageEnabled,
        depletionSeconds: base.depletionSeconds.map { max(0, $0 - secondsAhead) },
        todayCost: base.todayCost,
        activeSessionCount: base.activeSessionCount,
        opusUtilization: base.opusUtilization,
        sonnetUtilization: base.sonnetUtilization,
        haikuUtilization: base.haikuUtilization,
        dailyEntries: base.dailyEntries,
        dailyCosts: base.dailyCosts,
        sessions: base.sessions,
        extraUsageUtilization: base.extraUsageUtilization
    )
}
