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

func runParseOAuthAccountEmailTests() {
    suite("parseOAuthAccountEmail") {
        test("valid oauth account email") {
            let json = """
            {"oauthAccount":{"emailAddress":"user@example.com","displayName":"User"}}
            """.data(using: .utf8)!
            assertEqual(parseOAuthAccountEmail(from: json), "user@example.com")
        }

        test("missing oauthAccount") {
            let json = """
            {"someOtherKey":{"emailAddress":"user@example.com"}}
            """.data(using: .utf8)!
            assertNil(parseOAuthAccountEmail(from: json), "missing oauthAccount")
        }

        test("missing emailAddress") {
            let json = """
            {"oauthAccount":{"displayName":"User"}}
            """.data(using: .utf8)!
            assertNil(parseOAuthAccountEmail(from: json), "missing emailAddress")
        }

        test("empty emailAddress") {
            let json = """
            {"oauthAccount":{"emailAddress":""}}
            """.data(using: .utf8)!
            assertNil(parseOAuthAccountEmail(from: json), "empty emailAddress")
        }

        test("invalid JSON") {
            let data = "not json".data(using: .utf8)!
            assertNil(parseOAuthAccountEmail(from: data), "invalid JSON")
        }
    }
}

func runMissingCredentialsDetailsTests() {
    suite("missingCredentialsDetails") {
        test("metadata only shows reauth hint") {
            let json = """
            {"oauthAccount":{"emailAddress":"remote@example.com","displayName":"Remote User"}}
            """.data(using: .utf8)!
            let details = _missingCredentialsDetails(from: json)
            assertEqual(details.0, "Claude account found for remote@example.com")
            assertEqual(details.1, "OAuth token missing. Run `claude auth login`")
        }

        test("missing config falls back to generic message") {
            let details = _missingCredentialsDetails(from: nil)
            assertEqual(details.0, "No credentials found")
            assertEqual(details.1, "Ensure Claude Code is signed in")
        }

        test("invalid config falls back to generic message") {
            let data = "not json".data(using: .utf8)!
            let details = _missingCredentialsDetails(from: data)
            assertEqual(details.0, "No credentials found")
            assertEqual(details.1, "Ensure Claude Code is signed in")
        }
    }
}

func runParseKeychainAccountTests() {
    suite("parseKeychainAccount") {
        test("typical output with account") {
            let output = """
            keychain: "/Users/testuser/Library/Keychains/login.keychain-db"
            version: 512
            class: "genp"
            attributes:
                0x00000007 <blob>="Claude Code-credentials"
                0x00000008 <blob>=<NULL>
                "acct"<blob>="testuser"
                "cdat"<timedate>=0x32303236303332343133343834345A00  "20260324134844Z\\000"
                "svce"<blob>="Claude Code-credentials"
            """
            assertEqual(parseKeychainAccount(from: output), "testuser")
        }

        test("account with dots") {
            let output = """
                "acct"<blob>="john.doe"
                "svce"<blob>="Claude Code-credentials"
            """
            assertEqual(parseKeychainAccount(from: output), "john.doe")
        }

        test("account with hyphens and underscores") {
            let output = """
                "acct"<blob>="my-user_name"
            """
            assertEqual(parseKeychainAccount(from: output), "my-user_name")
        }

        test("null account returns nil") {
            let output = """
                "acct"<blob>=<NULL>
                "svce"<blob>="Claude Code-credentials"
            """
            assertNil(parseKeychainAccount(from: output), "NULL account")
        }

        test("missing account line returns nil") {
            let output = """
            keychain: "/Users/testuser/Library/Keychains/login.keychain-db"
            version: 512
            class: "genp"
            """
            assertNil(parseKeychainAccount(from: output), "no acct line")
        }

        test("empty output returns nil") {
            assertNil(parseKeychainAccount(from: ""), "empty string")
        }

        test("empty account name") {
            let output = """
                "acct"<blob>=""
            """
            assertEqual(parseKeychainAccount(from: output), "")
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
            check(line == "9 18", "compact format 9/18")
        }

        test("high usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 85.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 90.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "85 90", "compact format 85/90")
        }

        test("decimal values") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 6.5, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 18.3, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "6.5 18.3", "compact format 6.5/18.3")
        }

        test("zero usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 0.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 0.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "0 0", "compact format 0/0")
        }

        test("full usage") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "100 100", "compact format 100/100")
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
            assertEqual(s.interval, 300.0, "4th: capped at maxBackoffInterval 300s")

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

        test("record caps at maxEntries (60)") {
            var h = UsageHistory()
            for i in 0..<70 {
                let u = UsageData(fiveHour: UsageWindow(utilization: Double(i), remaining: nil, resetsAt: nil),
                                  sevenDay: UsageWindow(utilization: Double(i), remaining: nil, resetsAt: nil))
                h.record(u)
            }
            assertEqual(h.entries.count, 60, "capped at 60")
            assertEqual(h.entries[0].fiveHour, 10.0, "oldest entry is #10")
            assertEqual(h.entries[59].fiveHour, 69.0, "newest entry is #69")
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

        test("restore loads saved entries") {
            var h = UsageHistory()
            let saved = [
                UsageHistory.Entry(date: Date(), fiveHour: 10, sevenDay: 20),
                UsageHistory.Entry(date: Date(), fiveHour: 30, sevenDay: 40),
            ]
            h.restore(saved)
            assertEqual(h.entries.count, 2, "restored 2 entries")
            assertEqual(h.entries[0].fiveHour, 10.0, "first entry")
            assertEqual(h.entries[1].fiveHour, 30.0, "second entry")
        }

        test("restore prunes stale entries") {
            var h = UsageHistory()
            let old = Date().addingTimeInterval(-8000)  // older than 2h
            let recent = Date().addingTimeInterval(-60)
            let saved = [
                UsageHistory.Entry(date: old, fiveHour: 10, sevenDay: 20),
                UsageHistory.Entry(date: recent, fiveHour: 30, sevenDay: 40),
            ]
            h.restore(saved)
            assertEqual(h.entries.count, 1, "stale entry pruned")
            assertEqual(h.entries[0].fiveHour, 30.0, "only recent entry kept")
        }

        test("restore caps at maxEntries") {
            var h = UsageHistory()
            var saved: [UsageHistory.Entry] = []
            for i in 0..<70 {
                saved.append(UsageHistory.Entry(date: Date(), fiveHour: Double(i), sevenDay: 0))
            }
            h.restore(saved)
            assertEqual(h.entries.count, 60, "capped at 60")
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
            check(formatStatusLine(u, history: h) == "20 20", "compact ignores history")
        }

        test("mixed values") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 85, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "85 20", "compact format 85/20")
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

    suite("paceIndicator") {
        test("nil pace returns empty") {
            assertEqual(paceIndicator(pace: nil), "", "nil pace")
        }

        test("over-pacing returns up arrow") {
            assertEqual(paceIndicator(pace: 1.5), "▲", "1.5x pace")
            assertEqual(paceIndicator(pace: 1.21), "▲", "1.21x pace")
        }

        test("under-pacing returns down arrow") {
            assertEqual(paceIndicator(pace: 0.5), "▼", "0.5x pace")
            assertEqual(paceIndicator(pace: 0.79), "▼", "0.79x pace")
        }

        test("on track returns dot") {
            assertEqual(paceIndicator(pace: 1.0), "●", "1.0x pace")
            assertEqual(paceIndicator(pace: 1.2), "●", "1.2x boundary")
            assertEqual(paceIndicator(pace: 0.8), "●", "0.8x boundary")
        }
    }

    suite("formatStatusLine with pace indicator") {
        test("over-pacing shows up arrow") {
            // 7-day window: 50% used, resets in 5.25 days (elapsed 1.75 days = 25% expected, pace = 2.0)
            let resetsAt = Date().addingTimeInterval(5.25 * 86400)
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 50, remaining: nil, resetsAt: resetsAt)
            )
            let line = formatStatusLine(u)
            check(line.hasSuffix("▲"), "should end with up arrow, got: \(line)")
        }

        test("under-pacing shows down arrow") {
            // 7-day window: 10% used, resets in 1 day (elapsed 6 days = 85.7% expected, pace ≈ 0.12)
            let resetsAt = Date().addingTimeInterval(1 * 86400)
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 10, remaining: nil, resetsAt: resetsAt)
            )
            let line = formatStatusLine(u)
            check(line.hasSuffix("▼"), "should end with down arrow, got: \(line)")
        }

        test("on-track shows no indicator") {
            // 7-day window: 50% used, resets in 3.5 days (elapsed 3.5 days = 50% expected, pace = 1.0)
            let resetsAt = Date().addingTimeInterval(3.5 * 86400)
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 50, remaining: nil, resetsAt: resetsAt)
            )
            let line = formatStatusLine(u)
            check(line.hasSuffix("●"), "should end with dot, got: \(line)")
        }

        test("no resetsAt shows no indicator") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 42, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 15, remaining: nil, resetsAt: nil)
            )
            check(formatStatusLine(u) == "42 15", "no indicator without resetsAt")
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

// MARK: - Window Reset Notification Tests

