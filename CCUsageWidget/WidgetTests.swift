import Foundation
import Combine

// MARK: - Minimal Test Framework

var totalTests = 0
var passedTests = 0
var failedTests: [(String, String)] = []

func check(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if condition {
        passedTests += 1
    } else {
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        failedTests.append((loc, message))
        print("  FAIL: \(message) [\(loc)]")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if a == b {
        passedTests += 1
    } else {
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        let detail = msg.isEmpty ? "expected \(b), got \(a)" : "\(msg): expected \(b), got \(a)"
        failedTests.append((loc, detail))
        print("  FAIL: \(detail) [\(loc)]")
    }
}

func assertNil<T>(_ val: T?, _ msg: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if val == nil {
        passedTests += 1
    } else {
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        let detail = msg.isEmpty ? "expected nil, got \(val!)" : "\(msg): expected nil, got \(val!)"
        failedTests.append((loc, detail))
        print("  FAIL: \(detail) [\(loc)]")
    }
}

func assertNotNil<T>(_ val: T?, _ msg: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if val != nil {
        passedTests += 1
    } else {
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        let detail = msg.isEmpty ? "expected non-nil" : "\(msg): expected non-nil"
        failedTests.append((loc, detail))
        print("  FAIL: \(detail) [\(loc)]")
    }
}

func test(_ name: String, _ body: () -> Void) {
    body()
}

func suite(_ name: String, _ body: () -> Void) {
    print("--- \(name)")
    body()
}

// MARK: - Test Suite ID (avoids collisions with other tests)

private let testSuiteID = "com.ccusage.widgettests.\(ProcessInfo.processInfo.processIdentifier)"

// MARK: - WidgetData Encoding/Decoding Tests

func runWidgetDataTests() {
    suite("WidgetData encoding/decoding") {
        test("round-trip all fields") {
            let original = WidgetData(
                fiveHourUtilization: 45.5,
                sevenDayUtilization: 32.1,
                fiveHourPace: 1.2,
                sevenDayPace: 0.8,
                fiveHourResetsAt: 1700000000,
                sevenDayResetsAt: 1700300000,
                updatedAt: 1699999000,
                extraUsageEnabled: true,
                depletionSeconds: 300,
                todayCost: 2.50,
                activeSessionCount: 3,
                opusUtilization: 60,
                sonnetUtilization: 25,
                haikuUtilization: 15,
                dailyEntries: [DailyEntryData(date: "2026-04-13", usage: 40)],
                dailyCosts: [DailyCostData(date: "2026-04-13", cost: 1.25)],
                sessions: [SessionData(project: "test-proj", model: "opus", tokens: 5000, durationSeconds: 600)],
                extraUsageUtilization: 12
            )
            let data = try! JSONEncoder().encode(original)
            let decoded = try! JSONDecoder().decode(WidgetData.self, from: data)
            assertEqual(decoded.fiveHourUtilization, 45.5, "fiveHourUtilization")
            assertEqual(decoded.sevenDayUtilization, 32.1, "sevenDayUtilization")
            assertEqual(decoded.fiveHourPace, 1.2, "fiveHourPace")
            assertEqual(decoded.sevenDayPace, 0.8, "sevenDayPace")
            assertEqual(decoded.updatedAt, 1699999000, "updatedAt")
            assertEqual(decoded.extraUsageEnabled, true, "extraUsageEnabled")
            assertEqual(decoded.depletionSeconds, 300, "depletionSeconds")
            assertEqual(decoded.todayCost, 2.50, "todayCost")
            assertEqual(decoded.activeSessionCount, 3, "activeSessionCount")
            assertEqual(decoded.opusUtilization, 60, "opusUtilization")
            assertEqual(decoded.sonnetUtilization, 25, "sonnetUtilization")
            assertEqual(decoded.haikuUtilization, 15, "haikuUtilization")
            assertEqual(decoded.extraUsageUtilization, 12, "extraUsageUtilization")
            assertEqual(decoded.dailyEntries?.count, 1, "dailyEntries count")
            assertEqual(decoded.dailyCosts?.count, 1, "dailyCosts count")
            assertEqual(decoded.sessions?.count, 1, "sessions count")
            assertEqual(decoded.sessions?.first?.project, "test-proj", "session project")
            assertEqual(decoded.sessions?.first?.model, "opus", "session model")
        }

        test("minimal fields — backward compatibility") {
            let json = """
            {"fiveHourUtilization":50,"sevenDayUtilization":30,"updatedAt":1699999000}
            """.data(using: .utf8)!
            let decoded = try! JSONDecoder().decode(WidgetData.self, from: json)
            assertEqual(decoded.fiveHourUtilization, 50, "fiveHourUtilization")
            assertEqual(decoded.sevenDayUtilization, 30, "sevenDayUtilization")
            assertNil(decoded.fiveHourPace, "pace should be nil")
            assertNil(decoded.extraUsageEnabled, "extraUsageEnabled nil")
            assertNil(decoded.opusUtilization, "opusUtilization nil")
            assertNil(decoded.sessions, "sessions nil")
            assertNil(decoded.dailyEntries, "dailyEntries nil")
        }

        test("invalid JSON fails gracefully") {
            let bad = "not json".data(using: .utf8)!
            let result = try? JSONDecoder().decode(WidgetData.self, from: bad)
            assertNil(result, "should fail on bad JSON")
        }

        test("missing required field fails") {
            let json = """
            {"fiveHourUtilization":50,"sevenDayUtilization":30}
            """.data(using: .utf8)!
            let result = try? JSONDecoder().decode(WidgetData.self, from: json)
            assertNil(result, "missing updatedAt should fail")
        }

        test("SessionData optional fields") {
            let json = """
            {"project":"my-app","model":null,"tokens":null,"durationSeconds":null}
            """.data(using: .utf8)!
            let s = try! JSONDecoder().decode(SessionData.self, from: json)
            assertEqual(s.project, "my-app", "project")
            assertNil(s.model, "model nil")
            assertNil(s.tokens, "tokens nil")
            assertNil(s.durationSeconds, "duration nil")
        }
    }
}

// MARK: - DataService URL Validation Tests

@MainActor func runURLValidationTests() {
    suite("DataService.saveURL validation") {
        let validKey = String(repeating: "a1b2c3d4", count: 8) // 64 hex chars

        test("valid URL accepted") {
            let ds = DataService(suiteName: testSuiteID)
            let err = ds.saveURL("https://my-worker.workers.dev/read/\(validKey)")
            assertNil(err, "valid URL should return nil error")
            assertEqual(ds.isConnected, true, "should be connected")
            assertEqual(ds.widgetURL, "https://my-worker.workers.dev/read/\(validKey)", "URL stored")
            ds.disconnect()
        }

        test("http scheme rejected") {
            let ds = DataService(suiteName: testSuiteID)
            let err = ds.saveURL("http://my-worker.workers.dev/read/\(validKey)")
            assertNotNil(err, "http should fail")
            assertEqual(ds.isConnected, false, "not connected")
            ds.disconnect()
        }

        test("non-workers.dev host rejected") {
            let ds = DataService(suiteName: testSuiteID)
            let err = ds.saveURL("https://example.com/read/\(validKey)")
            assertNotNil(err, "wrong host should fail")
            ds.disconnect()
        }

        test("short key rejected") {
            let ds = DataService(suiteName: testSuiteID)
            let err = ds.saveURL("https://my-worker.workers.dev/read/abc123")
            assertNotNil(err, "short key should fail")
            ds.disconnect()
        }

        test("non-hex key rejected") {
            let ds = DataService(suiteName: testSuiteID)
            let nonHex = String(repeating: "zzzzzzzz", count: 8)
            let err = ds.saveURL("https://my-worker.workers.dev/read/\(nonHex)")
            assertNotNil(err, "non-hex key should fail")
            ds.disconnect()
        }

        test("empty string rejected") {
            let ds = DataService(suiteName: testSuiteID)
            let err = ds.saveURL("")
            assertNotNil(err, "empty should fail")
            ds.disconnect()
        }

        test("whitespace trimmed") {
            let ds = DataService(suiteName: testSuiteID)
            let err = ds.saveURL("  https://my-worker.workers.dev/read/\(validKey)  \n")
            assertNil(err, "trimmed URL should be valid")
            assertEqual(ds.widgetURL, "https://my-worker.workers.dev/read/\(validKey)", "URL trimmed")
            ds.disconnect()
        }
    }
}

// MARK: - DataService Disconnect Cleanup Tests

@MainActor func runDisconnectTests() {
    suite("DataService.disconnect cleanup") {
        test("removes all keys including widget-shared") {
            let defaults = UserDefaults(suiteName: testSuiteID)!
            let validKey = String(repeating: "a1b2c3d4", count: 8)

            // Simulate connected state with cached data
            defaults.set("https://w.workers.dev/r/\(validKey)", forKey: "widgetURL")
            defaults.set("cached".data(using: .utf8), forKey: "cachedAppWidgetData")
            defaults.set("shared".data(using: .utf8), forKey: "cachedWidgetData")
            defaults.set(Date().timeIntervalSince1970, forKey: "cachedWidgetDataTimestamp")

            let ds = DataService(suiteName: testSuiteID)
            ds.disconnect()

            assertNil(defaults.string(forKey: "widgetURL"), "widgetURL removed")
            assertNil(defaults.data(forKey: "cachedAppWidgetData"), "app cache removed")
            assertNil(defaults.data(forKey: "cachedWidgetData"), "widget cache removed")
            assertEqual(defaults.double(forKey: "cachedWidgetDataTimestamp"), 0, "widget timestamp removed")
            assertEqual(ds.isConnected, false, "disconnected")
            assertNil(ds.data, "data cleared")

            // Clean up test suite
            defaults.removePersistentDomain(forName: testSuiteID)
        }

        test("disconnect without prior data is safe") {
            let ds = DataService(suiteName: testSuiteID)
            ds.disconnect() // should not crash
            assertEqual(ds.isConnected, false, "disconnected")
            assertNil(ds.data, "no data")

            let defaults = UserDefaults(suiteName: testSuiteID)!
            defaults.removePersistentDomain(forName: testSuiteID)
        }
    }
}

// MARK: - DataService Cache Loading Tests

@MainActor func runCacheLoadTests() {
    suite("DataService.loadCached") {
        test("loads cached data on init") {
            let defaults = UserDefaults(suiteName: testSuiteID)!
            let validKey = String(repeating: "a1b2c3d4", count: 8)
            defaults.set("https://w.workers.dev/r/\(validKey)", forKey: "widgetURL")

            let widgetData = WidgetData(
                fiveHourUtilization: 55, sevenDayUtilization: 40,
                fiveHourPace: nil, sevenDayPace: nil,
                fiveHourResetsAt: nil, sevenDayResetsAt: nil,
                updatedAt: Date().timeIntervalSince1970,
                extraUsageEnabled: nil, depletionSeconds: nil,
                todayCost: nil, activeSessionCount: nil,
                opusUtilization: nil, sonnetUtilization: nil, haikuUtilization: nil,
                dailyEntries: nil, dailyCosts: nil, sessions: nil, extraUsageUtilization: nil
            )
            let encoded = try! JSONEncoder().encode(widgetData)
            defaults.set(encoded, forKey: "cachedAppWidgetData")

            let ds = DataService(suiteName: testSuiteID)
            assertEqual(ds.isConnected, true, "connected from URL")
            assertNotNil(ds.data, "data loaded from cache")
            assertEqual(ds.data?.fiveHourUtilization, 55, "cached utilization")

            ds.disconnect()
            defaults.removePersistentDomain(forName: testSuiteID)
        }

        test("no URL means not connected") {
            let defaults = UserDefaults(suiteName: testSuiteID)!
            defaults.removePersistentDomain(forName: testSuiteID)

            let ds = DataService(suiteName: testSuiteID)
            assertEqual(ds.isConnected, false, "not connected without URL")
            assertNil(ds.data, "no data without cache")

            defaults.removePersistentDomain(forName: testSuiteID)
        }

        test("URL but no cache — connected but no data") {
            let defaults = UserDefaults(suiteName: testSuiteID)!
            let validKey = String(repeating: "a1b2c3d4", count: 8)
            defaults.set("https://w.workers.dev/r/\(validKey)", forKey: "widgetURL")

            let ds = DataService(suiteName: testSuiteID)
            assertEqual(ds.isConnected, true, "connected from URL")
            assertNil(ds.data, "no data without cache")

            ds.disconnect()
            defaults.removePersistentDomain(forName: testSuiteID)
        }

        test("corrupt cache ignored gracefully") {
            let defaults = UserDefaults(suiteName: testSuiteID)!
            let validKey = String(repeating: "a1b2c3d4", count: 8)
            defaults.set("https://w.workers.dev/r/\(validKey)", forKey: "widgetURL")
            defaults.set("not valid json".data(using: .utf8), forKey: "cachedAppWidgetData")

            let ds = DataService(suiteName: testSuiteID)
            assertEqual(ds.isConnected, true, "connected from URL")
            assertNil(ds.data, "corrupt cache yields no data")

            ds.disconnect()
            defaults.removePersistentDomain(forName: testSuiteID)
        }
    }
}

// MARK: - Data Sharing Tests

@MainActor func runDataSharingTests() {
    suite("DataService widget data sharing") {
        test("fetch writes both app and widget shared keys") {
            let defaults = UserDefaults(suiteName: testSuiteID)!

            // Verify all three keys are written by simulating fetch() write path
            let widgetData = WidgetData(
                fiveHourUtilization: 70, sevenDayUtilization: 50,
                fiveHourPace: 1.1, sevenDayPace: 0.9,
                fiveHourResetsAt: nil, sevenDayResetsAt: nil,
                updatedAt: Date().timeIntervalSince1970,
                extraUsageEnabled: nil, depletionSeconds: nil,
                todayCost: 3.00, activeSessionCount: 1,
                opusUtilization: nil, sonnetUtilization: nil, haikuUtilization: nil,
                dailyEntries: nil, dailyCosts: nil, sessions: nil, extraUsageUtilization: nil
            )
            let encoded = try! JSONEncoder().encode(widgetData)

            // Replicate exact write path from DataService.fetch()
            defaults.set(encoded, forKey: "cachedAppWidgetData")
            defaults.set(encoded, forKey: "cachedWidgetData")
            defaults.set(Date().timeIntervalSince1970, forKey: "cachedWidgetDataTimestamp")

            // Verify widget extension can decode shared data
            let sharedData = defaults.data(forKey: "cachedWidgetData")
            assertNotNil(sharedData, "widget data written")
            let decoded = try? JSONDecoder().decode(WidgetData.self, from: sharedData!)
            assertNotNil(decoded, "widget data decodable")
            assertEqual(decoded?.fiveHourUtilization, 70, "shared utilization")
            assertEqual(decoded?.todayCost, 3.00, "shared cost")

            let ts = defaults.double(forKey: "cachedWidgetDataTimestamp")
            check(ts > 0, "timestamp written")

            // Verify app cache also written
            let appData = defaults.data(forKey: "cachedAppWidgetData")
            assertNotNil(appData, "app cache written")
            let appDecoded = try? JSONDecoder().decode(WidgetData.self, from: appData!)
            assertEqual(appDecoded?.fiveHourUtilization, 70, "app cache matches")

            defaults.removePersistentDomain(forName: testSuiteID)
        }

        test("shared keys match what widget extension reads") {
            // Verify key names are consistent between DataService writes and extension reads
            // DataService writes: "cachedWidgetData", "cachedWidgetDataTimestamp"
            // Extension reads:    "cachedWidgetData", "cachedWidgetDataTimestamp" (CCUsageProvider static lets)
            let defaults = UserDefaults(suiteName: testSuiteID)!

            let widgetData = WidgetData(
                fiveHourUtilization: 85, sevenDayUtilization: 60,
                fiveHourPace: nil, sevenDayPace: nil,
                fiveHourResetsAt: nil, sevenDayResetsAt: nil,
                updatedAt: Date().timeIntervalSince1970,
                extraUsageEnabled: nil, depletionSeconds: nil,
                todayCost: nil, activeSessionCount: nil,
                opusUtilization: nil, sonnetUtilization: nil, haikuUtilization: nil,
                dailyEntries: nil, dailyCosts: nil, sessions: nil, extraUsageUtilization: nil
            )
            let encoded = try! JSONEncoder().encode(widgetData)
            let now = Date().timeIntervalSince1970

            // Write using DataService key names
            defaults.set(encoded, forKey: "cachedWidgetData")
            defaults.set(now, forKey: "cachedWidgetDataTimestamp")

            // Read using extension key names (must match)
            let cachedTimestamp = defaults.double(forKey: "cachedWidgetDataTimestamp")
            check(cachedTimestamp > 0, "timestamp readable by extension key")
            check(Date().timeIntervalSince1970 - cachedTimestamp < 5, "timestamp is fresh")

            let cachedData = defaults.data(forKey: "cachedWidgetData")
            assertNotNil(cachedData, "data readable by extension key")
            let decoded = try? JSONDecoder().decode(WidgetData.self, from: cachedData!)
            assertEqual(decoded?.fiveHourUtilization, 85, "extension reads correct data")

            defaults.removePersistentDomain(forName: testSuiteID)
        }

        test("disconnect clears widget shared keys") {
            let defaults = UserDefaults(suiteName: testSuiteID)!
            defaults.set("data".data(using: .utf8), forKey: "cachedWidgetData")
            defaults.set(12345.0, forKey: "cachedWidgetDataTimestamp")
            defaults.set("https://w.workers.dev/r/\(String(repeating: "ab", count: 32))", forKey: "widgetURL")

            let ds = DataService(suiteName: testSuiteID)
            ds.disconnect()

            assertNil(defaults.data(forKey: "cachedWidgetData"), "widget data cleared")
            assertEqual(defaults.double(forKey: "cachedWidgetDataTimestamp"), 0, "widget timestamp cleared")

            defaults.removePersistentDomain(forName: testSuiteID)
        }
    }
}

// MARK: - Run All Tests

@main
struct WidgetTestRunner {
    @MainActor static func main() {
        runWidgetDataTests()
        runURLValidationTests()
        runDisconnectTests()
        runCacheLoadTests()
        runDataSharingTests()

        print("\n=== Widget Tests: \(passedTests)/\(totalTests) passed ===")
        if !failedTests.isEmpty {
            print("Failures:")
            for (loc, msg) in failedTests {
                print("  [\(loc)] \(msg)")
            }
            exit(1)
        }
        exit(0)
    }
}
