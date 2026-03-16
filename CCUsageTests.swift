import Foundation

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

// MARK: - Token Parsing Tests

func runParseTokenTests() {
    suite("parseToken") {
        test("valid credentials") {
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-test-123","refreshToken":"rt-456"}}
            """.data(using: .utf8)!
            assertEqual(parseToken(from: json), "sk-ant-test-123")
        }

        test("missing oauth key") {
            let json = """
            {"someOtherKey":{"accessToken":"sk-ant-test"}}
            """.data(using: .utf8)!
            assertNil(parseToken(from: json), "missing claudeAiOauth")
        }

        test("missing access token") {
            let json = """
            {"claudeAiOauth":{"refreshToken":"rt-456"}}
            """.data(using: .utf8)!
            assertNil(parseToken(from: json), "missing accessToken")
        }

        test("empty access token") {
            let json = """
            {"claudeAiOauth":{"accessToken":""}}
            """.data(using: .utf8)!
            assertNil(parseToken(from: json), "empty string token")
        }

        test("invalid JSON") {
            let data = "not json at all".data(using: .utf8)!
            assertNil(parseToken(from: data), "invalid JSON")
        }

        test("empty data") {
            assertNil(parseToken(from: Data()), "empty data")
        }

        test("null access token") {
            let json = """
            {"claudeAiOauth":{"accessToken":null}}
            """.data(using: .utf8)!
            assertNil(parseToken(from: json), "null token")
        }

        test("extra fields ignored") {
            let json = """
            {"claudeAiOauth":{"accessToken":"tok-ok","expiresAt":99999},"other":"data"}
            """.data(using: .utf8)!
            assertEqual(parseToken(from: json), "tok-ok")
        }

        test("HTML response") {
            let data = "<html><body>Unauthorized</body></html>".data(using: .utf8)!
            assertNil(parseToken(from: data), "HTML response")
        }

        test("numeric access token type rejected") {
            let json = """
            {"claudeAiOauth":{"accessToken":12345}}
            """.data(using: .utf8)!
            assertNil(parseToken(from: json), "numeric token")
        }
    }
}

// MARK: - Usage Parsing Tests

func runParseUsageTests() {
    suite("parseUsage") {
        test("valid response with remaining and resets_at") {
            let json = """
            {
                "five_hour": {"utilization": 42.0, "remaining": 58.0, "resets_at": "2026-03-16T16:59:59.693280+00:00"},
                "seven_day": {"utilization": 18.5, "remaining": 81.5, "resets_at": "2026-03-20T14:00:00.693302+00:00"}
            }
            """.data(using: .utf8)!
            let u = parseUsage(from: json)
            assertNotNil(u, "valid response")
            if let u = u {
                assertEqual(u.fiveHour.utilization, 42.0, "5h utilization")
                assertEqual(u.fiveHour.remaining, 58.0, "5h remaining")
                assertNotNil(u.fiveHour.resetsAt, "5h resetsAt parsed")
                assertEqual(u.sevenDay.utilization, 18.5, "7d utilization")
                assertEqual(u.sevenDay.remaining, 81.5, "7d remaining")
                assertNotNil(u.sevenDay.resetsAt, "7d resetsAt parsed")
            }
        }

        test("integer utilization") {
            let json = """
            {"five_hour": {"utilization": 0}, "seven_day": {"utilization": 100}}
            """.data(using: .utf8)!
            let u = parseUsage(from: json)
            assertNotNil(u, "integer values")
            if let u = u {
                assertEqual(u.fiveHour.utilization, 0.0, "zero")
                assertEqual(u.sevenDay.utilization, 100.0, "hundred")
            }
        }

        test("missing five_hour") {
            let json = """
            {"seven_day": {"utilization": 18.5}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "missing five_hour")
        }

        test("missing seven_day") {
            let json = """
            {"five_hour": {"utilization": 42.0}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "missing seven_day")
        }

        test("missing utilization field") {
            let json = """
            {"five_hour": {"remaining": 58.0}, "seven_day": {"utilization": 18.5}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "missing utilization")
        }

        test("remaining and resetsAt are optional") {
            let json = """
            {"five_hour": {"utilization": 42.0}, "seven_day": {"utilization": 18.5}}
            """.data(using: .utf8)!
            let u = parseUsage(from: json)
            assertNotNil(u, "no remaining/resetsAt")
            if let u = u {
                assertNil(u.fiveHour.remaining, "5h remaining nil")
                assertNil(u.fiveHour.resetsAt, "5h resetsAt nil")
                assertNil(u.sevenDay.remaining, "7d remaining nil")
                assertNil(u.sevenDay.resetsAt, "7d resetsAt nil")
            }
        }

        test("HTML response") {
            let data = "<html>Error</html>".data(using: .utf8)!
            assertNil(parseUsage(from: data), "HTML")
        }

        test("empty data") {
            assertNil(parseUsage(from: Data()), "empty")
        }

        test("utilization as string rejected") {
            let json = """
            {"five_hour": {"utilization": "42.0"}, "seven_day": {"utilization": 18.5}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "string utilization")
        }

        test("extra fields ignored") {
            let json = """
            {
                "five_hour": {"utilization": 5.0, "limit": 1000},
                "seven_day": {"utilization": 10.0, "limit": 5000},
                "daily": {"utilization": 1.0}
            }
            """.data(using: .utf8)!
            let u = parseUsage(from: json)
            assertNotNil(u, "extra fields")
            if let u = u {
                assertEqual(u.fiveHour.utilization, 5.0)
                assertEqual(u.sevenDay.utilization, 10.0)
            }
        }

        test("error response") {
            let json = """
            {"error": {"type": "invalid_request", "message": "Bad request"}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "error response")
        }
    }
}