func runWindowResetNotificationTests() {
    suite("window reset notifications") {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func usage(h5: Double, d7: Double, h5Reset: Date?, d7Reset: Date?) -> UsageData {
            UsageData(
                fiveHour: UsageWindow(utilization: h5, remaining: nil, resetsAt: h5Reset),
                sevenDay: UsageWindow(utilization: d7, remaining: nil, resetsAt: d7Reset)
            )
        }

        test("first observation seeds state but does not fire") {
            let state = NotificationState()
            let u = usage(h5: 20, d7: 10, h5Reset: t0.addingTimeInterval(3600), d7Reset: t0.addingTimeInterval(86400))
            let (notifs, newState) = determineNotifications(oldState: state, newUsage: u, fiveHourPace: nil, sevenDayPace: nil, now: t0)
            check(!notifs.contains(where: {
                if case .windowReset = $0 { return true } else { return false }
            }), "no reset on first observation")
            assertNotNil(newState.lastFiveHourResetsAt, "seeded 5h reset")
            assertNotNil(newState.lastSevenDayResetsAt, "seeded 7d reset")
        }

        test("resetsAt moving forward fires reset notification") {
            var state = NotificationState()
            state.lastFiveHourResetsAt = t0
            state.lastFiveHourUtilization = 42
            state.lastSevenDayResetsAt = t0.addingTimeInterval(86400)
            state.lastSevenDayUtilization = 15
            let u = usage(
                h5: 0, d7: 15,
                h5Reset: t0.addingTimeInterval(5 * 3600),
                d7Reset: t0.addingTimeInterval(86400)
            )
            let (notifs, newState) = determineNotifications(oldState: state, newUsage: u, fiveHourPace: nil, sevenDayPace: nil, now: t0)
            check(notifs.contains(.windowReset(window: "5-hour", previousUtilization: 42)), "5h reset fires")
            check(!notifs.contains(where: {
                if case .windowReset(let w, _) = $0, w == "7-day" { return true } else { return false }
            }), "7d reset does not fire when timestamp unchanged")
            assertEqual(newState.lastFiveHourResetsAt, t0.addingTimeInterval(5 * 3600), "5h reset advanced")
        }

        test("zero prior utilization suppresses reset alert") {
            var state = NotificationState()
            state.lastFiveHourResetsAt = t0
            state.lastFiveHourUtilization = 0
            let u = usage(h5: 0, d7: 0, h5Reset: t0.addingTimeInterval(5 * 3600), d7Reset: nil)
            let (notifs, _) = determineNotifications(oldState: state, newUsage: u, fiveHourPace: nil, sevenDayPace: nil, now: t0)
            check(!notifs.contains(where: {
                if case .windowReset = $0 { return true } else { return false }
            }), "idle account must not fire reset")
        }

        test("nil new resetsAt does not fire") {
            var state = NotificationState()
            state.lastFiveHourResetsAt = t0
            state.lastFiveHourUtilization = 50
            let u = usage(h5: 0, d7: 0, h5Reset: nil, d7Reset: nil)
            let (notifs, _) = determineNotifications(oldState: state, newUsage: u, fiveHourPace: nil, sevenDayPace: nil, now: t0)
            check(!notifs.contains(where: {
                if case .windowReset = $0 { return true } else { return false }
            }), "missing reset timestamp suppresses alert")
        }

        test("60s jitter does not fire") {
            var state = NotificationState()
            state.lastFiveHourResetsAt = t0
            state.lastFiveHourUtilization = 50
            let u = usage(h5: 50, d7: 0, h5Reset: t0.addingTimeInterval(30), d7Reset: nil)
            let (notifs, _) = determineNotifications(oldState: state, newUsage: u, fiveHourPace: nil, sevenDayPace: nil, now: t0)
            check(!notifs.contains(where: {
                if case .windowReset = $0 { return true } else { return false }
            }), "small drift tolerated")
        }
    }
}

// MARK: - Depletion Estimate Tests

