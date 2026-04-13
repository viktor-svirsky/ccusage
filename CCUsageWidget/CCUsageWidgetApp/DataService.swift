import Foundation
#if !TESTING
import WidgetKit
#else
import Combine
#endif

private let appGroupID = "group.com.viktorsvirsky.ccusage"
private let widgetURLKey = "widgetURL"
private let cachedDataKey = "cachedAppWidgetData"
private let widgetCachedDataKey = "cachedWidgetData"
private let widgetCachedTimestampKey = "cachedWidgetDataTimestamp"
private let fetchInterval: TimeInterval = 120

@MainActor
class DataService: ObservableObject {
    @Published var data: WidgetData?
    @Published var isConnected: Bool = false

    private var timer: Timer?
    private let defaults: UserDefaults?

    init() {
        self.defaults = UserDefaults(suiteName: appGroupID)
        loadCached()
    }

    #if TESTING
    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName)
        loadCached()
    }
    #endif

    // MARK: - Connection

    var widgetURL: String? {
        defaults?.string(forKey: widgetURLKey)
    }

    func saveURL(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "https",
              url.host?.hasSuffix(".workers.dev") == true,
              let key = url.path.split(separator: "/").last,
              key.count == 64,
              key.allSatisfy({ $0.isHexDigit }) else {
            return "Invalid widget URL"
        }
        defaults?.set(trimmed, forKey: widgetURLKey)
        #if !TESTING
        KeychainHelper.save(key: "widgetURL", value: trimmed)
        #endif
        isConnected = true
        #if !TESTING
        WidgetCenter.shared.reloadAllTimelines()
        Task { await fetch() }
        #endif
        return nil
    }

    func disconnect() {
        stop()
        defaults?.removeObject(forKey: widgetURLKey)
        defaults?.removeObject(forKey: cachedDataKey)
        defaults?.removeObject(forKey: widgetCachedDataKey)
        defaults?.removeObject(forKey: widgetCachedTimestampKey)
        #if !TESTING
        KeychainHelper.delete(key: "widgetURL")
        #endif
        data = nil
        isConnected = false
        #if !TESTING
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        Task { await fetch() }
        timer = Timer.scheduledTimer(withTimeInterval: fetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetch()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Fetch

    func fetch() async {
        guard let urlString = defaults?.string(forKey: widgetURLKey),
              let url = URL(string: urlString) else {
            isConnected = false
            return
        }

        do {
            let (responseData, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(WidgetData.self, from: responseData)
            self.data = decoded
            self.isConnected = true
            defaults?.set(responseData, forKey: cachedDataKey)
            // Share data with widget extension so it doesn't need network access
            defaults?.set(responseData, forKey: widgetCachedDataKey)
            defaults?.set(Date().timeIntervalSince1970, forKey: widgetCachedTimestampKey)
            #if !TESTING
            WidgetCenter.shared.reloadAllTimelines()
            NotificationService.shared.evaluate(decoded)
            #endif
        } catch {
            // Keep existing data on failure
        }
    }

    // MARK: - Cache

    private func loadCached() {
        let hasURL = defaults?.string(forKey: widgetURLKey) != nil
        #if !TESTING
        isConnected = hasURL || KeychainHelper.load(key: "widgetURL") != nil
        #else
        isConnected = hasURL
        #endif
        guard let cachedData = defaults?.data(forKey: cachedDataKey),
              let cached = try? JSONDecoder().decode(WidgetData.self, from: cachedData) else { return }
        data = cached
    }
}