// MARK: - Format Value Tests

func runFormatValueTests() {
    suite("formatValue") {
        test("whole numbers") {
            assertEqual(formatValue(0.0), "0", "zero")
            assertEqual(formatValue(42.0), "42", "42")
            assertEqual(formatValue(100.0), "100", "100")
            assertEqual(formatValue(99.0), "99", "99")
        }

        test("decimal values") {
            assertEqual(formatValue(42.5), "42.5", "42.5")
            assertEqual(formatValue(0.1), "0.1", "0.1")
            assertEqual(formatValue(6.5), "6.5", "6.5")
        }

        test("rounding") {
            assertEqual(formatValue(42.56), "42.6", "42.56 rounds to 42.6")
        }
    }
}

// MARK: - Indicator Tests

func runIndicatorTests() {
    suite("usageIndicator") {
        let green = "\u{1F7E2}"
        let yellow = "\u{1F7E1}"
        let red = "\u{1F534}"

        test("green range (0-49.9)") {
            assertEqual(usageIndicator(for: 0), green, "0%")
            assertEqual(usageIndicator(for: 25), green, "25%")
            assertEqual(usageIndicator(for: 49.9), green, "49.9%")
        }

        test("yellow range (50-79.9)") {
            assertEqual(usageIndicator(for: 50), yellow, "50%")
            assertEqual(usageIndicator(for: 65), yellow, "65%")
            assertEqual(usageIndicator(for: 79.9), yellow, "79.9%")
        }

        test("red range (80+)") {
            assertEqual(usageIndicator(for: 80), red, "80%")
            assertEqual(usageIndicator(for: 95), red, "95%")
            assertEqual(usageIndicator(for: 100), red, "100%")
        }

        test("exact boundaries") {
            assertEqual(usageIndicator(for: 50.0), yellow, "exactly 50")
            assertEqual(usageIndicator(for: 80.0), red, "exactly 80")
        }
    }
}

// MARK: - Reset Time Format Tests

func runFormatResetTimeTests() {
    suite("formatResetTime") {
        let now = Date(timeIntervalSince1970: 1000000)

        test("nil date returns empty") {
            assertEqual(formatResetTime(nil, relativeTo: now), "", "nil")
        }

        test("past date returns resetting") {
            let past = now.addingTimeInterval(-60)
            assertEqual(formatResetTime(past, relativeTo: now), " (resetting...)", "past")
        }

        test("minutes only") {
            let future = now.addingTimeInterval(45 * 60)
            assertEqual(formatResetTime(future, relativeTo: now), " (resets in 45m)", "45m")
        }

        test("hours and minutes") {
            let future = now.addingTimeInterval(2 * 3600 + 30 * 60)
            assertEqual(formatResetTime(future, relativeTo: now), " (resets in 2h 30m)", "2h30m")
        }

        test("exact hours") {
            let future = now.addingTimeInterval(3 * 3600)
            assertEqual(formatResetTime(future, relativeTo: now), " (resets in 3h)", "3h")
        }

        test("days and hours") {
            let future = now.addingTimeInterval(3 * 86400 + 5 * 3600)
            assertEqual(formatResetTime(future, relativeTo: now), " (resets in 3d 5h)", "3d5h")
        }

        test("exact days") {
            let future = now.addingTimeInterval(2 * 86400)
            assertEqual(formatResetTime(future, relativeTo: now), " (resets in 2d)", "2d")
        }

        test("just under a minute") {
            let future = now.addingTimeInterval(30)
            assertEqual(formatResetTime(future, relativeTo: now), " (resets in 0m)", "30s")
        }
    }
}