func runDepletionEstimateTests() {
    let fiveHours: TimeInterval = 5 * 3600
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

        test("100% utilization returns Depleted") {
            let resetsAt = now.addingTimeInterval(3600)
            let result = depletionEstimate(utilization: 100, resetsAt: resetsAt, windowDuration: fiveHours, now: now)
            assertEqual(result, "Depleted", "100% shows Depleted")
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
            check(result?.contains("Daily rate:") == true, "has rate")
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

// MARK: - Hourly Heatmap Tests

func runHourlyHeatmapTests() {
    // Use hour 23 as "now" so all 24 hours are visible in tests
    let cal = Calendar.current
    let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!

    suite("hourlyHeatmap") {
        test("nil with fewer than 3 entries") {
            assertNil(hourlyHeatmap([]), "nil for empty")
            assertNil(hourlyHeatmap([Date(), Date()]), "nil for 2 entries")
        }

        test("contiguous bars at end of day") {
            let dates = [
                cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!,
                cal.date(bySettingHour: 14, minute: 30, second: 0, of: Date())!,
                cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!,
            ]
            let result = hourlyHeatmap(dates, now: endOfDay)
            assertNotNil(result, "produces heatmap")
            let bars = Array(result!)
            assertEqual(bars.count, 24, "24 bars for 24 hours")
        }

        test("truncates to current hour") {
            let noon = cal.date(bySettingHour: 11, minute: 30, second: 0, of: Date())!
            let dates = [
                cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!,
                cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!,
                cal.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!,
            ]
            let result = hourlyHeatmap(dates, now: noon)
            assertNotNil(result, "produces heatmap")
            let bars = Array(result!)
            assertEqual(bars.count, 12, "12 bars for hours 0-11")
        }

        test("peak hour gets highest block") {
            var dates: [Date] = []
            for _ in 0..<10 {
                dates.append(cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!)
            }
            dates.append(cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!)
            let result = hourlyHeatmap(dates, now: endOfDay)!
            let bars = Array(result)
            assertEqual(String(bars[14]), "\u{2588}", "peak hour 14 gets highest block")
        }

        test("empty hours get middle dot") {
            let dates = [
                cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!,
                cal.date(bySettingHour: 14, minute: 30, second: 0, of: Date())!,
                cal.date(bySettingHour: 14, minute: 45, second: 0, of: Date())!,
            ]
            let result = hourlyHeatmap(dates, now: endOfDay)!
            let bars = Array(result)
            assertEqual(String(bars[0]), "\u{00B7}", "empty hour gets middle dot")
            assertEqual(String(bars[3]), "\u{00B7}", "empty hour gets middle dot")
        }

        test("multiple peaks distribute correctly") {
            var dates: [Date] = []
            for _ in 0..<8 {
                dates.append(cal.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!)
            }
            for _ in 0..<4 {
                dates.append(cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!)
            }
            let result = hourlyHeatmap(dates, now: endOfDay)!
            let bars = Array(result)
            assertEqual(String(bars[14]), "\u{2588}", "peak hour 14")
            assertEqual(String(bars[10]), "\u{2584}", "half-peak hour 10")
        }
    }
}

// MARK: - Hourly Heatmap Label Tests

func runHourlyHeatmapLabelTests() {
    let cal = Calendar.current

    suite("hourlyHeatmapLabel") {
        test("full day shows all markers") {
            let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
            let label = hourlyHeatmapLabel(now: endOfDay)
            check(label.contains("0"), "has 0 marker")
            check(label.contains("6"), "has 6 marker")
            check(label.contains("12"), "has 12 marker")
            check(label.contains("18"), "has 18 marker")
        }

        test("morning shows only early markers") {
            let morning = cal.date(bySettingHour: 5, minute: 30, second: 0, of: Date())!
            let label = hourlyHeatmapLabel(now: morning)
            check(label.contains("0"), "has 0 marker")
            check(!label.contains("6"), "no 6 marker before hour 6")
        }

        test("label width at least heatmap width") {
            let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
            let dates = [
                cal.date(bySettingHour: 1, minute: 0, second: 0, of: Date())!,
                cal.date(bySettingHour: 2, minute: 0, second: 0, of: Date())!,
                cal.date(bySettingHour: 3, minute: 0, second: 0, of: Date())!,
            ]
            let heatmap = hourlyHeatmap(dates, now: endOfDay)!
            let label = hourlyHeatmapLabel(now: endOfDay)
            check(label.count >= heatmap.count, "label at least as wide as heatmap")
        }

        test("hour 18 shows full 18 marker not truncated") {
            let hour18 = cal.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
            let label = hourlyHeatmapLabel(now: hour18)
            check(label.contains("18"), "has full 18 marker at hour 18")
            check(!label.hasSuffix("1"), "does not end with truncated 1")
        }

        test("hour 12 shows full 12 marker not truncated") {
            let hour12 = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
            let label = hourlyHeatmapLabel(now: hour12)
            check(label.contains("12"), "has full 12 marker at hour 12")
        }
    }
}

// MARK: - Agent Tracking Tests

func runAgentTrackingTests() {
    suite("parseAgentLaunches") {
        test("valid agent launch") {
            let json = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01ABC","name":"Agent","input":{"description":"Review code","subagent_type":"code-reviewer","prompt":"review this"}}]},"timestamp":"2026-03-11T14:49:55.323Z"}
            """.data(using: .utf8)!
            let agents = parseAgentLaunches(from: json)
            assertEqual(agents.count, 1, "one agent launched")
            assertEqual(agents[0].toolUseId, "toolu_01ABC")
            assertEqual(agents[0].description, "Review code")
            assertEqual(agents[0].subagentType, "code-reviewer")
            check(agents[0].isRunning, "agent should be running")
        }

        test("multiple agents in one message") {
            let json = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01A","name":"Agent","input":{"description":"Agent 1","subagent_type":"general-purpose","prompt":"a"}},{"type":"tool_use","id":"toolu_01B","name":"Agent","input":{"description":"Agent 2","subagent_type":"code-reviewer","prompt":"b"}}]},"timestamp":"2026-03-11T14:50:00.000Z"}
            """.data(using: .utf8)!
            let agents = parseAgentLaunches(from: json)
            assertEqual(agents.count, 2, "two agents launched")
            assertEqual(agents[0].description, "Agent 1")
            assertEqual(agents[1].description, "Agent 2")
        }

        test("non-agent tool_use ignored") {
            let json = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01X","name":"Read","input":{"file_path":"/tmp/foo"}}]},"timestamp":"2026-03-11T14:50:00.000Z"}
            """.data(using: .utf8)!
            let agents = parseAgentLaunches(from: json)
            assertEqual(agents.count, 0, "no agents from Read tool")
        }

        test("user message ignored") {
            let json = """
            {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01ABC"}]}}
            """.data(using: .utf8)!
            let agents = parseAgentLaunches(from: json)
            assertEqual(agents.count, 0, "user message has no launches")
        }

        test("invalid JSON") {
            let data = "not json".data(using: .utf8)!
            assertEqual(parseAgentLaunches(from: data).count, 0, "invalid JSON")
        }

        test("missing description uses default") {
            let json = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01Z","name":"Agent","input":{"prompt":"do stuff"}}]},"timestamp":"2026-03-11T14:50:00.000Z"}
            """.data(using: .utf8)!
            let agents = parseAgentLaunches(from: json)
            assertEqual(agents.count, 1)
            assertEqual(agents[0].description, "Agent")
            assertEqual(agents[0].subagentType, "general-purpose")
        }
    }

    suite("parseAgentCompletions") {
        test("valid completion with usage") {
            let json = """
            {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01ABC","content":[{"type":"text","text":"result here"},{"type":"text","text":"agentId: abc123\\n<usage>total_tokens: 14375\\ntool_uses: 1\\nduration_ms: 8494</usage>"}]}]}}
            """.data(using: .utf8)!
            let completions = parseAgentCompletions(from: json)
            assertEqual(completions.count, 1, "one completion")
            assertEqual(completions[0].toolUseId, "toolu_01ABC")
            assertEqual(completions[0].totalTokens ?? 0, 14375)
            assertEqual(completions[0].durationMs ?? 0, 8494)
        }

        test("completion without usage") {
            let json = """
            {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01XYZ","content":[{"type":"text","text":"just a result"}]}]}}
            """.data(using: .utf8)!
            let completions = parseAgentCompletions(from: json)
            assertEqual(completions.count, 1)
            assertNil(completions[0].totalTokens, "no tokens")
            assertNil(completions[0].durationMs, "no duration")
        }

        test("assistant message ignored") {
            let json = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01A","name":"Agent","input":{"prompt":"x"}}]}}
            """.data(using: .utf8)!
            assertEqual(parseAgentCompletions(from: json).count, 0)
        }
    }

    suite("formatAgentDuration") {
        test("completed agent with duration") {
            let agent = TrackedAgent(toolUseId: "t1", description: "Test", subagentType: "gp", launchedAt: Date(), completedAt: Date(), totalTokens: nil, durationMs: 8494)
            assertEqual(formatAgentDuration(agent), "8s")
        }

        test("completed agent long duration") {
            let agent = TrackedAgent(toolUseId: "t1", description: "Test", subagentType: "gp", launchedAt: Date(), completedAt: Date(), totalTokens: nil, durationMs: 125000)
            assertEqual(formatAgentDuration(agent), "2m5s")
        }

        test("running agent shows elapsed") {
            let now = Date()
            let agent = TrackedAgent(toolUseId: "t1", description: "Test", subagentType: "gp", launchedAt: now.addingTimeInterval(-15))
            assertEqual(formatAgentDuration(agent, now: now), "15s")
        }
    }

    suite("formatTokenCount") {
        test("small count") {
            assertEqual(formatTokenCount(500), "500")
        }

        test("thousands") {
            assertEqual(formatTokenCount(14375), "14K")
        }

        test("exact thousand") {
            assertEqual(formatTokenCount(1000), "1K")
        }
    }

    suite("projectNameFromSessionPath") {
        test("standard project path") {
            let path = "/Users/test/.claude/projects/-Users-test-Projects-ows-payment/abc.jsonl"
            assertEqual(projectNameFromSessionPath(path, homeDir: "/Users/test"), "ows-payment")
        }

        test("nested project path") {
            let path = "/Users/test/.claude/projects/-Users-test-Projects-terraform-infra/abc.jsonl"
            assertEqual(projectNameFromSessionPath(path, homeDir: "/Users/test"), "terraform-infra")
        }

        test("single-level project dir returns directory name") {
            let path = "/Users/test/.claude/projects/-Users-test-Projects/abc.jsonl"
            assertEqual(projectNameFromSessionPath(path, homeDir: "/Users/test"), "Projects", "single-level dir name")
        }

        test("non-matching home dir") {
            let path = "/Users/other/.claude/projects/-Users-other-Projects-foo/abc.jsonl"
            assertNil(projectNameFromSessionPath(path, homeDir: "/Users/test"), "different home dir")
        }
    }

    suite("AgentStats") {
        test("initial state") {
            let stats = AgentStats()
            assertEqual(stats.completedCount, 0)
            assertEqual(stats.totalTokens, 0)
            assertEqual(stats.avgDurationMs, 0)
        }

        test("record and average") {
            var stats = AgentStats()
            stats.record(tokens: 10000, durationMs: 5000)
            stats.record(tokens: 20000, durationMs: 15000)
            assertEqual(stats.completedCount, 2)
            assertEqual(stats.totalTokens, 30000)
            assertEqual(stats.avgDurationMs, 10000)
        }

        test("record with nil values") {
            var stats = AgentStats()
            stats.record(tokens: nil, durationMs: nil)
            assertEqual(stats.completedCount, 1)
            assertEqual(stats.totalTokens, 0)
        }
    }

    suite("formatAgentStatsLine") {
        test("no completed agents") {
            assertEqual(formatAgentStatsLine(AgentStats()), "")
        }

        test("with completed agents") {
            var stats = AgentStats()
            stats.record(tokens: 14000, durationMs: 8000)
            stats.record(tokens: 20000, durationMs: 12000)
            let line = formatAgentStatsLine(stats)
            check(line.contains("2 agents"), "agent count")
            check(line.contains("34K tok"), "total tokens")
            check(line.contains("avg 10s"), "average duration")
        }
    }
}

// MARK: - Session Token Tests

func runSessionTokenTests() {
    suite("SessionTokens") {
        test("initial state") {
            let tokens = SessionTokens()
            assertEqual(tokens.totalTokens, 0)
            assertEqual(tokens.totalInputTokens, 0)
            assertNil(tokens.cacheHitRate)
        }

        test("add tokens") {
            var tokens = SessionTokens()
            tokens.add(input: 1000, output: 500, cacheCreation: 200, cacheRead: 3000)
            assertEqual(tokens.inputTokens, 1000)
            assertEqual(tokens.outputTokens, 500)
            assertEqual(tokens.cacheCreationTokens, 200)
            assertEqual(tokens.cacheReadTokens, 3000)
            assertEqual(tokens.totalTokens, 4700)
            assertEqual(tokens.totalInputTokens, 4200)
        }

        test("accumulates across calls") {
            var tokens = SessionTokens()
            tokens.add(input: 1000, output: 500, cacheCreation: 0, cacheRead: 0)
            tokens.add(input: 2000, output: 1000, cacheCreation: 100, cacheRead: 5000)
            assertEqual(tokens.inputTokens, 3000)
            assertEqual(tokens.outputTokens, 1500)
            assertEqual(tokens.cacheReadTokens, 5000)
            assertEqual(tokens.totalTokens, 9600)
        }

        test("cache hit rate") {
            var tokens = SessionTokens()
            tokens.add(input: 1000, output: 500, cacheCreation: 0, cacheRead: 4000)
            // cacheHitRate = 4000 / (1000 + 0 + 4000) = 0.8
            let rate = tokens.cacheHitRate!
            check(abs(rate - 0.8) < 0.001, "cache hit rate should be 0.8, got \(rate)")
        }

        test("cache hit rate nil when no cache reads") {
            var tokens = SessionTokens()
            tokens.add(input: 1000, output: 500, cacheCreation: 0, cacheRead: 0)
            assertNil(tokens.cacheHitRate)
        }
    }

    suite("parseTokenUsage") {
        test("parses usage under message") {
            let json = Data("""
            {"type": "assistant", "message": {"role": "assistant", "content": [], "model": "claude-opus-4-6", "usage": {"input_tokens": 1500, "output_tokens": 800, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 5000}}}
            """.utf8)
            let result = parseTokenUsage(from: json)
            assertNotNil(result)
            assertEqual(result!.input, 1500)
            assertEqual(result!.output, 800)
            assertEqual(result!.cacheCreation, 200)
            assertEqual(result!.cacheRead, 5000)
        }

        test("falls back to top-level usage") {
            let json = Data("""
            {"type": "assistant", "usage": {"input_tokens": 1000, "output_tokens": 300}}
            """.utf8)
            let result = parseTokenUsage(from: json)
            assertNotNil(result)
            assertEqual(result!.input, 1000)
            assertEqual(result!.output, 300)
            assertEqual(result!.cacheCreation, 0)
            assertEqual(result!.cacheRead, 0)
        }

        test("returns nil for no usage") {
            let json = Data("""
            {"type": "user", "message": {"role": "user", "content": []}}
            """.utf8)
            assertNil(parseTokenUsage(from: json))
        }

        test("returns nil for zero usage") {
            let json = Data("""
            {"type": "assistant", "message": {"usage": {"input_tokens": 0, "output_tokens": 0}}}
            """.utf8)
            assertNil(parseTokenUsage(from: json))
        }

        test("returns nil for invalid JSON") {
            assertNil(parseTokenUsage(from: Data("not json".utf8)))
        }
    }

    suite("parseModel") {
        test("parses model under message") {
            let json = Data("""
            {"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-4-6"}}
            """.utf8)
            assertEqual(parseModel(from: json), "claude-opus-4-6")
        }

        test("falls back to top-level model") {
            let json = Data("""
            {"type": "assistant", "model": "claude-sonnet-4-6"}
            """.utf8)
            assertEqual(parseModel(from: json), "claude-sonnet-4-6")
        }

        test("returns nil when no model") {
            let json = Data("""
            {"type": "user", "message": {"role": "user"}}
            """.utf8)
            assertNil(parseModel(from: json))
        }

        test("returns nil for empty model") {
            let json = Data("""
            {"type": "assistant", "message": {"model": ""}}
            """.utf8)
            assertNil(parseModel(from: json))
        }
    }

    suite("modelDisplayName") {
        test("opus") {
            assertEqual(modelDisplayName("claude-opus-4-6"), "Opus 4.6")
        }
        test("sonnet") {
            assertEqual(modelDisplayName("claude-sonnet-4-6"), "Sonnet 4.6")
        }
        test("haiku with date suffix") {
            assertEqual(modelDisplayName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        }
        test("unknown model returns as-is") {
            assertEqual(modelDisplayName("some-other-model"), "some-other-model")
        }
        test("opus older version") {
            assertEqual(modelDisplayName("claude-opus-4-1"), "Opus 4.1")
        }
    }

    suite("formatSessionStats") {
        test("empty tokens returns empty") {
            assertEqual(formatSessionStats(SessionTokens()), "")
        }

        test("tokens only") {
            var tokens = SessionTokens()
            tokens.add(input: 15000, output: 3000, cacheCreation: 0, cacheRead: 0)
            let result = formatSessionStats(tokens)
            check(result.contains("15K in"), "shows input tokens: \(result)")
            check(result.contains("3K out"), "shows output tokens: \(result)")
        }

        test("with model") {
            var tokens = SessionTokens()
            tokens.add(input: 15000, output: 3000, cacheCreation: 0, cacheRead: 0)
            let result = formatSessionStats(tokens, model: "claude-opus-4-6")
            check(result.contains("Opus 4.6"), "shows model name: \(result)")
            check(result.contains("15K in"), "shows input tokens: \(result)")
        }

        test("with cache") {
            var tokens = SessionTokens()
            tokens.add(input: 1000, output: 500, cacheCreation: 0, cacheRead: 4000)
            let result = formatSessionStats(tokens)
            check(result.contains("5K in"), "shows total input: \(result)")
            check(result.contains("80% cache"), "shows cache rate: \(result)")
        }

        test("million tokens") {
            var tokens = SessionTokens()
            tokens.add(input: 500000, output: 100000, cacheCreation: 0, cacheRead: 1500000)
            let result = formatSessionStats(tokens)
            check(result.contains("2.0M in"), "shows millions: \(result)")
        }
    }

    suite("formatTokenCount millions") {
        test("1M") {
            assertEqual(formatTokenCount(1_000_000), "1.0M")
        }
        test("1.5M") {
            assertEqual(formatTokenCount(1_500_000), "1.5M")
        }
        test("999K stays K") {
            assertEqual(formatTokenCount(999_000), "999K")
        }
    }
}

// MARK: - Daily Usage Tracking Tests

func runDailyUsageTrackingTests() {
    suite("dailyDateString") {
        test("formats date as YYYY-MM-DD") {
            let cal = Calendar.current
            let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 15))!
            assertEqual(dailyDateString(date), "2026-03-15", "date format")
        }
    }

    suite("recordDailyUsage") {
        test("first reading creates entry with zero usage") {
            var store = DailyUsageData()
            let now = Date()
            recordDailyUsage(&store, sevenDayUtilization: 30.0, now: now)
            assertEqual(store.days.count, 1, "one entry")
            assertEqual(store.days[0].usage, 0.0, "first reading delta is 0")
            assertEqual(store.lastUtilization, 30.0, "lastUtilization set")
        }

        test("second reading records delta") {
            var store = DailyUsageData()
            let now = Date()
            recordDailyUsage(&store, sevenDayUtilization: 30.0, now: now)
            recordDailyUsage(&store, sevenDayUtilization: 35.0, now: now)
            assertEqual(store.days.count, 1, "still one entry")
            assertEqual(store.days[0].usage, 5.0, "delta of 5")
        }

        test("accumulates multiple deltas in same day") {
            var store = DailyUsageData()
            let now = Date()
            recordDailyUsage(&store, sevenDayUtilization: 10.0, now: now)
            recordDailyUsage(&store, sevenDayUtilization: 15.0, now: now)
            recordDailyUsage(&store, sevenDayUtilization: 22.0, now: now)
            assertEqual(store.days[0].usage, 12.0, "5 + 7 = 12")
        }

        test("window reset produces zero delta") {
            var store = DailyUsageData()
            let now = Date()
            recordDailyUsage(&store, sevenDayUtilization: 80.0, now: now)
            recordDailyUsage(&store, sevenDayUtilization: 5.0, now: now)
            assertEqual(store.days[0].usage, 0.0, "no negative delta on reset")
            assertEqual(store.lastUtilization, 5.0, "lastUtilization updated after reset")
        }

        test("resumes tracking after window reset") {
            var store = DailyUsageData()
            let now = Date()
            recordDailyUsage(&store, sevenDayUtilization: 80.0, now: now)
            recordDailyUsage(&store, sevenDayUtilization: 5.0, now: now)   // reset
            recordDailyUsage(&store, sevenDayUtilization: 8.0, now: now)   // normal delta
            assertEqual(store.days[0].usage, 3.0, "tracks delta after reset")
        }

        test("new day creates new entry") {
            var store = DailyUsageData()
            let cal = Calendar.current
            let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
            let today = Date()
            recordDailyUsage(&store, sevenDayUtilization: 10.0, now: yesterday)
            recordDailyUsage(&store, sevenDayUtilization: 15.0, now: yesterday)
            recordDailyUsage(&store, sevenDayUtilization: 20.0, now: today)
            assertEqual(store.days.count, 2, "two day entries")
            assertEqual(store.days[0].usage, 5.0, "yesterday usage")
            assertEqual(store.days[1].usage, 5.0, "today usage")
        }

        test("prunes entries older than 7 days") {
            var store = DailyUsageData()
            let cal = Calendar.current
            let oldDate = cal.date(byAdding: .day, value: -8, to: Date())!
            store.days.append(DailyEntry(date: dailyDateString(oldDate), usage: 10.0))
            recordDailyUsage(&store, sevenDayUtilization: 5.0, now: Date())
            check(!store.days.contains(where: { $0.date == dailyDateString(oldDate) }), "old entry pruned")
        }
    }
}

// MARK: - Weekly Chart Tests

func runWeeklyChartTests() {
    suite("weeklyChart") {
        test("nil with no data") {
            assertNil(weeklyChart([]), "nil for empty")
        }

        test("nil when all usage is zero") {
            let days = [DailyEntry(date: dailyDateString(Date()), usage: 0)]
            assertNil(weeklyChart(days), "nil for zero usage")
        }

        test("returns 13-char chart with spaces") {
            let cal = Calendar.current
            var days: [DailyEntry] = []
            for i in 0..<3 {
                let date = cal.date(byAdding: .day, value: -i, to: Date())!
                days.append(DailyEntry(date: dailyDateString(date), usage: Double(i + 1) * 5.0))
            }
            let result = weeklyChart(days)
            assertNotNil(result, "produces chart")
            assertEqual(result!.count, 13, "7 bars + 6 spaces = 13 chars")
        }

        test("highest usage gets highest block") {
            let cal = Calendar.current
            var days: [DailyEntry] = []
            for i in 0..<7 {
                let date = cal.date(byAdding: .day, value: -(6 - i), to: Date())!
                days.append(DailyEntry(date: dailyDateString(date), usage: i == 3 ? 20.0 : 2.0))
            }
            let result = weeklyChart(days)!
            let bars = result.split(separator: " ").map(String.init)
            assertEqual(bars[3], "\u{2588}", "peak day gets highest block")
        }

        test("zero usage days get lowest block") {
            let today = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            let days = [
                DailyEntry(date: dailyDateString(yesterday), usage: 10.0),
                DailyEntry(date: dailyDateString(today), usage: 0),
            ]
            let result = weeklyChart(days)!
            let bars = result.split(separator: " ").map(String.init)
            assertEqual(bars[6], "\u{2581}", "zero usage day gets lowest block")
        }
    }

    suite("weeklyChartLabel") {
        test("returns 13 chars") {
            let label = weeklyChartLabel()
            assertEqual(label.count, 13, "7 letters + 6 spaces = 13 chars")
        }

        test("contains only valid day letters and spaces") {
            let label = weeklyChartLabel()
            let validChars: Set<Character> = ["S", "M", "T", "W", "F", " "]
            for char in label {
                check(validChars.contains(char), "valid char: \(char)")
            }
        }

        test("last letter matches today") {
            let weekday = Calendar.current.component(.weekday, from: Date())
            let letters = ["S", "M", "T", "W", "T", "F", "S"]
            let expected = letters[weekday - 1]
            let label = weeklyChartLabel()
            let lastLetter = String(label.last!)
            assertEqual(lastLetter, expected, "last letter is today")
        }
    }
}

func runAlignedWeeklyColumnsTests() {
    suite("alignedWeeklyColumns") {
        test("single-digit values unchanged") {
            let chart = "▁ ▁ ▁ ▁ ▁ ▁ █"
            let values: [Double] = [0, 0, 0, 0, 0, 0, 9.0]
            let dayLabel = "S M T W T F S"
            let result = alignedWeeklyColumns(chart: chart, values: values, dayLabel: dayLabel)
            assertEqual(result.chart, chart, "chart unchanged for single-digit")
            assertEqual(result.pcts, "· · · · · · 9", "pcts single-digit")
            assertEqual(result.days, dayLabel, "days unchanged for single-digit")
        }

        test("multi-digit values right-justify all columns") {
            let chart = "▁ ▁ ▁ ▁ ▅ █ ▆"
            let values: [Double] = [0, 0, 0, 0, 5.0, 14.0, 12.0]
            let dayLabel = "S M T W T F S"
            let result = alignedWeeklyColumns(chart: chart, values: values, dayLabel: dayLabel)
            assertEqual(result.chart, " ▁  ▁  ▁  ▁  ▅  █  ▆", "chart padded to 2-char columns")
            assertEqual(result.pcts, " ·  ·  ·  ·  5 14 12", "pcts right-justified")
            assertEqual(result.days, " S  M  T  W  T  F  S", "days right-justified")
        }

        test("three-digit values") {
            let chart = "▁ █ ▁ ▁ ▁ ▁ ▁"
            let values: [Double] = [0, 100.0, 0, 0, 0, 0, 0]
            let dayLabel = "S M T W T F S"
            let result = alignedWeeklyColumns(chart: chart, values: values, dayLabel: dayLabel)
            assertEqual(result.pcts.contains("100"), true, "contains 100")
            // All columns should have consistent width
            let pctCols = result.pcts.components(separatedBy: " ").filter { !$0.isEmpty }
            assertEqual(pctCols.count, 7, "7 pct columns")
        }

        test("all zero usage") {
            let chart = "▁ ▁ ▁ ▁ ▁ ▁ ▁"
            let values: [Double] = [0, 0, 0, 0, 0, 0, 0]
            let dayLabel = "S M T W T F S"
            let result = alignedWeeklyColumns(chart: chart, values: values, dayLabel: dayLabel)
            assertEqual(result.pcts, "· · · · · · ·", "all dots for zero usage")
            assertEqual(result.chart, chart, "chart unchanged")
        }
    }
}

// MARK: - Merge & iCloud Tests

func runMergeDailyEntriesTests() {
    suite("mergeDailyEntries") {
        test("empty input") {
            let result = mergeDailyEntries([])
            assertEqual(result.count, 0, "empty merge")
        }

        test("single device") {
            let days = [
                DailyEntry(date: "2026-03-18", usage: 5.0),
                DailyEntry(date: "2026-03-19", usage: 3.0),
            ]
            let result = mergeDailyEntries([days])
            assertEqual(result.count, 2, "two days")
            assertEqual(result[0].usage, 5.0, "first day")
            assertEqual(result[1].usage, 3.0, "second day")
        }

        test("two devices same days") {
            let device1 = [
                DailyEntry(date: "2026-03-18", usage: 5.0),
                DailyEntry(date: "2026-03-19", usage: 3.0),
            ]
            let device2 = [
                DailyEntry(date: "2026-03-18", usage: 8.0),
                DailyEntry(date: "2026-03-19", usage: 2.0),
            ]
            let result = mergeDailyEntries([device1, device2])
            assertEqual(result.count, 2, "two days merged")
            assertEqual(result[0].usage, 13.0, "day 18: 5+8")
            assertEqual(result[1].usage, 5.0, "day 19: 3+2")
        }

        test("two devices different days") {
            let device1 = [DailyEntry(date: "2026-03-18", usage: 5.0)]
            let device2 = [DailyEntry(date: "2026-03-19", usage: 8.0)]
            let result = mergeDailyEntries([device1, device2])
            assertEqual(result.count, 2, "two separate days")
            assertEqual(result[0].date, "2026-03-18", "sorted by date")
            assertEqual(result[1].date, "2026-03-19", "sorted by date")
        }

        test("three devices") {
            let d1 = [DailyEntry(date: "2026-03-19", usage: 3.0)]
            let d2 = [DailyEntry(date: "2026-03-19", usage: 7.0)]
            let d3 = [DailyEntry(date: "2026-03-19", usage: 2.0)]
            let result = mergeDailyEntries([d1, d2, d3])
            assertEqual(result.count, 1, "one day")
            assertEqual(result[0].usage, 12.0, "3+7+2")
        }
    }

    suite("deviceId") {
        test("is not empty") {
            check(!deviceId.isEmpty, "deviceId should not be empty")
        }

        test("contains only lowercase alphanumerics and dashes") {
            for char in deviceId {
                let valid = char.isLetter || char.isNumber || char == "-"
                check(valid, "valid char: \(char)")
                if char.isLetter {
                    check(char.isLowercase, "lowercase: \(char)")
                }
            }
        }
    }
}

// MARK: - Parse Bash Uses Tests

func runParseBashUsesTests() {
    suite("parseBashUses") {
        test("counts single Bash tool_use") {
            let json = Data("""
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
            """.utf8)
            assertEqual(parseBashUses(from: json), 1)
        }
        test("counts multiple Bash tool_use blocks") {
            let json = Data("""
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pwd"}}]}}
            """.utf8)
            assertEqual(parseBashUses(from: json), 2)
        }
        test("ignores non-Bash tools") {
            let json = Data("""
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}]}}
            """.utf8)
            assertEqual(parseBashUses(from: json), 1)
        }
        test("returns 0 for user messages") {
            let json = Data("""
            {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
            """.utf8)
            assertEqual(parseBashUses(from: json), 0)
        }
        test("returns 0 for no content") {
            let json = Data("""
            {"type":"assistant","message":{"content":[]}}
            """.utf8)
            assertEqual(parseBashUses(from: json), 0)
        }
        test("returns 0 for invalid JSON") {
            assertEqual(parseBashUses(from: Data("bad".utf8)), 0)
        }
    }
}

// MARK: - Parse Context Window Tests

func runParseContextWindowTests() {
    suite("parseContextWindow") {
        test("returns context_window and token sum") {
            let json = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"context_window":200000}}}
            """.utf8)
            let result = parseContextWindow(from: json)
            assertNotNil(result)
            assertEqual(result!.contextTokens, 4200)
            assertEqual(result!.contextMax, 200000)
        }
        test("falls back to model default when no context_window field") {
            let json = Data("""
            {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":5000,"output_tokens":500,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000}}}
            """.utf8)
            let result = parseContextWindow(from: json)
            assertNotNil(result)
            assertEqual(result!.contextTokens, 8000)
            assertEqual(result!.contextMax, 200000)
        }
        test("returns nil when no usage block") {
            let json = Data("""
            {"type":"assistant","message":{"model":"claude-sonnet-4-6"}}
            """.utf8)
            assertNil(parseContextWindow(from: json))
        }
        test("returns nil when all tokens zero and no context_window") {
            let json = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":0,"output_tokens":500}}}
            """.utf8)
            assertNil(parseContextWindow(from: json))
        }
        test("returns nil for invalid JSON") {
            assertNil(parseContextWindow(from: Data("not json".utf8)))
        }
        test("uses top-level usage as fallback") {
            let json = Data("""
            {"usage":{"input_tokens":3000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"context_window":200000}}
            """.utf8)
            let result = parseContextWindow(from: json)
            assertNotNil(result)
            assertEqual(result!.contextTokens, 3000)
            assertEqual(result!.contextMax, 200000)
        }
        test("infers 1M context when tokens exceed 200K and no context_window") {
            let json = Data("""
            {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":100000,"output_tokens":500,"cache_creation_input_tokens":50000,"cache_read_input_tokens":202000}}}
            """.utf8)
            let result = parseContextWindow(from: json)
            assertNotNil(result)
            assertEqual(result!.contextTokens, 352000)
            assertEqual(result!.contextMax, 1_000_000)
        }
    }
}

// MARK: - Model Max Context Tokens Tests

func runModelMaxContextTokensTests() {
    suite("modelMaxContextTokens") {
        test("returns 200K for standard context") {
            assertEqual(modelMaxContextTokens("claude-opus-4-6"), 200_000)
            assertEqual(modelMaxContextTokens("claude-sonnet-4-6"), 200_000)
            assertEqual(modelMaxContextTokens("claude-haiku-4-5"), 200_000)
            assertEqual(modelMaxContextTokens("unknown-model"), 200_000)
        }
        test("returns 200K when observed tokens within 200K") {
            assertEqual(modelMaxContextTokens("claude-opus-4-6", observedTokens: 150_000), 200_000)
            assertEqual(modelMaxContextTokens("claude-opus-4-6", observedTokens: 200_000), 200_000)
        }
        test("returns 1M when observed tokens exceed 200K") {
            assertEqual(modelMaxContextTokens("claude-opus-4-6", observedTokens: 200_001), 1_000_000)
            assertEqual(modelMaxContextTokens("claude-opus-4-6", observedTokens: 352_000), 1_000_000)
            assertEqual(modelMaxContextTokens("claude-opus-4-6", observedTokens: 999_999), 1_000_000)
        }
    }
}

// MARK: - TrackedSession Tests

func runTrackedSessionTests() {
    suite("TrackedSession") {
        test("init sets projectName from path") {
            let home = NSHomeDirectory()
            let encodedHome = home.replacingOccurrences(of: "/", with: "-")
            let session = TrackedSession(path: "\(home)/.claude/projects/\(encodedHome)-Projects-my-app/abc.jsonl")
            assertEqual(session.projectName, "my-app")
        }
        test("processNewData accumulates tokens") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let line = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":20}}}
            """.utf8)
            let changed = session.processNewData(line)
            check(changed, "should report change")
            assertEqual(session.sessionTokens.inputTokens, 100)
            assertEqual(session.sessionTokens.outputTokens, 50)
        }
        test("processNewData tracks model") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let line = Data("""
            {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}}}
            """.utf8)
            _ = session.processNewData(line)
            assertEqual(session.currentModel, "claude-sonnet-4-6")
        }
        test("processNewData counts bash uses") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let line = Data("""
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pwd"}}]}}
            """.utf8)
            _ = session.processNewData(line)
            assertEqual(session.shellRequestCount, 2)
        }
        test("processNewData tracks context window") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let line = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":5000,"output_tokens":500,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000,"context_window":200000}}}
            """.utf8)
            _ = session.processNewData(line)
            assertEqual(session.lastContextTokens, 8000)
            assertEqual(session.contextWindowMax, 200000)
        }
        test("processNewData never downgrades contextWindowMax") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let line1 = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":100000,"output_tokens":500,"cache_creation_input_tokens":50000,"cache_read_input_tokens":200000,"context_window":1000000}}}
            """.utf8)
            _ = session.processNewData(line1)
            assertEqual(session.contextWindowMax, 1_000_000)
            let line2 = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":5000,"output_tokens":500,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000,"context_window":200000}}}
            """.utf8)
            _ = session.processNewData(line2)
            assertEqual(session.contextWindowMax, 1_000_000, "should not downgrade from 1M to 200K")
        }
        test("processNewData returns false for empty data") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let changed = session.processNewData(Data())
            check(!changed, "empty data should not change state")
        }
        test("hasDisplayableData is false initially") {
            let session = TrackedSession(path: "/tmp/test.jsonl")
            check(!session.hasDisplayableData, "new session has no data")
        }
        test("hasDisplayableData is true after tokens") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let line = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":5}}}
            """.utf8)
            _ = session.processNewData(line)
            check(session.hasDisplayableData, "session with tokens has data")
        }
        test("isStale returns false when no lastFileModification") {
            let session = TrackedSession(path: "/tmp/test.jsonl")
            check(!session.isStale, "no modification date = not stale")
        }
        test("isStale returns false when no data") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            session.lastFileModification = Date().addingTimeInterval(-600)
            check(!session.isStale, "no data = not stale")
        }
        test("isStale returns true when threshold exceeded with data no agents") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            _ = session.processNewData(Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50}}}
            """.utf8))
            session.lastFileModification = Date().addingTimeInterval(-600)
            check(session.isStale, "old data with no agents = stale")
        }
        test("isStale returns false when active agents present") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            _ = session.processNewData(Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50}}}
            """.utf8))
            session.agents.append(TrackedAgent(toolUseId: "t1", description: "test", subagentType: "general", launchedAt: Date()))
            session.lastFileModification = Date().addingTimeInterval(-600)
            check(!session.isStale, "active agent = not stale")
        }
        test("processNewData handles multiple lines") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            let lines = Data("""
            {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":50}}}
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
            """.utf8)
            _ = session.processNewData(lines)
            assertEqual(session.currentModel, "claude-opus-4-6")
            assertEqual(session.sessionTokens.inputTokens, 100)
            assertEqual(session.shellRequestCount, 1)
        }
    }
}


