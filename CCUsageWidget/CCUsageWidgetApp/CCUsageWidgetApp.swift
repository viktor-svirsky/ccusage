import SwiftUI

@main
struct CCUsageWidgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Buffers the system-provided completion handler until the matching URLSession's delegate
/// finishes processing events. Invoking the handler immediately (as the previous implementation
/// did) lets iOS suspend the app before the download delegate persists data and reloads the
/// widget timeline, so background refreshes could be dropped on the floor.
enum BackgroundSessionHandlerStore {
    private static let lock = NSLock()
    private static var handlers: [String: () -> Void] = [:]

    static func store(_ handler: @escaping () -> Void, for identifier: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[identifier] = handler
    }

    static func take(for identifier: String) -> (() -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return handlers.removeValue(forKey: identifier)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Stash the handler. The DataService's delegate will invoke it from
        // `urlSessionDidFinishEvents(forBackgroundURLSession:)` once downloads are persisted.
        BackgroundSessionHandlerStore.store(completionHandler, for: identifier)
    }
}
