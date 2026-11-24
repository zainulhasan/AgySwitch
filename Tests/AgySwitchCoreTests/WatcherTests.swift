import Foundation
import XCTest
@testable import AgySwitchCore

final class WatcherTests: XCTestCase {
    private final class Clock {
        var now = 1_735_680_000.0
        var uptime = 0.0

        func advance(_ seconds: Double) {
            now += seconds
            uptime += seconds
        }
    }

    func testQuotaSignalSpellingsAndExpectedNonErrors() {
        let quota: [(String, ExhaustionReason)] = [
            ("STOP_REASON_QUOTA_EXHAUSTED", .stopReason),
            ("ERROR_CODE_RESOURCE_EXHAUSTED", .errorCode),
            ("ResourceExhausted", .resource),
            ("RESOURCE_EXHAUSTED", .resource),
            ("out of quota", .quota),
            ("quota exceeded", .quota),
            ("HTTP/2 429", .http429),
            ("status_code=429", .http429),
            ("Too Many Requests", .http429)
        ]
        for (body, reason) in quota {
            let line = "E1120 19:00:00.123456 429 client.go:25] error: \(body)"
            XCTAssertEqual(QuotaParser.event(in: [line], now: 0, owner: "one@example.com")?.reason, reason)
        }
        let normal = [
            "I1120 19:00:00.123456 429 client.go:25] request completed",
            "W1120 19:00:00.123456 429 client.go:25] selected MODEL_PLACEHOLDER_M429",
            "I1120 19:00:00.123456 429 client.go:25] retry_model_capacity_exhausted: true",
            "I1120 19:00:00.123456 429 client.go:25] loaded config: HTTP 429",
            "I1120 19:00:00.123456 429 client.go:25] initialized RESOURCE_EXHAUSTED mapping",
            "user prompt: sample HTTP 429",
            "E1120 19:00:00.123456 429 client.go:25] response text: HTTP 429"
        ]
        for line in normal {
            XCTAssertNil(QuotaParser.event(in: [line], now: 0, owner: "one@example.com"), line)
        }
    }

    func testResetTimeAcceptsOffsetsFractionsAndRelativeFallback() {
        let text = #"resetTime: "2025-01-01T08:00:00.125+0800", retry after 1h30m"#
        XCTAssertEqual(QuotaParser.resetAt(in: text, now: 1_735_689_601), 1_735_695_001)
        XCTAssertEqual(QuotaParser.resetAt(in: text, now: 1_735_689_500), 1_735_689_600.125)
        let utc = #"{"resetTime":"2025-01-01T00:00:00.125Z"}"#
        XCTAssertEqual(QuotaParser.resetAt(in: utc, now: 1_735_689_600), 1_735_689_600.125)
        XCTAssertEqual(QuotaParser.resetAt(in: "resetTime=2021-09-09T03:00:00Z; retry_after=1h 30m 5s",
                                          now: 1_735_680_000), 1_735_685_405)
        XCTAssertNil(QuotaParser.resetAt(in: "retry after 250ms", now: 0))
        XCTAssertNil(QuotaParser.resetAt(in: "resetTime=2025-02-31T02:00:00Z", now: 0))
    }