func runAdaptiveStatusLineTests() {
    suite("formatAdaptiveStatusLine") {
        test("normal state under 80% returns same as formatStatusLine") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 20.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 30.0, remaining: nil, resetsAt: nil)
            )
            let adaptive = formatAdaptiveStatusLine(usage: u)
            let normal = formatStatusLine(u)
            assertEqual(adaptive, normal)
        }

        test("depleted state returns depleted string") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 50.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil)
            )
            let result = formatAdaptiveStatusLine(usage: u)
            assertEqual(result, "\u{2716} depleted")
        }

        test("over 100% returns depleted") {
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 100.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 120.0, remaining: nil, resetsAt: nil)
            )
            let result = formatAdaptiveStatusLine(usage: u)
            assertEqual(result, "\u{2716} depleted")
        }

        test("warning state returns time left when will deplete before window resets") {
            let now = Date()
            // 7-day window, 95% used, 1 day elapsed, 6 days remaining
            // ratePerSec = 95 / 86400 ≈ 0.001099/sec
            // secsToFull = 5 / 0.001099 ≈ 4550s ≈ 1.26h
            // remaining = 6*86400 = 518400s >> secsToFull → WILL DEPLETE → warning
            let resetsAt = now.addingTimeInterval(6 * 86400)
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 50.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 95.0, remaining: nil, resetsAt: resetsAt)
            )
            let result = formatAdaptiveStatusLine(usage: u, now: now)
            check(result.hasPrefix("\u{26A0}"), "warning should start with ⚠: got \(result)")
            check(result.contains("left"), "warning should contain 'left': got \(result)")
        }

        test("no depletion expected returns normal format") {
            let now = Date()
            // 7-day window, 5% used, only 2 hours remaining
            // elapsed = 7*86400 - 2*3600 = 597600s
            // ratePerSec = 5 / 597600 ≈ 0.0000084/sec
            // secsToFull = 95 / 0.0000084 ≈ 11.3M sec >> 7200s remaining → won't deplete
            let resetsAt = now.addingTimeInterval(2 * 3600)
            let u = UsageData(
                fiveHour: UsageWindow(utilization: 5.0, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 5.0, remaining: nil, resetsAt: resetsAt)
            )
            let result = formatAdaptiveStatusLine(usage: u, now: now)
            let normal = formatStatusLine(u)
            assertEqual(result, normal)
        }

        test("warning format hours and minutes") {
            // secsToFull = 2.5 hours = 9000s
            let secsToFull = 9000.0
            let result = formatDepletionTime(secsToFull: secsToFull)
            assertEqual(result, "2h 30m")
        }

        test("warning format days") {
            let secsToFull = 25 * 3600.0
            let result = formatDepletionTime(secsToFull: secsToFull)
            assertEqual(result, "1d 1h")
        }

        test("warning format minutes only") {
            let secsToFull = 45 * 60.0
            let result = formatDepletionTime(secsToFull: secsToFull)
            assertEqual(result, "45m")
        }
    }
}