// MARK: - Status Line Format Tests

func runFormatStatusLineTests() {
    suite("formatStatusLine") {
        let green = "\u{1F7E2}"
        let yellow = "\u{1F7E1}"
        let red = "\u{1F534}"

        test("low usage shows green") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 9.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 18.0, remaining: nil, resetsAt: nil)
            )
            let line = formatStatusLine(u)
            check(line.contains("5h:9%"), "contains 5h:9%")
            check(line.contains("7d:18%"), "contains 7d:18%")
            check(line.contains(green), "green indicator")
        }

        test("high 5h drives indicator red") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 85.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u).contains(red), "red from 5h=85")
        }

        test("high 7d drives indicator red") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 10.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 90.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u).contains(red), "red from 7d=90")
        }

        test("decimal values") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 6.5, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 18.3, remaining: nil, resetsAt: nil)
            )
            let line = formatStatusLine(u)
            check(line.contains("5h:6.5%"), "decimal 5h")
            check(line.contains("7d:18.3%"), "decimal 7d")
        }

        test("zero usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 0.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 0.0, remaining: nil, resetsAt: nil)
            )
            let line = formatStatusLine(u)
            check(line.contains("5h:0%"), "zero 5h")
            check(line.contains("7d:0%"), "zero 7d")
            check(line.contains(green), "green at zero")
        }

        test("full usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil)
            )
            let line = formatStatusLine(u)
            check(line.contains("5h:100%"), "100 5h")
            check(line.contains("7d:100%"), "100 7d")
            check(line.contains(red), "red at 100")
        }

        test("yellow threshold") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 55.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 30.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u).contains(yellow), "yellow at 55")
        }
    }
}

// MARK: - Version Comparison Tests

func runVersionComparisonTests() {
    suite("isNewerVersion") {
        test("newer patch") {
            check(isNewerVersion("1.0.1", than: "1.0.0"), "1.0.1 > 1.0.0")
        }

        test("newer minor") {
            check(isNewerVersion("1.1.0", than: "1.0.0"), "1.1.0 > 1.0.0")
        }

        test("newer major") {
            check(isNewerVersion("2.0.0", than: "1.0.0"), "2.0.0 > 1.0.0")
        }

        test("same version") {
            check(!isNewerVersion("1.0.0", than: "1.0.0"), "equal")
        }

        test("older version") {
            check(!isNewerVersion("1.0.0", than: "1.0.1"), "older")
        }

        test("v prefix stripped") {
            check(isNewerVersion("v1.1.0", than: "1.0.0"), "v prefix remote")
            check(isNewerVersion("1.1.0", than: "v1.0.0"), "v prefix local")
            check(isNewerVersion("v2.0.0", than: "v1.0.0"), "v prefix both")
        }

        test("different segment counts") {
            check(isNewerVersion("1.0.1", than: "1.0"), "3 vs 2 segments")
            check(!isNewerVersion("1.0", than: "1.0.0"), "2 vs 3 equal")
            check(isNewerVersion("1.1", than: "1.0.9"), "minor bump")
        }

        test("dev version upgradable") {
            check(isNewerVersion("1.0.0", than: "0.0.0-dev"), "any release > dev")
        }

        test("same numeric, release > pre-release") {
            check(isNewerVersion("1.0.0", than: "1.0.0-dev"), "release > dev same version")
            check(!isNewerVersion("1.0.0-dev", than: "1.0.0"), "dev < release same version")
        }

        test("pre-release suffix preserved in segments") {
            check(isNewerVersion("0.0.1", than: "0.0.0-dev"), "0.0.1 > 0.0.0-dev")
            check(isNewerVersion("1.0.0", than: "1.0.0-beta"), "release > beta")
        }
    }
}

// MARK: - Utilization Range Validation Tests

