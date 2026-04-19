import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight Sentry reporter for the iOS widget + companion app. Mirrors the Mac app's
/// HTTP-only `/store/` approach (no SDK, no dependencies). Silent on failure — reporting
/// problems must never block the user-facing code path.
enum WidgetSentry {
    // Same DSN as the Mac app. The scope here is the ccusage Sentry project; platform tag
    // (ios-widget) separates widget events from Mac events in the issue stream.
    private static let sentryKey = "e775413587228219897ba908e29d5901"
    private static let sentryProjectId = "4511105650720769"
    private static let sentryHost = "o4510977201995776.ingest.us.sentry.io"

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var cachedVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    private static var environment: String {
        #if PRODUCTION
        return "production"
        #else
        return "development"
        #endif
    }

    /// Fire a Sentry event for a widget-side failure.
    ///
    /// - Parameters:
    ///   - type: short camelcase identifier grouped in Sentry (e.g. "WidgetFetchTimeout")
    ///   - message: human-readable one-liner
    ///   - context: free-form string pairs attached as `extra`
    static func capture(type: String, message: String, context: [String: String] = [:]) {
        #if TESTING
        // Tests must not hit the network. Keep the pure-parsing surface; drop the POST.
        _ = (type, message, context)
        return
        #else
        let urlString = "https://\(sentryHost)/api/\(sentryProjectId)/store/?sentry_version=7&sentry_key=\(sentryKey)"
        guard let url = URL(string: urlString) else { return }
        let version = cachedVersion
        let eventId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var event: [String: Any] = [
            "event_id": eventId,
            "timestamp": iso8601.string(from: Date()),
            "level": "error",
            "platform": "cocoa",
            "logger": "ccusage-widget",
            "release": "ccusage@\(version)",
            "environment": environment,
            "tags": [
                "app.version": version,
                "component": "ios-widget",
            ],
            "exception": ["values": [["type": type, "value": message]]],
        ]
        if !context.isEmpty {
            event["extra"] = context
        }
        guard let body = try? JSONSerialization.data(withJSONObject: event) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ccusage-widget/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        #endif
    }
}