// MARK: - SHA-256 Tests

func runSHA256Tests() {
    suite("sha256hex") {
        test("known vector") {
            // SHA-256 of empty string
            assertEqual(sha256hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }

        test("hello world") {
            assertEqual(sha256hex("hello"), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        }

        test("deterministic") {
            let a = sha256hex("test-token")
            let b = sha256hex("test-token")
            assertEqual(a, b)
        }

        test("different inputs differ") {
            let a = sha256hex("token-a")
            let b = sha256hex("token-b")
            check(a != b, "different inputs should produce different hashes")
        }

        test("returns 64 hex chars") {
            let result = sha256hex("anything")
            assertEqual(result.count, 64)
            for c in result {
                check("0123456789abcdef".contains(c), "hex char: \(c)")
            }
        }
    }
}

// MARK: - Build Widget Data Tests

func runBuildWidgetDataTests() {
    suite("buildWidgetData") {
        test("maps usage fields") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 45.2, remaining: nil, resetsAt: Date(timeIntervalSince1970: 1700000000)),
                sevenDay: UsageWindow(utilization: 32.1, remaining: nil, resetsAt: Date(timeIntervalSince1970: 1700100000))
            )
            let widget = buildWidgetData(usage)
            assertEqual(widget.fiveHourUtilization, 45.2)
            assertEqual(widget.sevenDayUtilization, 32.1)
            assertEqual(widget.fiveHourResetsAt, 1700000000)
            assertEqual(widget.sevenDayResetsAt, 1700100000)
            check(widget.updatedAt > 0, "updatedAt should be set")
        }

        test("encodes to JSON") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil)
            )
            let widget = buildWidgetData(usage)
            let data = try? JSONEncoder().encode(widget)
            check(data != nil, "should encode to JSON")
        }
    }
}