    func testNewLogsUseSplitResetContextAndRetireAllOldSessionsAfterSwitch() throws {
        try scenario { logs, clock, keychain, pool, entries in
            let oldLog = logs.appendingPathComponent("cli-old.log")
            try put("ERROR_CODE_RESOURCE_EXHAUSTED retry after 5h\n", at: oldLog)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            let newLog = logs.appendingPathComponent("cli-new.log")
            try put("E1120 19:00:00.123456 429 client.go:25] failed HTTP 429 arbitrary-content\n", at: newLog)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            clock.advance(1)
            try put("  retry after 1h30m\n", at: newLog, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            XCTAssertEqual(try pool.snapshot().registry.accounts[0].cooldownUntil, clock.now + 5400)
            XCTAssertEqual(try pool.snapshot().registry.accounts[0].exhaustedReason, .http429)
            let count = keychain.activeWrites

            clock.advance(31)
            try put("E1120 19:00:00.123456 429 client.go:25] request failed: HTTP 429 accountEmail=two@example.com retry after 2h\n", at: oldLog, append: true)
            try put("E1120 19:00:00.123456 429 client.go:25] request failed: HTTP 429 accountEmail=two@example.com retry after 2h\n", at: newLog, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, count)
        }
    }

    func testAcpErrorsRotateAndRetireBothLogFamilies() throws {
        for signal in ["RESOURCE_EXHAUSTED", "HTTP 429"] {
            try scenario { logs, clock, keychain, pool, accounts in
                let cli = logs.appendingPathComponent("cli-running.log")
                let acp = logs.appendingPathComponent("acp-server-20261120_185551-56432.log")
                try put("", at: cli)
                let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                    monotonic: { clock.uptime })
                try put("E1120 19:00:00.123456 429 client.go:25] request failed: \(signal) retry after 1h\n", at: acp)
                XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, accounts[1].alias)
                clock.advance(31)
                for log in [acp, cli] {
                    try put("E1120 19:00:00.123456 429 client.go:25] request failed: HTTP 429 accountEmail=two@example.com retry after 1h\n", at: log, append: true)
                }
                XCTAssertNil(try watcher.poll(cooldown: 18_000))
                XCTAssertEqual(keychain.activeWrites, 1)
            }
        }
    }

    func testPendingResetContextInALogStartedAfterSwitchStillSwitches() throws {
        try scenario { logs, clock, keychain, pool, entries in
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put("request failed: RESOURCE_EXHAUSTED retry after 1h\n", at: logs.appendingPathComponent("cli-1.log"))
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            let afterSwitch = logs.appendingPathComponent("cli-2.log")
            clock.advance(3)
            try put(signIn("two@example.com") + "E1124 06:41:00.000001 1 errorreport.go:285] request failed: RESOURCE_EXHAUSTED\n",
                    at: afterSwitch)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            clock.advance(1)
            try put("  retry after 5h\n", at: afterSwitch, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[2].alias)
            XCTAssertEqual(try pool.snapshot().registry.accounts[1].cooldownUntil, clock.now + 18_000)
            XCTAssertEqual(keychain.activeWrites, 2)
        }
    }

    func testAgyIndividualQuotaLineUsesItsOwnResetTime() {
        let now = 1_735_680_000.0
        let cases: [(String, Double)] = [("4m37s", 277), ("4h58m54s", 17_934), ("147h22m8s", 530_528), ("2d3h", 183_600)]
        for (duration, seconds) in cases {
            for line in [quotaLine(duration), quotaLine(duration).replacingOccurrences(of: "agent executor error: ", with: "")] {
                let event = QuotaParser.event(in: [line], now: now, owner: "one@example.com")
                XCTAssertEqual(event?.reason, .resource, duration)
                XCTAssertEqual(event?.resetAt, now + seconds, duration)
                XCTAssertEqual(event?.email, "one@example.com", duration)
            }
        }
        let retryInfo = #"{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "3600s"}"#
        XCTAssertEqual(QuotaParser.resetAt(in: retryInfo, now: now), now + 3600)
        XCTAssertEqual(QuotaParser.resetAt(in: "retry_delay=12.5s", now: now), now + 12.5)
        XCTAssertNil(QuotaParser.resetAt(in: "Resets in 5 days", now: now))
    }

    func testCapacityToolMcpBackgroundAndRetryLinesAreNotAccountExhaustion() {
        let ignored = [
            "E1120 19:00:00.123456 57344 errorreport.go:285] generating and executing: RESOURCE_EXHAUSTED (code 429): No capacity available for model claude-x on the server",
            "E1120 19:00:00.123456 57344 errorreport.go:285] request failed: MODEL_CAPACITY_EXHAUSTED retry after 1h",
            "E1120 19:00:00.123456 57344 mcp_manager.go:310] call failed: HTTP 429 Too Many Requests",
            "E1120 19:00:00.123456 57344 runner.go:88] tool result: request failed with status 429",
            "I1120 19:00:00.123456 57344 runner.go:88] tool output: RESOURCE_EXHAUSTED from api.example.com",
            "E1120 19:00:00.123456 57344 errorreport.go:285] Failed to poll ListExperiments: RESOURCE_EXHAUSTED (code 429)",
            "W1120 19:00:00.123456 57344 client.go:25] RESOURCE_EXHAUSTED, retrying in 2s",
            "W1120 19:00:00.123456 57344 client.go:25] attempt 1 failed: HTTP 429",
            "W1120 19:00:00.123456 57344 client.go:25] attempt 1/3 failed: RESOURCE_EXHAUSTED",
            "I1120 19:00:00.123456 57344 client.go:25] request failed: HTTP 429",
            #"{"error":{"code":429,"message":"Too Many Requests"}}"#,
            "status_code=429 from api.example.com"
        ]
        for line in ignored {
            XCTAssertNil(QuotaParser.event(in: [line], now: 0, owner: "one@example.com"), line)
        }
        let kept: [(String, ExhaustionReason)] = [
            (quotaLine("4m37s"), .resource),
            ("I1120 19:00:00.123456 57344 server.go:25] STOP_REASON_QUOTA_EXHAUSTED", .stopReason),
            ("W1120 19:00:00.123456 57344 client.go:25] request failed: HTTP 429", .http429),
            ("request failed: RESOURCE_EXHAUSTED", .resource),
            // Final failures, and agy's own tool calls, are still the account's quota.
            ("E1120 19:00:00.123456 57344 errorreport.go:285] request failed after retrying: RESOURCE_EXHAUSTED", .resource),
            ("E1120 19:00:00.123456 57344 client.go:25] attempt 3/3 failed: RESOURCE_EXHAUSTED", .resource),
            ("E1120 19:00:00.123456 57344 errorreport.go:285] agent executor error: tool call failed: RESOURCE_EXHAUSTED", .resource)
        ]
        for (line, reason) in kept {
            XCTAssertEqual(QuotaParser.event(in: [line], now: 0, owner: "one@example.com")?.reason, reason, line)
        }
        // agy logs backend errors as a tagged header plus an untagged JSON body: the header decides.
        let backgroundBody = [
            "I1121 13:21:47.000001 1 http_helpers.go:938] Failed to make code assist backend request "
                + "(https://daily-cloudcode-pa.googleapis.com/v1internal:listExperiments): {",
            "  \"error\": {",
            "    \"code\": 429,",
            "    \"status\": \"RESOURCE_EXHAUSTED\"",
            "  }",
            "}"
        ]
        XCTAssertNil(QuotaParser.event(in: backgroundBody, now: 0, owner: "one@example.com"))
        let generationBody = backgroundBody.map { $0.replacingOccurrences(of: "listExperiments", with: "streamGenerateContent") }
        XCTAssertEqual(QuotaParser.event(in: generationBody, now: 0, owner: "one@example.com")?.reason, .resource)
    }

    func testSignInLinesNameTheLogsAccount() {
        let header = "I1124 06:40:20.123456 1 "
        XCTAssertEqual(QuotaParser.signIn(in: header + "server_oauth.go:221] applyAuthResult: email=Two@Example.com, authMethod=consumer, quotaProject="),
                       .account("two@example.com"))
        XCTAssertEqual(QuotaParser.signIn(in: header + "server_oauth.go:226] OAuth: authenticated successfully as two@example.com"),
                       .account("two@example.com"))
        XCTAssertEqual(QuotaParser.signIn(in: header + "browser.go:167] consumerOAuth: authenticated successfully as three@example.com"),
                       .account("three@example.com"))
        XCTAssertEqual(QuotaParser.signIn(in: header + "server_oauth.go:221] applyAuthResult: email=, authMethod=gateway, quotaProject="),
                       .noAccount)
        XCTAssertEqual(QuotaParser.signIn(in: header + "server_oauth.go:226] OAuth: authenticated successfully as "), .noAccount)
        // Untagged output and text later in a line (e.g. echoed prompts) cannot claim an account.
        XCTAssertNil(QuotaParser.signIn(in: "applyAuthResult: email=two@example.com, authMethod=consumer"))
        XCTAssertNil(QuotaParser.signIn(in: header + "runner.go:1] user said applyAuthResult: email=two@example.com"))
        XCTAssertNil(QuotaParser.signIn(in: "E1124 06:40:20.1 1 server_oauth.go:221] applyAuthResult: email=two@example.com"))
        // An email agy redacts or reformats is unknown, not "no account": the log keeps its fallback owner.
        XCTAssertNil(QuotaParser.signIn(in: header + "server_oauth.go:221] applyAuthResult: email=<redacted>, authMethod=consumer"))
    }

    func testReLoginWithinOneChunkKeepsTheActiveAccountsExhaustion() throws {
        try scenario { logs, clock, _, pool, entries in
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put(signIn("two@example.com") + quotaLine("1h") + signIn("one@example.com") + quotaLine("2h"),
                    at: logs.appendingPathComponent("cli-relogin.log"))
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            XCTAssertEqual(try pool.snapshot().registry.accounts[0].cooldownUntil, clock.now + 7200)
        }
    }

    func testUnattributedLogRightAfterSwitchWaitsOutTheDebounce() throws {
        try scenario { logs, clock, keychain, pool, entries in
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put(signIn("one@example.com") + quotaLine("1h"), at: logs.appendingPathComponent("acp-server-1.log"))
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            // No sign-in line: the log is only guessed to be on the new account, so it can't cascade straight away.
            clock.advance(5)
            let guessed = logs.appendingPathComponent("cli-guessed.log")
            try put(quotaLine("2h"), at: guessed)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, 1)
            clock.advance(30)
            try put(quotaLine("2h"), at: guessed, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[2].alias)
        }
    }

    func testOverlongLineCannotForgeASignInDuringTheLazySearch() throws {
        try scenario { logs, clock, _, pool, entries in
            let log = logs.appendingPathComponent("cli-long.log")
            let head = signIn("one@example.com") + "I1124 06:40:21.000001 1 server.go:1] "
            // Lands exactly on a 1 MiB read boundary inside one over-long line.
            let forged = "I1124 06:40:22.000001 1 server_oauth.go:221] applyAuthResult: email=two@example.com, authMethod=consumer"
            try put(head + String(repeating: "a", count: 2 * 1_048_576 - head.utf8.count) + forged + "\n", at: log)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put(quotaLine("1h"), at: log, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
        }
    }

    func testSessionsOnAnotherAccountCannotSwitchOrCoolTheActiveAccount() throws {
        try scenario { logs, clock, keychain, pool, _ in
            // A long-running terminal agy signed in as "two" before AgySwitch started watching.
            let old = logs.appendingPathComponent("cli-20261121_083706.log")
            try put(signIn("two@example.com") + "I1121 08:37:07.000001 1 server.go:1] ready\n", at: old)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put(quotaLine("4h"), at: old, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            // A new session signed in through a gateway (no consumer account).
            let gateway = logs.appendingPathComponent("acp-server-20261124_064019-1.log")
            try put("I1124 06:40:20.123456 1 server_oauth.go:221] applyAuthResult: email=, authMethod=gateway, quotaProject=\n"
                    + quotaLine("1h"), at: gateway)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, 0)
            XCTAssertTrue(try pool.snapshot().registry.accounts.allSatisfy { $0.cooldownUntil == nil })
        }
    }

    func testSessionSignedInAsActiveAccountBeforeWatchingSwitchesWithAgysResetTime() throws {
        try scenario { logs, clock, _, pool, entries in
            let log = logs.appendingPathComponent("acp-server-20261124_064019-1.log")
            try put(signIn("one@example.com") + String(repeating: "I1124 06:40:21.000001 1 server.go:1] busy\n", count: 40_000), at: log)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put(quotaLine("4h58m54s"), at: log, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            let account = try pool.snapshot().registry.accounts[0]
            XCTAssertEqual(account.cooldownUntil, clock.now + 17_934)
            XCTAssertEqual(account.exhaustedReason, .resource)
        }
    }

    func testSecondExhaustionRightAfterSwitchIsNotDropped() throws {
        try scenario { logs, clock, keychain, pool, entries in
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            try put(signIn("one@example.com") + quotaLine("1h"), at: logs.appendingPathComponent("acp-server-1.log"))
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            // T3 Code restarts `agy acp` on the new account, which is also out of quota five seconds later.
            clock.advance(5)
            try put(signIn("two@example.com") + quotaLine("2h"), at: logs.appendingPathComponent("acp-server-2.log"))
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[2].alias)
            XCTAssertEqual(try pool.snapshot().registry.accounts[1].cooldownUntil, clock.now + 7200)
            XCTAssertEqual(keychain.activeWrites, 2)
        }
    }

    func testEventsDuringBackOffAreReplayedNotDropped() throws {
        try scenario { logs, clock, keychain, pool, entries in
            for account in entries.dropFirst() { try pool.cooldown(accountID: account.id, seconds: 60) }
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            let log = logs.appendingPathComponent("acp-server-1.log")
            try put(signIn("one@example.com") + quotaLine("3h"), at: log)
            XCTAssertThrowsError(try watcher.poll(cooldown: 18_000)) { XCTAssertEqual(AppError(redacting: $0), .allOthersCooling) }
            clock.advance(10)
            try put(quotaLine("2h59m50s"), at: log, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            // A gateway session's errors (no account) can't push the active account's error out of the queue.
            let gateway = logs.appendingPathComponent("cli-gateway.log")
            for round in 0..<20 {
                clock.advance(0.5)
                try put("I1124 06:40:20.123456 1 server_oauth.go:221] applyAuthResult: email=, authMethod=gateway, quotaProject=\n"
                        + quotaLine("1h"), at: gateway, append: round > 0)
                XCTAssertNil(try watcher.poll(cooldown: 18_000))
            }
            XCTAssertEqual(keychain.activeWrites, 0)
            clock.advance(60)
            XCTAssertEqual(try watcher.poll(cooldown: 18_000)?.target, entries[1].alias)
            XCTAssertEqual(keychain.activeWrites, 1)
        }
    }

    func testExternalLoginAndExplicitUnrelatedEmailCannotSwitchOrMarkCooldown() throws {
        try scenario { logs, clock, keychain, pool, _ in
            let log = logs.appendingPathComponent("cli-old.log")
            try put("", at: log)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            let changed = try credential("outside@example.com")
            keychain.active = changed
            try put("RESOURCE_EXHAUSTED retry after 2h\n", at: log, append: true)
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            try put("E1120 19:00:00.123456 429 client.go:25] request failed: HTTP 429 accountEmail=one@example.com retry after 2h\n", at: logs.appendingPathComponent("cli-new.log"))
            XCTAssertNil(try watcher.poll(cooldown: 18_000))
            XCTAssertEqual(keychain.activeWrites, 0)
            XCTAssertEqual(keychain.active, changed)
            XCTAssertTrue(try pool.snapshot().registry.accounts.allSatisfy { $0.cooldownUntil == nil })
        }
    }

    func testBlockedRotationKeepsCooldownAndDoesNotExposeLogCredentials() throws {
        try scenario { logs, clock, keychain, pool, entries in
            for account in entries.dropFirst() { try pool.cooldown(accountID: account.id, seconds: 900) }
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            let marker = "synthetic-secret-precise-example"
            let line = "E1120 19:00:00.1 429 client.go:25] HTTP 429 retry after 2h refresh_token=\(marker)\n"
            try put(line, at: logs.appendingPathComponent("cli-blocked.log"))
            XCTAssertThrowsError(try watcher.poll(cooldown: 1)) { error in
                let warning = AppError(redacting: error)
                XCTAssertEqual(warning, .allOthersCooling)
                XCTAssertEqual(warning.text.localized(in: .zhHans), "其余账号都在冷却，请等到期后再切换。")
                XCTAssertEqual(warning.text.localized(in: .en), "All other accounts are on cooldown. Try again when one is available.")
                for language in DisplayLanguage.allCases {
                    XCTAssertFalse(warning.text.localized(in: language).contains(marker))
                }
            }
            let snapshot = try pool.snapshot()
            XCTAssertEqual(snapshot.registry.accounts[0].cooldownUntil, clock.now + 7200)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot.registry), as: UTF8.self).contains(marker))
            XCTAssertEqual(keychain.activeWrites, 0)
        }
    }

    func testPartialLineAndMissingDirectoryAreHandledWithoutReplayingHistory() throws {
        try scenario { logs, clock, _, pool, _ in
            try FileManager.default.removeItem(at: logs)
            let watcher = try AutoSwitchWatcher(pool: pool, directory: logs, clock: { clock.now },
                                                monotonic: { clock.uptime })
            XCTAssertNil(try watcher.poll(cooldown: 3600))
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
            let log = logs.appendingPathComponent("cli-chunked.log")
            try put("request failed: RESOUR", at: log)
            XCTAssertNil(try watcher.poll(cooldown: 3600))
            try put("CE_EXHAUSTED retry after 5h\n", at: log, append: true)
            XCTAssertEqual(try watcher.poll(cooldown: 3600)?.target, "two")
        }
    }

    /// agy's sign-in lines, as logged at startup by every cli-*/acp-server-* session.
    private func signIn(_ email: String) -> String {
        "I1124 06:40:20.123456 1 server_oauth.go:221] applyAuthResult: email=\(email), authMethod=consumer, quotaProject=\n"
            + "I1124 06:40:20.123500 1 server_oauth.go:226] OAuth: authenticated successfully as \(email)\n"
    }

    /// agy's end-of-turn quota error, verbatim apart from the duration.
    private func quotaLine(_ resets: String) -> String {
        "E1124 06:41:00.000001 57344 errorreport.go:285] agent executor error: generating and executing: "
            + "RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase "
            + "your limits. Resets in \(resets).\n"
    }

    private func scenario(_ body: (URL, Clock, MemoryKeychain, AccountPool, [Account]) throws -> Void) throws {
        try withSandbox { root in
            let logs = root.appendingPathComponent("log")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
            let clock = Clock()
            let keychain = MemoryKeychain()
            let pool = AccountPool(store: RegistryStore(home: root.appendingPathComponent("pool")), keychain: keychain,
                                   clock: { clock.now })
            let entries = try ["one", "two", "three"].map { name in
                let email = name + "@example.com"
                keychain.active = try credential(email)
                return try pool.save(alias: name, expectedEmail: email).account
            }
            keychain.active = try credential("one@example.com")
            try body(logs, clock, keychain, pool, entries)
        }
    }
}
