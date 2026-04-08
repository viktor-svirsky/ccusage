import Foundation
import WidgetKit

private let appGroupID = "group.com.viktorsvirsky.ccusage"
private let widgetURLKey = "widgetURL"
private let cachedDataKey = "cachedAppWidgetData"
private let fetchInterval: TimeInterval = 120

@MainActor
class DataService: ObservableObject {
    @Published var data: WidgetData?
    @Published var isConnected: Bool = false

    private var timer: Timer?
    private let defaults = UserDefaults(suiteName: appGroupID)

    init() {
        loadCached()
    }

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
        isConnected = true
        WidgetCenter.shared.reloadAllTimelines()
        Task { await fetch() }
        return nil
    }

    func disconnect() {
        stop()
        defaults?.removeObject(forKey: widgetURLKey)
        defaults?.removeObject(forKey: cachedDataKey)
        data = nil
        isConnected = false
        WidgetCenter.shared.reloadAllTimelines()
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
            NotificationService.shared.evaluate(decoded)
        } catch {
            // Keep existing data on failure
        }
    }

    // MARK: - Cache

    private func loadCached() {
        isConnected = defaults?.string(forKey: widgetURLKey) != nil
        guard let cachedData = defaults?.data(forKey: cachedDataKey),
              let cached = try? JSONDecoder().decode(WidgetData.self, from: cachedData) else { return }
        data = cached
    }
}