// MARK: - Compact Reset Time Tests

func runCompactResetTimeTests() {
    suite("compactResetTime") {
        let now = Date()

        test("nil date returns nil") {
            assertNil(compactResetTime(nil, relativeTo: now), "nil date")
        }

        test("past date returns nil") {
            let past = now.addingTimeInterval(-60)
            assertNil(compactResetTime(past, relativeTo: now), "past date")
        }

        test("minutes only") {
            let future = now.addingTimeInterval(45 * 60)
            assertEqual(compactResetTime(future, relativeTo: now), "45m", "45 minutes")
        }

        test("exact hours") {
            let future = now.addingTimeInterval(3 * 3600)
            assertEqual(compactResetTime(future, relativeTo: now), "3h", "exact 3 hours")
        }

        test("hours and minutes") {
            let future = now.addingTimeInterval(3 * 3600 + 5 * 60)
            assertEqual(compactResetTime(future, relativeTo: now), "3h 5m", "3h 5m")
        }

        test("sub-minute returns 0m") {
            let future = now.addingTimeInterval(30)
            assertEqual(compactResetTime(future, relativeTo: now), "0m", "sub-minute")
        }

        test("multi-day") {
            let future = now.addingTimeInterval(2 * 86400 + 21 * 3600)
            assertEqual(compactResetTime(future, relativeTo: now), "2d 21h", "2d 21h")
        }

        test("multi-day exact days") {
            let future = now.addingTimeInterval(3 * 86400)
            assertEqual(compactResetTime(future, relativeTo: now), "3d", "exact 3 days")
        }
    }
}

// MARK: - Compact Five Hour Tests

func runCompactFiveHourTests() {
    suite("formatCompactFiveHour") {
        let now = Date()

        test("no segments — nil resetsAt, no sparkline, nil extra") {
            let window = UsageWindow(utilization: 19.0, remaining: nil, resetsAt: nil)
            let result = formatCompactFiveHour(window: window, sparkline: nil, extraUsage: nil, now: now)
            assertEqual(result, "5h: 19%", "basic no segments")
        }

        test("with reset") {
            let resetsAt = now.addingTimeInterval(3 * 3600 + 5 * 60)
            let window = UsageWindow(utilization: 19.0, remaining: nil, resetsAt: resetsAt)
            let result = formatCompactFiveHour(window: window, sparkline: nil, extraUsage: nil, now: now)
            check(result.contains("resets 3h 5m"), "should contain reset time: \(result)")
        }

        test("with pace and reset") {
            // For pace to work, resetsAt must be within 5h window
            let resetsAt = now.addingTimeInterval(3 * 3600) // 3h remaining = 2h elapsed in 5h window
            let window = UsageWindow(utilization: 30.0, remaining: nil, resetsAt: resetsAt)
            let result = formatCompactFiveHour(window: window, sparkline: nil, extraUsage: nil, now: now)
            check(result.contains("5h: 30%"), "should contain pct: \(result)")
            check(result.contains("x"), "should contain pace: \(result)")
            check(result.contains("resets 3h"), "should contain reset: \(result)")
        }

        test("with sparkline") {
            let window = UsageWindow(utilization: 19.0, remaining: nil, resetsAt: nil)
            let result = formatCompactFiveHour(window: window, sparkline: "\u{2581}\u{2582}\u{2583}", extraUsage: nil, now: now)
            check(result.contains("\u{2581}\u{2582}\u{2583}"), "should contain sparkline: \(result)")
        }

        test("with extra enabled") {
            let window = UsageWindow(utilization: 19.0, remaining: nil, resetsAt: nil)
            let extra = ExtraUsage(isEnabled: true, utilization: nil)
            let result = formatCompactFiveHour(window: window, sparkline: nil, extraUsage: extra, now: now)
            check(result.contains("Extra on"), "should contain Extra on: \(result)")
        }

        test("with extra disabled — not shown") {
            let window = UsageWindow(utilization: 19.0, remaining: nil, resetsAt: nil)
            let extra = ExtraUsage(isEnabled: false, utilization: nil)
            let result = formatCompactFiveHour(window: window, sparkline: nil, extraUsage: extra, now: now)
            check(!result.contains("Extra"), "should not contain Extra: \(result)")
        }

        test("full combination") {
            let resetsAt = now.addingTimeInterval(3 * 3600 + 5 * 60)
            let window = UsageWindow(utilization: 19.0, remaining: nil, resetsAt: resetsAt)
            let extra = ExtraUsage(isEnabled: true, utilization: nil)
            let result = formatCompactFiveHour(window: window, sparkline: "\u{2581}\u{2582}\u{2583}", extraUsage: extra, now: now)
            check(result.hasPrefix("5h: 19%"), "should start with pct: \(result)")
            check(result.contains("resets 3h 5m"), "should contain reset: \(result)")
            check(result.contains("Extra on"), "should contain extra: \(result)")
            check(result.contains("\u{2581}\u{2582}\u{2583}"), "should contain sparkline: \(result)")
        }

        test("decimal percentage") {
            let window = UsageWindow(utilization: 19.5, remaining: nil, resetsAt: nil)
            let result = formatCompactFiveHour(window: window, sparkline: nil, extraUsage: nil, now: now)
            assertEqual(result, "5h: 19.5%", "decimal pct")
        }
    }
}

// MARK: - Forecast Line Tests

