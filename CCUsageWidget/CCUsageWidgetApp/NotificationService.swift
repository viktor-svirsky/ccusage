import Foundation
#if !TESTING
import UserNotifications
#endif

// MARK: - Pure Decide Helpers (testable)

enum PaceDecision: Equatable {
    case fire     // pace exceeded, not yet alerted
    case clear    // pace back under threshold, clear alerted flag
    case unchanged
}

/// Window reset fires when tracked `resetsAt` advances past the previously seen one by >60s and
/// the closing window had non-trivial usage. Mirrors `detectReset` in main.swift.
func shouldFireWindowReset(
    priorResetsAt: TimeInterval?,
    newResetsAt: TimeInterval?,
    priorUtilization: Double
) -> Bool {
    guard let priorResetsAt, let newResetsAt, priorResetsAt > 0 else { return false }
    return newResetsAt - priorResetsAt > 60 && priorUtilization >= 1.0
}

/// Edge-triggered: fire once when pace crosses above 1.2x, clear when back under. Matches Mac
/// pace-alert semantics (no cooldown spam while sustained over pace).
func decidePace(pace: Double?, alreadyAlerted: Bool) -> PaceDecision {
    guard let pace else { return .unchanged }
    if pace > 1.2 { return alreadyAlerted ? .unchanged : .fire }
    return alreadyAlerted ? .clear : .unchanged
}

#if !TESTING
class NotificationService {
    static let shared = NotificationService()

    private let defaults = UserDefaults.standard
    private let cooldown: TimeInterval = 1800 // 30 minutes

    // MARK: - Toggle Keys

    private enum Key: String {
        case highUsage = "notif_highUsage"
        case critical = "notif_critical"
        case depletion = "notif_depletion"
        case pace = "notif_pace"
        case windowReset = "notif_windowReset"
        case lastHigh = "notif_lastHigh"
        case lastCritical = "notif_lastCritical"
        case lastDepletion = "notif_lastDepletion"
        case paceAlerted5h = "notif_paceAlerted5h"
        case paceAlerted7d = "notif_paceAlerted7d"
        case priorReset5h = "notif_priorReset5h"
        case priorReset7d = "notif_priorReset7d"
        case priorUtil5h = "notif_priorUtil5h"
        case priorUtil7d = "notif_priorUtil7d"
    }

    var highUsageEnabled: Bool {
        get { defaults.bool(forKey: Key.highUsage.rawValue) }
        set { defaults.set(newValue, forKey: Key.highUsage.rawValue) }
    }

    var criticalEnabled: Bool {
        get { defaults.bool(forKey: Key.critical.rawValue) }
        set { defaults.set(newValue, forKey: Key.critical.rawValue) }
    }

    var depletionEnabled: Bool {
        get { defaults.bool(forKey: Key.depletion.rawValue) }
        set { defaults.set(newValue, forKey: Key.depletion.rawValue) }
    }

    var paceEnabled: Bool {
        get { defaults.bool(forKey: Key.pace.rawValue) }
        set { defaults.set(newValue, forKey: Key.pace.rawValue) }
    }

    var windowResetEnabled: Bool {
        get { defaults.bool(forKey: Key.windowReset.rawValue) }
        set { defaults.set(newValue, forKey: Key.windowReset.rawValue) }
    }

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - Evaluation

    func evaluate(_ data: WidgetData) {
        let now = Date().timeIntervalSince1970
        let pct = max(data.fiveHourUtilization, data.sevenDayUtilization)

        if depletionEnabled,
           let dep = data.depletionSeconds, dep > 0, dep < 600,
           now - defaults.double(forKey: Key.lastDepletion.rawValue) > cooldown {
            defaults.set(now, forKey: Key.lastDepletion.rawValue)
            send(
                title: "Usage Depleting",
                body: "Claude Code usage will deplete in \(Theme.depletionLabel(dep)). Consider pausing."
            )
        } else if criticalEnabled, pct >= 95,
                  now - defaults.double(forKey: Key.lastCritical.rawValue) > cooldown {
            defaults.set(now, forKey: Key.lastCritical.rawValue)
            send(
                title: "Critical Usage",
                body: "Claude Code usage at \(Int(pct.rounded()))%. Approaching limit."
            )
        } else if highUsageEnabled, pct >= 80,
                  now - defaults.double(forKey: Key.lastHigh.rawValue) > cooldown {
            defaults.set(now, forKey: Key.lastHigh.rawValue)
            send(
                title: "High Usage Warning",
                body: "Claude Code usage at \(Int(pct.rounded()))%. Pace yourself."
            )
        }

        evaluateWindowReset(data)
        evaluatePace(data)
    }

    private func evaluateWindowReset(_ data: WidgetData) {
        func check(name: String, new: TimeInterval?, priorKey: Key, priorUtilKey: Key, newUtil: Double) {
            let prior = defaults.object(forKey: priorKey.rawValue) as? TimeInterval
            let priorUtil = defaults.double(forKey: priorUtilKey.rawValue)

            if windowResetEnabled,
               shouldFireWindowReset(priorResetsAt: prior, newResetsAt: new, priorUtilization: priorUtil) {
                send(
                    title: "\(name) Window Reset",
                    body: "Used \(Int(priorUtil.rounded()))% of your \(name.lowercased()) limit last window. Quota refreshed."
                )
            }

            if let new {
                defaults.set(new, forKey: priorKey.rawValue)
                defaults.set(newUtil, forKey: priorUtilKey.rawValue)
            }
        }

        check(name: "5-Hour", new: data.fiveHourResetsAt, priorKey: .priorReset5h, priorUtilKey: .priorUtil5h, newUtil: data.fiveHourUtilization)
        check(name: "7-Day", new: data.sevenDayResetsAt, priorKey: .priorReset7d, priorUtilKey: .priorUtil7d, newUtil: data.sevenDayUtilization)
    }

    private func evaluatePace(_ data: WidgetData) {
        // Only track alerted flag while toggle is on so enabling mid-sustained-overpace still fires.
        guard paceEnabled else { return }

        func check(name: String, pace: Double?, alertedKey: Key) {
            let alerted = defaults.bool(forKey: alertedKey.rawValue)
            switch decidePace(pace: pace, alreadyAlerted: alerted) {
            case .fire:
                defaults.set(true, forKey: alertedKey.rawValue)
                if let pace {
                    send(
                        title: "\(name) Over Pace",
                        body: "Burning at \(String(format: "%.1fx", pace)) normal rate. Slow down to stay within limit."
                    )
                }
            case .clear:
                defaults.set(false, forKey: alertedKey.rawValue)
            case .unchanged:
                break
            }
        }

        check(name: "5-Hour", pace: data.fiveHourPace, alertedKey: .paceAlerted5h)
        check(name: "7-Day", pace: data.sevenDayPace, alertedKey: .paceAlerted7d)
    }

    // MARK: - Send

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private init() {}
}
#endif