func runUtilizationRangeTests() {
    suite("parseUsage utilization range") {
        test("negative utilization rejected") {
            let json = """
            {"five_hour": {"utilization": -1.0}, "seven_day": {"utilization": 50.0}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "negative 5h")
        }

        test("negative seven_day utilization rejected") {
            let json = """
            {"five_hour": {"utilization": 50.0}, "seven_day": {"utilization": -10.0}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "negative 7d")
        }

        test("utilization over 100 rejected") {
            let json = """
            {"five_hour": {"utilization": 150.0}, "seven_day": {"utilization": 50.0}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "over 100 5h")
        }

        test("seven_day utilization over 100 rejected") {
            let json = """
            {"five_hour": {"utilization": 50.0}, "seven_day": {"utilization": 101.0}}
            """.data(using: .utf8)!
            assertNil(parseUsage(from: json), "over 100 7d")
        }

        test("boundary values accepted") {
            let json = """
            {"five_hour": {"utilization": 0.0}, "seven_day": {"utilization": 100.0}}
            """.data(using: .utf8)!
            let u = parseUsage(from: json)
            assertNotNil(u, "0 and 100 accepted")
            if let u = u {
                assertEqual(u.fiveHour.utilization, 0.0, "0 accepted")
                assertEqual(u.sevenDay.utilization, 100.0, "100 accepted")
            }
        }
    }
}

// MARK: - Retry-After Clamping Tests

func runClampRetryAfterTests() {
    suite("clampRetryAfter") {
        test("normal value passes through") {
            assertEqual(clampRetryAfter(300), 300, "5 min")
            assertEqual(clampRetryAfter(3600), 3600, "1 hour")
        }

        test("value below minimum clamped up") {
            assertEqual(clampRetryAfter(1), 60, "1s -> 60s")
            assertEqual(clampRetryAfter(0), 60, "0 -> 60s")
            assertEqual(clampRetryAfter(-100), 60, "negative -> 60s")
        }

        test("value above maximum clamped down") {
            assertEqual(clampRetryAfter(999999), 86400, "huge -> 1 day")
            assertEqual(clampRetryAfter(100000), 86400, "100k -> 1 day")
        }

        test("boundary values") {
            assertEqual(clampRetryAfter(60), 60, "exactly min")
            assertEqual(clampRetryAfter(86400), 86400, "exactly max")
        }
    }
}

// MARK: - Download URL Validation Tests

func runDownloadURLValidationTests() {
    suite("isValidDownloadURL") {
        test("valid GitHub URLs accepted") {
            check(isValidDownloadURL("https://github.com/user/repo/releases/download/v1.0/app.zip"), "github.com")
            check(isValidDownloadURL("https://objects.githubusercontent.com/some/path/app.zip"), "githubusercontent.com")
        }

        test("HTTP rejected") {
            check(!isValidDownloadURL("http://github.com/user/repo/releases/download/v1.0/app.zip"), "http rejected")
        }

        test("other domains rejected") {
            check(!isValidDownloadURL("https://evil.com/malware.zip"), "evil.com rejected")
            check(!isValidDownloadURL("https://github.com.evil.com/fake.zip"), "subdomain attack rejected")
        }

        test("non-URL strings rejected") {
            check(!isValidDownloadURL("not a url"), "plain text rejected")
            check(!isValidDownloadURL(""), "empty string rejected")
            check(!isValidDownloadURL("file:///etc/passwd"), "file scheme rejected")
        }
    }
}

// MARK: - Release Info Parsing Tests

func runParseReleaseInfoTests() {
    suite("parseReleaseInfo") {
        test("valid release with .zip asset") {
            let json = """
            {
                "tag_name": "v2.0.0",
                "assets": [
                    {"name": "CCUsage.zip", "browser_download_url": "https://github.com/user/repo/releases/download/v2.0.0/CCUsage.zip"}
                ]
            }
            """.data(using: .utf8)!
            let info = parseReleaseInfo(from: json, currentVersion: "1.0.0")
            assertNotNil(info, "should return update info")
            if let info = info {
                assertEqual(info.tagName, "v2.0.0", "tag name")
                assertEqual(info.downloadURL, "https://github.com/user/repo/releases/download/v2.0.0/CCUsage.zip", "download URL")
            }
        }

        test("newer version with no .zip asset") {
            let json = """
            {
                "tag_name": "v2.0.0",
                "assets": [
                    {"name": "CCUsage.tar.gz", "browser_download_url": "https://github.com/user/repo/releases/download/v2.0.0/CCUsage.tar.gz"}
                ]
            }
            """.data(using: .utf8)!
            let info = parseReleaseInfo(from: json, currentVersion: "1.0.0")
            assertNotNil(info, "should return update info")
            if let info = info {
                assertEqual(info.tagName, "v2.0.0", "tag name")
                assertNil(info.downloadURL, "no zip means nil download URL")
            }
        }

        test("same version returns nil") {
            let json = """
            {"tag_name": "v1.0.0", "assets": []}
            """.data(using: .utf8)!
            assertNil(parseReleaseInfo(from: json, currentVersion: "1.0.0"), "same version")
        }

        test("older version returns nil") {
            let json = """
            {"tag_name": "v0.9.0", "assets": []}
            """.data(using: .utf8)!
            assertNil(parseReleaseInfo(from: json, currentVersion: "1.0.0"), "older version")
        }

        test("invalid download URL domain") {
            let json = """
            {
                "tag_name": "v2.0.0",
                "assets": [
                    {"name": "CCUsage.zip", "browser_download_url": "https://evil.com/CCUsage.zip"}
                ]
            }
            """.data(using: .utf8)!
            let info = parseReleaseInfo(from: json, currentVersion: "1.0.0")
            assertNotNil(info, "should return update info")
            if let info = info {
                assertEqual(info.tagName, "v2.0.0", "tag name")
                assertNil(info.downloadURL, "invalid domain means nil download URL")
            }
        }

        test("malformed JSON returns nil") {
            let data = "not json".data(using: .utf8)!
            assertNil(parseReleaseInfo(from: data, currentVersion: "1.0.0"), "malformed JSON")
        }

        test("missing tag_name returns nil") {
            let json = """
            {"assets": [{"name": "CCUsage.zip", "browser_download_url": "https://github.com/u/r/CCUsage.zip"}]}
            """.data(using: .utf8)!
            assertNil(parseReleaseInfo(from: json, currentVersion: "1.0.0"), "missing tag_name")
        }

        test("multiple assets picks .zip") {
            let json = """
            {
                "tag_name": "v3.0.0",
                "assets": [
                    {"name": "CCUsage.tar.gz", "browser_download_url": "https://github.com/u/r/CCUsage.tar.gz"},
                    {"name": "CCUsage.zip", "browser_download_url": "https://github.com/u/r/releases/download/v3.0.0/CCUsage.zip"},
                    {"name": "checksums.txt", "browser_download_url": "https://github.com/u/r/checksums.txt"}
                ]
            }
            """.data(using: .utf8)!
            let info = parseReleaseInfo(from: json, currentVersion: "1.0.0")
            assertNotNil(info, "should return update info")
            if let info = info {
                assertEqual(info.tagName, "v3.0.0", "tag name")
                assertEqual(info.downloadURL, "https://github.com/u/r/releases/download/v3.0.0/CCUsage.zip", "picks .zip asset")
            }
        }

        test("no assets key") {
            let json = """
            {"tag_name": "v2.0.0"}
            """.data(using: .utf8)!
            let info = parseReleaseInfo(from: json, currentVersion: "1.0.0")
            assertNotNil(info, "should return update info without assets")
            if let info = info {
                assertEqual(info.tagName, "v2.0.0", "tag name")
                assertNil(info.downloadURL, "no assets means nil download URL")
            }
        }

        test("empty assets array") {
            let json = """
            {"tag_name": "v2.0.0", "assets": []}
            """.data(using: .utf8)!
            let info = parseReleaseInfo(from: json, currentVersion: "1.0.0")
            assertNotNil(info, "should return update info")
            if let info = info {
                assertNil(info.downloadURL, "empty assets means nil download URL")
            }
        }

        test("empty data returns nil") {
            assertNil(parseReleaseInfo(from: Data(), currentVersion: "1.0.0"), "empty data")
        }

        test("dev version detects release update") {
            let json = """
            {"tag_name": "v1.0.0", "assets": []}
            """.data(using: .utf8)!
            let info = parseReleaseInfo(from: json, currentVersion: "0.0.0-dev")
            assertNotNil(info, "dev should see 1.0.0 as update")
        }
    }
}

// MARK: - Test Runner

func runAllTests() {
    runParseTokenTests()
    runParseUsageTests()
    runFormatValueTests()
    runIndicatorTests()
    runFormatResetTimeTests()
    runFormatStatusLineTests()
    runVersionComparisonTests()
    runUtilizationRangeTests()
    runClampRetryAfterTests()
    runDownloadURLValidationTests()
    runParseReleaseInfoTests()

    print("\n=== Results: \(passedTests)/\(totalTests) passed ===")
    if !failedTests.isEmpty {
        print("\nFailed:")
        for (loc, msg) in failedTests {
            print("  - [\(loc)] \(msg)")
        }
        exit(1)
    } else {
        print("All tests passed!")
        exit(0)
    }
}
