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

// MARK: - Predictive Timeline

struct PredictiveEntry {
    let date: Date
    let data: WidgetData?

    var utilization5h: Double? { data?.fiveHourUtilization }
    var utilization7d: Double? { data?.sevenDayUtilization }
    var updatedAt: TimeInterval? { data?.updatedAt }
}

func buildPredictiveTimeline(base: WidgetData?, from startDate: Date, count: Int, intervalSeconds: TimeInterval) -> [PredictiveEntry] {
    guard let base else {
        return [PredictiveEntry(date: startDate, data: nil)]
    }
    return (0..<count).map { i in
        let elapsed = TimeInterval(i) * intervalSeconds
        let projected = projectWidgetData(base, secondsAhead: elapsed)
        return PredictiveEntry(date: startDate.addingTimeInterval(elapsed), data: projected)
    }
}
