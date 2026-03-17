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

// MARK: - Refresh Token Parsing Tests

func runParseRefreshTokenTests() {
    suite("parseRefreshToken") {
        test("valid credentials") {
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-test-123","refreshToken":"rt-456"}}
            """.data(using: .utf8)!
            assertEqual(parseRefreshToken(from: json), "rt-456")
        }

        test("missing refresh token") {
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-test-123"}}
            """.data(using: .utf8)!
            assertNil(parseRefreshToken(from: json), "missing refreshToken")
        }

        test("empty refresh token") {
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-test","refreshToken":""}}
            """.data(using: .utf8)!
            assertNil(parseRefreshToken(from: json), "empty refreshToken")
        }

        test("invalid JSON") {
            let data = "not json".data(using: .utf8)!
            assertNil(parseRefreshToken(from: data), "invalid JSON")
        }
    }
}

// MARK: - Expires At Parsing Tests

func runParseExpiresAtTests() {
    suite("parseExpiresAt") {
        test("valid expiresAt") {
            let json = """
            {"claudeAiOauth":{"accessToken":"tok","refreshToken":"rt","expiresAt":1700000000000}}
            """.data(using: .utf8)!
            let date = parseExpiresAt(from: json)
            assertNotNil(date, "valid expiresAt")
            if let date = date {
                assertEqual(Int(date.timeIntervalSince1970), 1700000000, "correct timestamp")
            }
        }

        test("missing expiresAt") {
            let json = """
            {"claudeAiOauth":{"accessToken":"tok","refreshToken":"rt"}}
            """.data(using: .utf8)!
            assertNil(parseExpiresAt(from: json), "missing expiresAt")
        }

        test("missing oauth key") {
            let json = """
            {"someOther":{"expiresAt":1700000000000}}
            """.data(using: .utf8)!
            assertNil(parseExpiresAt(from: json), "missing claudeAiOauth")
        }

        test("null expiresAt") {
            let json = """
            {"claudeAiOauth":{"accessToken":"tok","expiresAt":null}}
            """.data(using: .utf8)!
            assertNil(parseExpiresAt(from: json), "null expiresAt")
        }

        test("string expiresAt rejected") {
            let json = """
            {"claudeAiOauth":{"accessToken":"tok","expiresAt":"1700000000000"}}
            """.data(using: .utf8)!
            assertNil(parseExpiresAt(from: json), "string expiresAt")
        }

        test("invalid JSON") {
            let data = "not json".data(using: .utf8)!
            assertNil(parseExpiresAt(from: data), "invalid JSON")
        }

        test("empty data") {
            assertNil(parseExpiresAt(from: Data()), "empty data")
        }

        test("zero expiresAt") {
            let json = """
            {"claudeAiOauth":{"accessToken":"tok","expiresAt":0}}
            """.data(using: .utf8)!
            let date = parseExpiresAt(from: json)
            assertNotNil(date, "zero expiresAt")
            if let date = date {
                assertEqual(Int(date.timeIntervalSince1970), 0, "epoch")
            }
        }

        test("floating-point expiresAt") {
            let json = """
            {"claudeAiOauth":{"accessToken":"tok","expiresAt":1700000000000.0}}
            """.data(using: .utf8)!
            let date = parseExpiresAt(from: json)
            assertNotNil(date, "float expiresAt")
            if let date = date {
                assertEqual(Int(date.timeIntervalSince1970), 1700000000, "correct timestamp from float")
            }
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
        test("compact format h5/d7") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 9.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 18.0, remaining: nil, resetsAt: nil)
            )
            let line = formatStatusLine(u)
            check(line == "9/18", "compact format 9/18")
        }

        test("high usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 85.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 90.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "85/90", "compact format 85/90")
        }

        test("decimal values") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 6.5, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 18.3, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "6.5/18.3", "compact format 6.5/18.3")
        }

        test("zero usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 0.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 0.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "0/0", "compact format 0/0")
        }

        test("full usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "100/100", "compact format 100/100")
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

// MARK: - Fetch Schedule Tests

func runFetchScheduleTests() {
    suite("FetchSchedule") {
        test("initial state") {
            let s = FetchSchedule()
            assertEqual(s.interval, defaultFetchInterval, "default interval")
            check(!s.isRateLimited, "not rate limited initially")
        }

        test("onRateLimit sets reduced interval and flags rate limited") {
            var s = FetchSchedule()
            s.onRateLimit(retryAfter: 30)  // below minimum, should clamp to 60
            assertEqual(s.interval, 60.0, "clamped to minimum 60s")
            check(s.isRateLimited, "flagged as rate limited")
            assertEqual(s.consecutiveRateLimits, 1, "first rate limit")
        }

        test("onSuccess resets interval after rate limit") {
            var s = FetchSchedule()
            s.onRateLimit(retryAfter: 120)
            assertEqual(s.interval, 120.0, "interval set to retry-after")
            check(s.isRateLimited, "rate limited after 429")

            s.onSuccess()
            assertEqual(s.interval, defaultFetchInterval, "interval reset to default after success")
            check(!s.isRateLimited, "rate limit cleared after success")
            assertEqual(s.consecutiveRateLimits, 0, "counter reset on success")
        }

        test("exponential backoff on consecutive rate limits") {
            var s = FetchSchedule()
            // retry-after: 0 → clamped to 60s base
            s.onRateLimit(retryAfter: 0)
            assertEqual(s.interval, 60.0, "1st: 60 * 2^0 = 60s")

            s.onRateLimit(retryAfter: 0)
            assertEqual(s.interval, 120.0, "2nd: 60 * 2^1 = 120s")

            s.onRateLimit(retryAfter: 0)
            assertEqual(s.interval, 240.0, "3rd: 60 * 2^2 = 240s")

            s.onRateLimit(retryAfter: 0)
            assertEqual(s.interval, 300.0, "4th: capped at defaultFetchInterval 300s")

            s.onRateLimit(retryAfter: 0)
            assertEqual(s.interval, 300.0, "5th: stays capped at 300s")
        }

        test("success resets backoff counter") {
            var s = FetchSchedule()
            s.onRateLimit(retryAfter: 0)
            s.onRateLimit(retryAfter: 0)
            assertEqual(s.interval, 120.0, "backed off to 120s")

            s.onSuccess()
            assertEqual(s.consecutiveRateLimits, 0, "counter reset")

            s.onRateLimit(retryAfter: 0)
            assertEqual(s.interval, 60.0, "backoff restarts from 60s after success")
        }

        test("onSuccess is idempotent when not rate limited") {
            var s = FetchSchedule()
            s.onSuccess()
            assertEqual(s.interval, defaultFetchInterval, "stays at default")
            check(!s.isRateLimited, "still not rate limited")
        }

        test("large retry-after skips backoff") {
            var s = FetchSchedule()
            s.onRateLimit(retryAfter: 300)
            assertEqual(s.interval, 300.0, "300s on first hit, already at cap")
        }
    }
}

// MARK: - Usage History Tests

func runUsageHistoryTests() {
    suite("UsageHistory") {
        test("record adds entries") {
            var h = UsageHistory()
            let u = UsageData(fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                              sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil))
            h.record(u)
            assertEqual(h.entries.count, 1, "one entry")
            assertEqual(h.entries[0].fiveHour, 10.0, "fiveHour value")
            assertEqual(h.entries[0].sevenDay, 20.0, "sevenDay value")
        }

        test("record caps at maxEntries (24)") {
            var h = UsageHistory()
            for i in 0..<30 {
                let u = UsageData(fiveHour: UsageWindow(utilization: Double(i), remaining: nil, resetsAt: nil),
                                  sevenDay: UsageWindow(utilization: Double(i), remaining: nil, resetsAt: nil))
                h.record(u)
            }
            assertEqual(h.entries.count, 24, "capped at 24")
            assertEqual(h.entries[0].fiveHour, 6.0, "oldest entry is #6")
            assertEqual(h.entries[23].fiveHour, 29.0, "newest entry is #29")
        }

        test("trend with empty history returns flat") {
            let h = UsageHistory()
            assertEqual(h.trend(for: \.fiveHour), Character("→"), "empty → flat")
        }

        test("trend with one entry returns flat") {
            var h = UsageHistory()
            h.record(UsageData(fiveHour: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil),
                               sevenDay: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil)))
            assertEqual(h.trend(for: \.fiveHour), Character("→"), "single entry → flat")
        }

        test("trend with fewer than 6 entries returns flat") {
            var h = UsageHistory()
            for v in [10.0, 20.0, 30.0, 40.0, 50.0] {
                h.record(UsageData(fiveHour: UsageWindow(utilization: v, remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: v, remaining: nil, resetsAt: nil)))
            }
            assertEqual(h.trend(for: \.fiveHour), Character("→"), "5 entries → flat (need 6)")
        }

        test("trend rising") {
            var h = UsageHistory()
            for v in [10.0, 12.0, 14.0, 16.0, 18.0, 20.0] {
                h.record(UsageData(fiveHour: UsageWindow(utilization: v, remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: v, remaining: nil, resetsAt: nil)))
            }
            assertEqual(h.trend(for: \.fiveHour), Character("↑"), "rising trend")
        }

        test("trend falling") {
            var h = UsageHistory()
            for v in [20.0, 18.0, 16.0, 14.0, 12.0, 10.0] {
                h.record(UsageData(fiveHour: UsageWindow(utilization: v, remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: v, remaining: nil, resetsAt: nil)))
            }
            assertEqual(h.trend(for: \.fiveHour), Character("↓"), "falling trend")
        }

        test("trend flat with small changes") {
            var h = UsageHistory()
            for v in [50.0, 50.5, 51.0, 50.5, 51.0, 51.5] {
                h.record(UsageData(fiveHour: UsageWindow(utilization: v, remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: v, remaining: nil, resetsAt: nil)))
            }
            assertEqual(h.trend(for: \.fiveHour), Character("→"), "small changes → flat")
        }

        test("trend works independently per keyPath") {
            var h = UsageHistory()
            // fiveHour rises, sevenDay falls
            let fiveHourVals = [10.0, 12.0, 14.0, 16.0, 18.0, 20.0]
            let sevenDayVals = [20.0, 18.0, 16.0, 14.0, 12.0, 10.0]
            for i in 0..<6 {
                h.record(UsageData(fiveHour: UsageWindow(utilization: fiveHourVals[i], remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: sevenDayVals[i], remaining: nil, resetsAt: nil)))
            }
            assertEqual(h.trend(for: \.fiveHour), Character("↑"), "5h rising")
            assertEqual(h.trend(for: \.sevenDay), Character("↓"), "7d falling")
        }

        test("sparkline empty history") {
            let h = UsageHistory()
            assertEqual(h.sparkline(for: \.fiveHour), "", "empty → empty string")
        }

        test("sparkline with ascending values") {
            var h = UsageHistory()
            for v in [0.0, 25.0, 50.0, 75.0, 100.0] {
                h.record(UsageData(fiveHour: UsageWindow(utilization: v, remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: 0, remaining: nil, resetsAt: nil)))
            }
            let s = h.sparkline(for: \.fiveHour)
            assertEqual(s.count, 5, "5 chars for 5 entries")
            assertEqual(s.first, Character("▁"), "starts with lowest block")
            assertEqual(s.last, Character("█"), "ends with highest block")
        }

        test("sparkline constant values uses lowest block") {
            var h = UsageHistory()
            for _ in 0..<5 {
                h.record(UsageData(fiveHour: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil)))
            }
            let s = h.sparkline(for: \.fiveHour)
            assertEqual(s.count, 5, "5 chars")
            check(s.allSatisfy { $0 == "▁" }, "all lowest block for constant values")
        }

        test("sparkline respects width parameter") {
            var h = UsageHistory()
            for v in 0..<20 {
                h.record(UsageData(fiveHour: UsageWindow(utilization: Double(v), remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: 0, remaining: nil, resetsAt: nil)))
            }
            let s = h.sparkline(for: \.fiveHour, width: 8)
            assertEqual(s.count, 8, "limited to width=8")
        }

        test("sparkline needs at least 3 entries") {
            var h = UsageHistory()
            h.record(UsageData(fiveHour: UsageWindow(utilization: 0, remaining: nil, resetsAt: nil),
                               sevenDay: UsageWindow(utilization: 0, remaining: nil, resetsAt: nil)))
            h.record(UsageData(fiveHour: UsageWindow(utilization: 100, remaining: nil, resetsAt: nil),
                               sevenDay: UsageWindow(utilization: 0, remaining: nil, resetsAt: nil)))
            assertEqual(h.sparkline(for: \.fiveHour), "", "two entries not enough")
            h.record(UsageData(fiveHour: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil),
                               sevenDay: UsageWindow(utilization: 0, remaining: nil, resetsAt: nil)))
            assertEqual(h.sparkline(for: \.fiveHour), "▁█▄", "three entries works")
        }
    }
}

// MARK: - Format Status Line with History Tests

func runFormatStatusLineWithHistoryTests() {
    suite("formatStatusLine with history") {
        test("history is ignored in compact format") {
            var h = UsageHistory()
            for v in [10.0, 12.0, 14.0, 16.0, 18.0, 20.0] {
                h.record(UsageData(fiveHour: UsageWindow(utilization: v, remaining: nil, resetsAt: nil),
                                   sevenDay: UsageWindow(utilization: v, remaining: nil, resetsAt: nil)))
            }
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u, history: h) == "20/20", "compact ignores history")
        }

        test("mixed values") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 85, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "85/20", "compact format 85/20")
        }
    }
}

// MARK: - Pacing Tests

func runPacingTests() {
    suite("calculatePace") {
        let now = Date(timeIntervalSince1970: 1000000)
        let sevenDays: TimeInterval = 7 * 86400
        let fiveHours: TimeInterval = 5 * 3600

        test("nil resetsAt returns nil") {
            assertNil(calculatePace(utilization: 50, resetsAt: nil, windowDuration: sevenDays, now: now), "nil resetsAt")
        }

        test("past resetsAt returns nil") {
            let past = now.addingTimeInterval(-100)
            assertNil(calculatePace(utilization: 50, resetsAt: past, windowDuration: sevenDays, now: now), "past reset")
        }

        test("on track returns ~1.0") {
            // 3.5 days in (half the window), 50% used → pace = 1.0
            let resetsAt = now.addingTimeInterval(3.5 * 86400)
            let pace = calculatePace(utilization: 50, resetsAt: resetsAt, windowDuration: sevenDays, now: now)
            assertNotNil(pace, "should have pace")
            if let pace = pace {
                check(pace > 0.99 && pace < 1.01, "pace ~1.0, got \(pace)")
            }
        }

        test("over budget returns >1.2") {
            // 2 days in (~28.6% of window), 50% used → pace ≈ 1.75
            let resetsAt = now.addingTimeInterval(5 * 86400)
            let pace = calculatePace(utilization: 50, resetsAt: resetsAt, windowDuration: sevenDays, now: now)
            assertNotNil(pace, "should have pace")
            if let pace = pace {
                check(pace > 1.2, "over budget, got \(pace)")
            }
        }

        test("under budget returns <0.8") {
            // 5 days in (~71.4% of window), 30% used → pace ≈ 0.42
            let resetsAt = now.addingTimeInterval(2 * 86400)
            let pace = calculatePace(utilization: 30, resetsAt: resetsAt, windowDuration: sevenDays, now: now)
            assertNotNil(pace, "should have pace")
            if let pace = pace {
                check(pace < 0.8, "under budget, got \(pace)")
            }
        }

        test("5-hour window pacing") {
            // 2.5 hours in (half), 50% used → pace = 1.0
            let resetsAt = now.addingTimeInterval(2.5 * 3600)
            let pace = calculatePace(utilization: 50, resetsAt: resetsAt, windowDuration: fiveHours, now: now)
            assertNotNil(pace, "5h pace")
            if let pace = pace {
                check(pace > 0.99 && pace < 1.01, "5h on track, got \(pace)")
            }
        }

        test("very early in window returns nil") {
            // Just started, expected < 1%
            let resetsAt = now.addingTimeInterval(sevenDays - 60)
            assertNil(calculatePace(utilization: 0.1, resetsAt: resetsAt, windowDuration: sevenDays, now: now), "too early")
        }
    }

    suite("paceLabel") {
        test("over budget label") {
            let label = paceLabel(1.5)
            check(label.contains("1.5x"), "shows pace")
            check(label.contains("over budget"), "over budget text")
            check(label.contains("▲"), "up arrow")
        }

        test("under budget label") {
            let label = paceLabel(0.6)
            check(label.contains("0.6x"), "shows pace")
            check(label.contains("under budget"), "under budget text")
            check(label.contains("▼"), "down arrow")
        }

        test("on track label") {
            let label = paceLabel(1.0)
            check(label.contains("1.0x"), "shows pace")
            check(label.contains("on track"), "on track text")
        }

        test("boundary values") {
            check(paceLabel(1.2).contains("on track"), "1.2 is on track")
            check(paceLabel(1.21).contains("over budget"), "1.21 is over")
            check(paceLabel(0.8).contains("on track"), "0.8 is on track")
            check(paceLabel(0.79).contains("under budget"), "0.79 is under")
        }
    }
}

// MARK: - Zone & Notification Tests

func runZoneTests() {
    suite("zoneFor") {
        test("0% is green") {
            assertEqual(zoneFor(utilization: 0), .green, "0%")
        }

        test("49.9% is green") {
            assertEqual(zoneFor(utilization: 49.9), .green, "49.9%")
        }

        test("50% is yellow") {
            assertEqual(zoneFor(utilization: 50), .yellow, "50%")
        }

        test("79.9% is yellow") {
            assertEqual(zoneFor(utilization: 79.9), .yellow, "79.9%")
        }

        test("80% is red") {
            assertEqual(zoneFor(utilization: 80), .red, "80%")
        }

        test("99.9% is red") {
            assertEqual(zoneFor(utilization: 99.9), .red, "99.9%")
        }

        test("100% is depleted") {
            assertEqual(zoneFor(utilization: 100), .depleted, "100%")
        }

        test("zone ordering") {
            check(UsageZone.green < UsageZone.yellow, "green < yellow")
            check(UsageZone.yellow < UsageZone.red, "yellow < red")
            check(UsageZone.red < UsageZone.depleted, "red < depleted")
        }
    }
}

func makeUsage(h5: Double, d7: Double) -> UsageData {
    UsageData(
        fiveHour: UsageWindow(utilization: h5, remaining: nil, resetsAt: nil),
        sevenDay: UsageWindow(utilization: d7, remaining: nil, resetsAt: nil)
    )
}

func runNotificationTests() {
    suite("determineNotifications") {
        test("green to yellow triggers zone transition") {
            let state = NotificationState()
            let (notifs, newState) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 1, "one notification")
            assertEqual(notifs[0], .zoneTransition(window: "5-hour", zone: .yellow, utilization: 55), "yellow transition")
            assertEqual(newState.fiveHourZone, .yellow, "state updated")
        }

        test("green to red triggers zone transition") {
            let state = NotificationState()
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 85, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 1, "one notification")
            assertEqual(notifs[0], .zoneTransition(window: "5-hour", zone: .red, utilization: 85), "red transition")
        }

        test("green to depleted triggers depleted notification") {
            let state = NotificationState()
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 100, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 1, "one notification")
            assertEqual(notifs[0], .depleted(window: "5-hour"), "depleted")
        }

        test("yellow to red triggers zone transition") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 85, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 1, "one notification")
            assertEqual(notifs[0], .zoneTransition(window: "5-hour", zone: .red, utilization: 85), "red transition")
        }

        test("staying in same zone does not re-trigger") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 60, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 0, "no notifications")
        }

        test("downward transition does not trigger") {
            var state = NotificationState()
            state.fiveHourZone = .red
            let (notifs, newState) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 0, "no notifications on drop")
            assertEqual(newState.fiveHourZone, .yellow, "state tracks current zone")
        }

        test("reset to green clears tracking") {
            var state = NotificationState()
            state.fiveHourZone = .red
            state.fiveHourPaceAlerted = true
            let (_, newState) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 10, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(newState.fiveHourZone, .green, "zone reset")
            assertEqual(newState.fiveHourPaceAlerted, false, "pace alert reset")
        }

        test("re-trigger after reset to green") {
            // First: go to yellow
            let state0 = NotificationState()
            let (n1, state1) = determineNotifications(oldState: state0, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(n1.count, 1, "first yellow trigger")

            // Drop to green
            let (n2, state2) = determineNotifications(oldState: state1, newUsage: makeUsage(h5: 10, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(n2.count, 0, "no trigger on drop")

            // Rise to yellow again
            let (n3, _) = determineNotifications(oldState: state2, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(n3.count, 1, "re-triggers after green reset")
        }

        test("both windows trigger simultaneously") {
            let state = NotificationState()
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 85), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 2, "two notifications")
            assertEqual(notifs[0], .zoneTransition(window: "5-hour", zone: .yellow, utilization: 55), "5h yellow")
            assertEqual(notifs[1], .zoneTransition(window: "7-day", zone: .red, utilization: 85), "7d red")
        }

        test("pace over budget fires notification") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            let (notifs, newState) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: 1.5, sevenDayPace: nil)
            assertEqual(notifs.count, 1, "one pace notification")
            assertEqual(notifs[0], .paceOverBudget(window: "5-hour", pace: 1.5), "pace alert")
            assertEqual(newState.fiveHourPaceAlerted, true, "pace alerted flag set")
        }

        test("pace does not re-fire when already alerted") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            state.fiveHourPaceAlerted = true
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: 1.5, sevenDayPace: nil)
            assertEqual(notifs.count, 0, "no re-fire")
        }

        test("pace resets when pace drops below threshold") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            state.fiveHourPaceAlerted = true
            let (_, newState) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: 1.0, sevenDayPace: nil)
            assertEqual(newState.fiveHourPaceAlerted, false, "pace alert reset")
        }

        test("depleted suppresses pace alert") {
            let state = NotificationState()
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 100, d7: 10), fiveHourPace: 1.5, sevenDayPace: nil)
            assertEqual(notifs.count, 1, "only depleted, no pace")
            assertEqual(notifs[0], .depleted(window: "5-hour"), "depleted only")
        }

        test("nil pace does not trigger") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 0, "nil pace = no alert")
        }

        test("initial green usage produces no alerts") {
            let state = NotificationState()
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 10, d7: 20), fiveHourPace: nil, sevenDayPace: nil)
            assertEqual(notifs.count, 0, "green = no alerts")
        }

        test("pace at exactly 1.2 does not trigger") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: 1.2, sevenDayPace: nil)
            assertEqual(notifs.count, 0, "1.2 exactly = no trigger")
        }

        test("pace at 1.21 triggers") {
            var state = NotificationState()
            state.fiveHourZone = .yellow
            let (notifs, _) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 55, d7: 10), fiveHourPace: 1.21, sevenDayPace: nil)
            assertEqual(notifs.count, 1, "1.21 triggers")
            assertEqual(notifs[0], .paceOverBudget(window: "5-hour", pace: 1.21), "pace alert at 1.21")
        }

        test("pace alert resets when leaving depleted") {
            // Simulate: pace alerted → depleted → drops back to red
            var state = NotificationState()
            state.fiveHourZone = .depleted
            state.fiveHourPaceAlerted = true
            // Exit depleted to red with over-budget pace
            let (notifs, newState) = determineNotifications(oldState: state, newUsage: makeUsage(h5: 85, d7: 10), fiveHourPace: 1.5, sevenDayPace: nil)
            // Should re-fire pace alert since we left depleted (flag was reset)
            assertEqual(newState.fiveHourPaceAlerted, true, "pace re-alerted after depleted exit")
            check(notifs.contains(.paceOverBudget(window: "5-hour", pace: 1.5)), "pace alert fires after leaving depleted")
        }
    }
}

// MARK: - Depletion Estimate Tests

func runDepletionEstimateTests() {
    let fiveHours: TimeInterval = 5 * 3600
    let sevenDays: TimeInterval = 7 * 86400
    let now = Date(timeIntervalSince1970: 1000000)

    suite("depletionEstimate") {
        test("nil when resetsAt is nil") {
            check(depletionEstimate(utilization: 50, resetsAt: nil, windowDuration: fiveHours, now: now) == nil, "nil for nil reset")
        }

        test("nil when elapsed < 60s") {
            let resetsAt = now.addingTimeInterval(fiveHours - 30)  // 30s elapsed
            check(depletionEstimate(utilization: 50, resetsAt: resetsAt, windowDuration: fiveHours, now: now) == nil, "nil for short elapsed")
        }

        test("nil when utilization near zero") {
            let resetsAt = now.addingTimeInterval(fiveHours - 3600)  // 1h elapsed
            check(depletionEstimate(utilization: 0.05, resetsAt: resetsAt, windowDuration: fiveHours, now: now) == nil, "nil for tiny utilization")
        }

        test("won't deplete when rate is low") {
            let resetsAt = now.addingTimeInterval(3600)  // 1h left of 5h window, 4h elapsed
            let result = depletionEstimate(utilization: 10, resetsAt: resetsAt, windowDuration: fiveHours, now: now)
            check(result == "Won't deplete this window", "won't deplete at low rate")
        }

        test("shows depletion time when rate is high") {
            let resetsAt = now.addingTimeInterval(14400)  // 4h left, 1h elapsed
            let result = depletionEstimate(utilization: 50, resetsAt: resetsAt, windowDuration: fiveHours, now: now)
            check(result?.contains("Won't") == false, "depletes at high rate")
            check(result?.contains("Depletes in") == true, "contains depletion label")
        }

        test("100% utilization") {
            let resetsAt = now.addingTimeInterval(3600)
            let result = depletionEstimate(utilization: 100, resetsAt: resetsAt, windowDuration: fiveHours, now: now)
            // 0% left / rate = 0 time, but (100 - 100) = 0, secsToFull = 0 which is < remaining
            check(result != nil, "result for 100%")
        }
    }
}

// MARK: - Budget Advice Tests

func runBudgetAdviceTests() {
    let sevenDays: TimeInterval = 7 * 86400
    let now = Date(timeIntervalSince1970: 1000000)

    suite("budgetAdvice") {
        test("nil when resetsAt is nil") {
            check(budgetAdvice(utilization: 50, resetsAt: nil, windowDuration: sevenDays, now: now) == nil, "nil for nil reset")
        }

        test("nil when remaining < 60s") {
            let resetsAt = now.addingTimeInterval(30)
            check(budgetAdvice(utilization: 50, resetsAt: resetsAt, windowDuration: sevenDays, now: now) == nil, "nil for tiny remaining")
        }

        test("exhausted when 100%") {
            let resetsAt = now.addingTimeInterval(86400)
            assertEqual(budgetAdvice(utilization: 100, resetsAt: resetsAt, windowDuration: sevenDays, now: now), "Budget exhausted", "exhausted at 100%")
        }

        test("use sparingly near window end") {
            let resetsAt = now.addingTimeInterval(600)  // 10 min left = 0.17h
            let result = budgetAdvice(utilization: 50, resetsAt: resetsAt, windowDuration: sevenDays, now: now)
            assertEqual(result, "Budget: use sparingly", "sparingly near end")
        }

        test("normal budget with time remaining") {
            let resetsAt = now.addingTimeInterval(86400)  // 24h left
            let result = budgetAdvice(utilization: 50, resetsAt: resetsAt, windowDuration: sevenDays, now: now)
            check(result?.contains("Budget:") == true && result?.contains("/hour") == true, "normal budget format")
        }
    }
}

// MARK: - Daily Breakdown Tests

func runDailyBreakdownTests() {
    let sevenDays: TimeInterval = 7 * 86400
    let now = Date(timeIntervalSince1970: 1000000)

    suite("dailyBreakdown") {
        test("nil when resetsAt is nil") {
            check(dailyBreakdown(utilization: 50, resetsAt: nil, windowDuration: sevenDays, now: now) == nil, "nil for nil reset")
        }

        test("nil when barely elapsed") {
            let resetsAt = now.addingTimeInterval(sevenDays - 10)  // 10s elapsed
            check(dailyBreakdown(utilization: 50, resetsAt: resetsAt, windowDuration: sevenDays, now: now) == nil, "nil for tiny elapsed")
        }

        test("shows rate and safe rate") {
            let resetsAt = now.addingTimeInterval(sevenDays - 86400)  // 1 day elapsed
            let result = dailyBreakdown(utilization: 20, resetsAt: resetsAt, windowDuration: sevenDays, now: now)
            check(result != nil, "result exists")
            check(result?.contains("Today's rate:") == true, "has rate")
            check(result?.contains("Safe:") == true, "has safe rate")
        }
    }
}

// MARK: - Peak Hours Tests

func runPeakHoursTests() {
    suite("peakHoursSummary") {
        test("nil with fewer than 3 entries") {
            check(peakHoursSummary([]) == nil, "nil for empty")
            check(peakHoursSummary([Date(), Date()]) == nil, "nil for 2 entries")
        }

        test("returns peak hour with 3+ entries") {
            let cal = Calendar.current
            var dates: [Date] = []
            for _ in 0..<5 {
                dates.append(cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!)
            }
            dates.append(cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!)
            let result = peakHoursSummary(dates)
            check(result != nil, "result exists")
            check(result?.contains("14:00") == true, "peak at hour 14")
        }
    }
}

// MARK: - Parse Window Tests

func runParseWindowTests() {
    suite("parseWindowIfPresent") {
        test("nil for nil dict") {
            check(parseWindowIfPresent(nil) == nil, "nil for nil")
        }

        test("nil for missing utilization") {
            check(parseWindowIfPresent(["remaining": 50.0]) == nil, "nil for missing util")
        }

        test("nil for out of range") {
            check(parseWindowIfPresent(["utilization": 150.0]) == nil, "nil for >100")
            check(parseWindowIfPresent(["utilization": -5.0]) == nil, "nil for negative")
        }

        test("parses valid window") {
            let result = parseWindowIfPresent(["utilization": 25.0, "remaining": 75.0])
            check(result != nil, "parses valid")
            check(result?.utilization == 25.0, "correct utilization")
            check(result?.remaining == 75.0, "correct remaining")
        }

        test("parses without optional fields") {
            let result = parseWindowIfPresent(["utilization": 0.0])
            check(result != nil, "parses minimal")
            check(result?.remaining == nil, "no remaining")
            check(result?.resetsAt == nil, "no resetsAt")
        }
    }
}

// MARK: - Model Breakdown Parse Tests

func runModelBreakdownParseTests() {
    suite("parseUsage with models") {
        test("parses model breakdown") {
            let json: [String: Any] = [
                "five_hour": ["utilization": 30.0],
                "seven_day": ["utilization": 20.0],
                "seven_day_sonnet": ["utilization": 5.0],
                "seven_day_opus": ["utilization": 10.0],
                "extra_usage": ["is_enabled": true, "utilization": 15.0]
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            let result = parseUsage(from: data)
            check(result != nil, "parses with models")
            check(result?.models != nil, "has models")
            assertEqual(result?.models?.sonnet?.utilization, 5.0, "sonnet util")
            assertEqual(result?.models?.opus?.utilization, 10.0, "opus util")
            assertEqual(result?.extraUsage?.isEnabled, true, "extra enabled")
            assertEqual(result?.extraUsage?.utilization, 15.0, "extra util")
        }

        test("nil models when none present") {
            let json: [String: Any] = [
                "five_hour": ["utilization": 30.0],
                "seven_day": ["utilization": 20.0]
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            let result = parseUsage(from: data)
            check(result != nil, "parses without models")
            check(result?.models == nil, "no models")
        }
    }
}

// MARK: - Test Runner

func runAllTests() {
    runParseTokenTests()
    runParseRefreshTokenTests()
    runParseExpiresAtTests()
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
    runFetchScheduleTests()
    runUsageHistoryTests()
    runFormatStatusLineWithHistoryTests()
    runPacingTests()
    runZoneTests()
    runNotificationTests()
    runDepletionEstimateTests()
    runBudgetAdviceTests()
    runDailyBreakdownTests()
    runPeakHoursTests()
    runParseWindowTests()
    runModelBreakdownParseTests()

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
