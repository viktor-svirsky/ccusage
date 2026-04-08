import Foundation
import UserNotifications

class NotificationService {
    static let shared = NotificationService()

    private let defaults = UserDefaults.standard
    private let cooldown: TimeInterval = 1800 // 30 minutes

    // MARK: - Toggle Keys

    private enum Key: String {
        case highUsage = "notif_highUsage"
        case critical = "notif_critical"
        case depletion = "notif_depletion"
        case lastHigh = "notif_lastHigh"
        case lastCritical = "notif_lastCritical"
        case lastDepletion = "notif_lastDepletion"
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