func runForecastLineTests() {
    suite("formatForecastLine") {
        let now = Date()

        test("nil resetsAt") {
            assertNil(formatForecastLine(utilization: 20, resetsAt: nil, windowDuration: 7 * 86400, now: now), "nil resetsAt")
        }

        test("barely elapsed (<60s)") {
            let resetsAt = now.addingTimeInterval(7 * 86400 - 30) // only 30s elapsed
            assertNil(formatForecastLine(utilization: 5, resetsAt: resetsAt, windowDuration: 7 * 86400, now: now), "barely elapsed")
        }

        test("near-zero utilization") {
            let resetsAt = now.addingTimeInterval(5 * 86400) // 2 days elapsed
            assertNil(formatForecastLine(utilization: 0.05, resetsAt: resetsAt, windowDuration: 7 * 86400, now: now), "near-zero util")
        }

        test("remaining > windowDuration") {
            let resetsAt = now.addingTimeInterval(8 * 86400) // more than 7 days
            assertNil(formatForecastLine(utilization: 20, resetsAt: resetsAt, windowDuration: 7 * 86400, now: now), "remaining > window")
        }

        test("depleted at 100") {
            let resetsAt = now.addingTimeInterval(3 * 86400)
            assertEqual(formatForecastLine(utilization: 100, resetsAt: resetsAt, windowDuration: 7 * 86400, now: now), "Depleted", "depleted 100")
        }

        test("depleted over 100") {
            let resetsAt = now.addingTimeInterval(3 * 86400)
            assertEqual(formatForecastLine(utilization: 110, resetsAt: resetsAt, windowDuration: 7 * 86400, now: now), "Depleted", "depleted >100")
        }

        test("safe state") {
            // 20% used in 4 days, 3 days left => rate 5%/day, budget ~26.7%/day => safe
            let resetsAt = now.addingTimeInterval(3 * 86400)
            let result = formatForecastLine(utilization: 20, resetsAt: resetsAt, windowDuration: 7 * 86400, now: now)
            assertNotNil(result, "should return forecast")
            check(result!.hasPrefix("Safe"), "should be safe: \(result!)")
            check(result!.contains("/day of"), "should contain rate info: \(result!)")
            check(result!.contains("/day budget"), "should contain budget info: \(result!)")
        }

        test("depleting state") {
            // 90% used in 4 days, 3 days left => rate 22.5%/day, budget ~3.3%/day => depleting
            let resetsAt = now.addingTimeInterval(3 * 86400)
            let result = formatForecastLine(utilization: 90, resetsAt: resetsAt, windowDuration: 7 * 86400, now: now)
            assertNotNil(result, "should return forecast")
            check(result!.hasPrefix("Depletes in ~"), "should be depleting: \(result!)")
            check(result!.contains("/day of"), "should contain rate info: \(result!)")
        }
    }
}

// MARK: - Codex Tests

func runCodexTests() {
    suite("CodexThread") {
        test("projectName extracts last path component") {
            let thread = CodexThread(id: "1", title: "test", model: nil, tokensUsed: 0,
                createdAt: Date(), updatedAt: Date(), cwd: "/Users/me/Projects/myapp")
            assertEqual(thread.projectName, "myapp")
        }
        test("projectName returns cwd if empty last component") {
            let thread = CodexThread(id: "1", title: "test", model: nil, tokensUsed: 0,
                createdAt: Date(), updatedAt: Date(), cwd: "")
            assertEqual(thread.projectName, "")
        }
        test("isActive within threshold") {
            let now = Date()
            let thread = CodexThread(id: "1", title: "test", model: nil, tokensUsed: 0,
                createdAt: now, updatedAt: now.addingTimeInterval(-60), cwd: "/tmp")
            check(thread.isActive(now: now), "should be active within 5 min")
        }
        test("isActive beyond threshold") {
            let now = Date()
            let thread = CodexThread(id: "1", title: "test", model: nil, tokensUsed: 0,
                createdAt: now, updatedAt: now.addingTimeInterval(-600), cwd: "/tmp")
            check(!thread.isActive(now: now), "should not be active after 10 min")
        }
        test("isActive with custom threshold") {
            let now = Date()
            let thread = CodexThread(id: "1", title: "test", model: nil, tokensUsed: 0,
                createdAt: now, updatedAt: now.addingTimeInterval(-30), cwd: "/tmp")
            check(!thread.isActive(now: now, threshold: 10), "should not be active with 10s threshold")
        }
    }

    suite("buildCodexSummary") {
        test("empty array returns nil") {
            assertNil(buildCodexSummary(from: []))
        }
        test("calculates today tokens and sessions") {
            let now = Date()
            let t1 = CodexThread(id: "1", title: "a", model: "o3", tokensUsed: 5000,
                createdAt: now, updatedAt: now.addingTimeInterval(-60), cwd: "/tmp/p1")
            let t2 = CodexThread(id: "2", title: "b", model: "o3", tokensUsed: 3000,
                createdAt: now, updatedAt: now.addingTimeInterval(-10), cwd: "/tmp/p2")
            let summary = buildCodexSummary(from: [t1, t2], now: now)!
            assertEqual(summary.todayTokens, 8000, "today tokens")
            assertEqual(summary.todaySessions, 2, "today sessions")
        }
        test("identifies active sessions") {
            let now = Date()
            let active = CodexThread(id: "1", title: "a", model: "o3", tokensUsed: 1000,
                createdAt: now, updatedAt: now.addingTimeInterval(-10), cwd: "/tmp/p1")
            let inactive = CodexThread(id: "2", title: "b", model: "o3", tokensUsed: 2000,
                createdAt: now, updatedAt: now.addingTimeInterval(-600), cwd: "/tmp/p2")
            let summary = buildCodexSummary(from: [active, inactive], now: now)!
            assertEqual(summary.activeSessions.count, 1, "only 1 active")
            assertEqual(summary.activeSessions.first?.id, "1", "correct active session")
        }
        test("multi-day thread buckets by createdAt not updatedAt") {
            let now = Date()
            let cal = Calendar.current
            let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
            // Thread created yesterday but updated today — tokens should count under yesterday
            let t = CodexThread(id: "1", title: "long-running", model: "o3", tokensUsed: 5000,
                createdAt: yesterday, updatedAt: now, cwd: "/tmp")
            let summary = buildCodexSummary(from: [t], now: now)!
            assertEqual(summary.todayTokens, 0, "should not count in today")
            assertEqual(summary.todaySessions, 0, "should not count as today session")
        }
        test("stale-only codex returns non-nil but empty active") {
            let now = Date()
            let cal = Calendar.current
            let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: now)!
            let t = CodexThread(id: "1", title: "old", model: "o3", tokensUsed: 1000,
                createdAt: twoDaysAgo, updatedAt: twoDaysAgo, cwd: "/tmp")
            let summary = buildCodexSummary(from: [t], now: now)!
            assertEqual(summary.todaySessions, 0, "no today sessions")
            assertEqual(summary.activeSessions.count, 0, "no active sessions")
        }
    }

}

// MARK: - Unified Sessions Tests

func runFormatUnifiedSessionsTests() {
    suite("formatUnifiedSessions") {
        test("empty state returns empty") {
            let result = formatUnifiedSessions(claudeSessions: [], codex: nil)
            assertEqual(result, "")
        }
        test("Claude session shows directly") {
            var session = TrackedSession(path: "/tmp/test.jsonl")
            _ = session.processNewData(Data("""
            {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":10000,"output_tokens":1000}}}
            """.utf8))
            let result = formatUnifiedSessions(claudeSessions: [session], codex: nil)
            check(!result.contains("Codex"), "should not mention Codex: \(result)")
            check(result.contains("Opus 4.6"), "should show model: \(result)")
            check(result.contains("11K tok"), "should show tokens: \(result)")
        }
        test("Codex session shows directly") {
            let now = Date()
            let thread = CodexThread(id: "1", title: "fix bug", model: "o3", tokensUsed: 5000,
                createdAt: now, updatedAt: now.addingTimeInterval(-10), cwd: "/tmp/myproject")
            let codex = buildCodexSummary(from: [thread], now: now)!
            let result = formatUnifiedSessions(claudeSessions: [], codex: codex, now: now)
            check(result.contains("Codex"), "should have Codex label: \(result)")
            check(result.contains("myproject"), "should show project name: \(result)")
            check(result.contains("5K tok"), "should show tokens: \(result)")
        }
        test("both providers shown together") {
            let now = Date()
            var session = TrackedSession(path: "/tmp/test.jsonl")
            _ = session.processNewData(Data("""
            {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000}}}
            """.utf8))
            let thread = CodexThread(id: "1", title: "test", model: "o3", tokensUsed: 3000,
                createdAt: now, updatedAt: now.addingTimeInterval(-10), cwd: "/tmp/proj")
            let codex = buildCodexSummary(from: [thread], now: now)!
            let result = formatUnifiedSessions(claudeSessions: [session], codex: codex, now: now)
            check(result.contains("Sonnet 4.6"), "has Claude session: \(result)")
            check(result.contains("Codex"), "has Codex session: \(result)")
        }
        test("task name display for running agents") {
            let now = Date()
            var session = TrackedSession(path: "/tmp/test.jsonl")
            _ = session.processNewData(Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":100}}}
            """.utf8))
            session.agents.append(TrackedAgent(toolUseId: "t1", description: "Review code", subagentType: "code-review", launchedAt: now))
            let result = formatUnifiedSessions(claudeSessions: [session], codex: nil, now: now)
            check(result.contains("\u{270E} Review code"), "should show pencil + task: \(result)")
        }
        test("completed agents not shown with pencil") {
            let now = Date()
            var session = TrackedSession(path: "/tmp/test.jsonl")
            _ = session.processNewData(Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":100}}}
            """.utf8))
            var agent = TrackedAgent(toolUseId: "t1", description: "Done task", subagentType: "helper", launchedAt: now.addingTimeInterval(-60))
            agent.completedAt = now.addingTimeInterval(-30)
            session.agents.append(agent)
            let result = formatUnifiedSessions(claudeSessions: [session], codex: nil, now: now)
            check(!result.contains("\u{270E}"), "completed agents should not have pencil: \(result)")
        }
    }

}

// MARK: - Extended Widget Data Tests

func runExtendedWidgetDataTests() {
    suite("buildWidgetData with model breakdown") {
        test("includes opus and sonnet utilization") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 30, remaining: nil, resetsAt: nil),
                models: ModelBreakdown(opus: UsageWindow(utilization: 60, remaining: nil, resetsAt: nil), sonnet: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil), oauthApps: nil, cowork: nil)
            )
            let widget = buildWidgetData(usage)
            assertEqual(widget.opusUtilization, 60, "opus utilization")
            assertEqual(widget.sonnetUtilization, 20, "sonnet utilization")
            assertNil(widget.haikuUtilization, "haiku not in model breakdown")
        }

        test("nil models produce nil utilization") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 5, remaining: nil, resetsAt: nil)
            )
            let widget = buildWidgetData(usage)
            assertNil(widget.opusUtilization, "no opus")
            assertNil(widget.sonnetUtilization, "no sonnet")
        }

        test("extra usage utilization included") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 5, remaining: nil, resetsAt: nil),
                extraUsage: ExtraUsage(isEnabled: true, utilization: 42.5)
            )
            let widget = buildWidgetData(usage)
            assertEqual(widget.extraUsageUtilization, 42.5, "extra usage utilization")
        }
    }

    suite("buildWidgetData with daily entries") {
        test("maps daily entries") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 5, remaining: nil, resetsAt: nil)
            )
            let entries = [
                DailyEntry(date: "2026-04-07", usage: 12.5),
                DailyEntry(date: "2026-04-08", usage: 8.0),
            ]
            let widget = buildWidgetData(usage, dailyEntries: entries)
            assertEqual(widget.dailyEntries?.count, 2, "two entries")
            assertEqual(widget.dailyEntries?[0].date, "2026-04-07", "first date")
            assertEqual(widget.dailyEntries?[0].usage, 12.5, "first usage")
            assertEqual(widget.dailyEntries?[1].date, "2026-04-08", "second date")
        }

        test("nil daily entries") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 5, remaining: nil, resetsAt: nil)
            )
            let widget = buildWidgetData(usage)
            assertNil(widget.dailyEntries, "no daily entries")
        }
    }

    suite("hasSameValues with new fields") {
        test("same values returns true") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 50, remaining: nil, resetsAt: Date(timeIntervalSince1970: 1700000000)),
                sevenDay: UsageWindow(utilization: 30, remaining: nil, resetsAt: Date(timeIntervalSince1970: 1700100000)),
                models: ModelBreakdown(opus: UsageWindow(utilization: 60, remaining: nil, resetsAt: nil), sonnet: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil), oauthApps: nil, cowork: nil)
            )
            let entries = [DailyEntry(date: "2026-04-08", usage: 5.0)]
            let a = buildWidgetData(usage, dailyEntries: entries)
            let b = buildWidgetData(usage, dailyEntries: entries)
            check(a.hasSameValues(as: b), "identical builds should match")
        }

        test("different opus utilization returns false") {
            let usage1 = UsageData(
                fiveHour: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 30, remaining: nil, resetsAt: nil),
                models: ModelBreakdown(opus: UsageWindow(utilization: 60, remaining: nil, resetsAt: nil), sonnet: nil, oauthApps: nil, cowork: nil)
            )
            let usage2 = UsageData(
                fiveHour: UsageWindow(utilization: 50, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 30, remaining: nil, resetsAt: nil),
                models: ModelBreakdown(opus: UsageWindow(utilization: 70, remaining: nil, resetsAt: nil), sonnet: nil, oauthApps: nil, cowork: nil)
            )
            let a = buildWidgetData(usage1)
            let b = buildWidgetData(usage2)
            check(!a.hasSameValues(as: b), "different opus should differ")
        }

        test("different daily entries returns false") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 5, remaining: nil, resetsAt: nil)
            )
            let a = buildWidgetData(usage, dailyEntries: [DailyEntry(date: "2026-04-08", usage: 5.0)])
            let b = buildWidgetData(usage, dailyEntries: [DailyEntry(date: "2026-04-08", usage: 10.0)])
            check(!a.hasSameValues(as: b), "different daily entries should differ")
        }
    }

    suite("WidgetData v3 JSON encoding") {
        test("encodes new fields to JSON") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil),
                models: ModelBreakdown(opus: UsageWindow(utilization: 55, remaining: nil, resetsAt: nil), sonnet: nil, oauthApps: nil, cowork: nil),
                extraUsage: ExtraUsage(isEnabled: true, utilization: 12.5)
            )
            let entries = [DailyEntry(date: "2026-04-08", usage: 7.5)]
            let widget = buildWidgetData(usage, dailyEntries: entries)
            let data = try? JSONEncoder().encode(widget)
            check(data != nil, "should encode to JSON")
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                assertEqual(json["opusUtilization"] as? Double, 55, "opus in JSON")
                assertEqual(json["extraUsageUtilization"] as? Double, 12.5, "extra usage in JSON")
                assertNotNil(json["dailyEntries"], "dailyEntries in JSON")
            }
        }
    }
}

// MARK: - Codesign Parsing Tests

func runCodesignParsingTests() {
    suite("teamIdentifier(fromCodesignOutput:)") {
        test("extracts standard TeamIdentifier line") {
            let out = """
            Executable=/Applications/Foo.app/Contents/MacOS/Foo
            Identifier=com.example.foo
            Format=app bundle with Mach-O thin (arm64)
            TeamIdentifier=ABCD1234EF
            Signature size=9000
            """
            assertEqual(teamIdentifier(fromCodesignOutput: out), "ABCD1234EF", "parses team id")
        }

        test("handles `not set` as nil (ad-hoc signed)") {
            let out = "TeamIdentifier=not set"
            assertNil(teamIdentifier(fromCodesignOutput: out), "ad-hoc signed -> nil")
        }

        test("missing TeamIdentifier line is nil") {
            let out = "Identifier=com.example.foo\nFormat=app bundle"
            assertNil(teamIdentifier(fromCodesignOutput: out), "absent -> nil")
        }

        test("ignores other `=` keys") {
            let out = "Identifier=com.example.foo=confusing\nTeamIdentifier=ZZ9999WW99"
            assertEqual(teamIdentifier(fromCodesignOutput: out), "ZZ9999WW99", "doesn't confuse with other = fields")
        }
    }
}

// MARK: - Widget Push Heartbeat Tests

func runWidgetHeartbeatTests() {
    suite("shouldPushWidget") {
        let usage = UsageData(
            fiveHour: UsageWindow(utilization: 25, remaining: nil, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil)
        )
        let changedUsage = UsageData(
            fiveHour: UsageWindow(utilization: 40, remaining: nil, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil)
        )

        test("first push (no prior state) pushes") {
            let widget = buildWidgetData(usage)
            check(shouldPushWidget(now: Date(), current: widget, lastPushed: nil, lastPushedAt: nil),
                  "no prior state must push")
        }

        test("unchanged values within heartbeat window skip") {
            let now = Date()
            let a = buildWidgetData(usage)
            let b = buildWidgetData(usage)
            check(!shouldPushWidget(now: now, current: b, lastPushed: a, lastPushedAt: now.addingTimeInterval(-60)),
                  "60s old identical push must be skipped under 300s heartbeat")
        }

        test("unchanged values past heartbeat interval push") {
            let now = Date()
            let a = buildWidgetData(usage)
            let b = buildWidgetData(usage)
            check(shouldPushWidget(now: now, current: b, lastPushed: a, lastPushedAt: now.addingTimeInterval(-600)),
                  "10 min since last push must trigger heartbeat")
        }

        test("changed values push immediately even within heartbeat") {
            let now = Date()
            let a = buildWidgetData(usage)
            let b = buildWidgetData(changedUsage)
            check(shouldPushWidget(now: now, current: b, lastPushed: a, lastPushedAt: now.addingTimeInterval(-10)),
                  "value change must push without waiting")
        }

        test("custom heartbeat interval honored") {
            let now = Date()
            let a = buildWidgetData(usage)
            let b = buildWidgetData(usage)
            check(shouldPushWidget(now: now, current: b, lastPushed: a, lastPushedAt: now.addingTimeInterval(-30), heartbeatInterval: 15),
                  "custom short heartbeat triggers earlier")
            check(!shouldPushWidget(now: now, current: b, lastPushed: a, lastPushedAt: now.addingTimeInterval(-5), heartbeatInterval: 15),
                  "custom short heartbeat still skips when fresh")
        }
    }

    suite("buildWidgetData session ordering") {
        test("sessions deterministically sorted by project") {
            // Synthesize two TrackedSessions whose project names parse to "alpha" and "bravo"
            let home = NSHomeDirectory()
            let encodedHome = home.replacingOccurrences(of: "/", with: "-")
            let bravoLine = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """.utf8)
            let alphaLine = Data("""
            {"type":"assistant","message":{"usage":{"input_tokens":80,"output_tokens":40,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """.utf8)
            var s1 = TrackedSession(path: "\(home)/.claude/projects/\(encodedHome)-Projects-bravo/s1.jsonl")
            _ = s1.processNewData(bravoLine)
            s1.lastFileModification = Date()
            var s2 = TrackedSession(path: "\(home)/.claude/projects/\(encodedHome)-Projects-alpha/s2.jsonl")
            _ = s2.processNewData(alphaLine)
            s2.lastFileModification = Date()

            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 5, remaining: nil, resetsAt: nil)
            )
            let widgetA = buildWidgetData(usage, activeSessions: [s1, s2])
            let widgetB = buildWidgetData(usage, activeSessions: [s2, s1])
            assertEqual(widgetA.sessions?.first?.project, "alpha", "first entry is alpha (sorted)")
            assertEqual(widgetB.sessions?.first?.project, "alpha", "order stable across input order")
            check(widgetA.hasSameValues(as: widgetB),
                  "hasSameValues must be stable across input session order")
        }
    }
}

// MARK: - Test Runner

func runAllTests() {
    runParseTokenTests()
    runParseRefreshTokenTests()
    runParseExpiresAtTests()
    runParseOAuthAccountEmailTests()
    runMissingCredentialsDetailsTests()
    runParseKeychainAccountTests()
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
    runWindowResetNotificationTests()
    runDepletionEstimateTests()
    runDailyBreakdownTests()
    runPeakHoursTests()
    runHourlyHeatmapTests()
    runHourlyHeatmapLabelTests()
    runParseWindowTests()
    runModelBreakdownParseTests()
    runAgentTrackingTests()
    runSessionTokenTests()
    runDailyUsageTrackingTests()
    runWeeklyChartTests()
    runAlignedWeeklyColumnsTests()
    runMergeDailyEntriesTests()
    runParseBashUsesTests()
    runParseContextWindowTests()
    runModelMaxContextTokensTests()
    runTrackedSessionTests()
    runAdaptiveStatusLineTests()
    runSHA256Tests()
    runBuildWidgetDataTests()
    runCompactResetTimeTests()
    runCompactFiveHourTests()
    runForecastLineTests()
    runCodexTests()
    runFormatUnifiedSessionsTests()
    runExtendedWidgetDataTests()
    runCodesignParsingTests()
    runWidgetHeartbeatTests()

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
