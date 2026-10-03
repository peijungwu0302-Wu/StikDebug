import Foundation
import Testing

@testable import RouteLocation

struct ReviewSafetyRegressionTests {
    @Test func shortcutURLPreservesReservedCharactersAndUnicode() throws {
        let name = "開啟 & 關閉=測試+100% #?"
        let tx = "tx&other=value+空 白%"
        let url = try #require(ShortcutBootstrapService.shortcutURL(name: name, txId: tx))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "shortcuts")
        #expect(components.host == "run-shortcut")
        #expect(components.fragment == nil)
        #expect(components.queryItems == [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: tx)
        ])
        // Literal plus must not be interpreted as a space by a form-style decoder.
        #expect(components.percentEncodedQuery?.contains("+") == false)
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
    }

    @Test func shortcutURLKeepsExistingPlainTextInputContract() throws {
        let url = try #require(ShortcutBootstrapService.shortcutURL(name: "RouteLocationDataOff", txId: "tx-123"))
        #expect(url.absoluteString == "shortcuts://run-shortcut?name=RouteLocationDataOff&input=text&text=tx-123")
    }

    @Test func trimmingLogsCountsOnlyEvictedErrors() {
        let date = Date(timeIntervalSince1970: 0)
        var logs = [
            LogManager.LogEntry(timestamp: date, type: .error, message: "old error"),
            LogManager.LogEntry(timestamp: date, type: .info, message: "old info"),
            LogManager.LogEntry(timestamp: date, type: .error, message: "retained error")
        ]
        var errorCount = 2
        LogManager.removeOldestLogs(2, from: &logs, errorCount: &errorCount)
        #expect(errorCount == 1)
        #expect(logs.map(\.message) == ["retained error"])
        LogManager.removeOldestLogs(0, from: &logs, errorCount: &errorCount)
        #expect(errorCount == 1)
        #expect(logs.count == 1)
    }

    @Test func mountingProgressRejectsUnknownTotalAndStaysFinite() {
        #expect(MountingProgress.percentage(progress: 0, total: 0) == nil)
        #expect(MountingProgress.percentage(progress: 1, total: 0) == nil)
        #expect(MountingProgress.percentage(progress: 1, total: 4) == 25)
        #expect(MountingProgress.percentage(progress: 5, total: 4) == 100)
    }

    @Test func diagnosticRetentionProtectsActiveRunAndEnforcesAgeAndCapacity() {
        let now = Date(timeIntervalSince1970: 1_000)
        let runs = [run("new", updatedAt: 995), run("next", updatedAt: 990),
                    run("expired", updatedAt: 800), run("active", updatedAt: 700)]
        let retained = DeveloperDiagnosticsStore.retainedRuns(
            from: runs, activeRunID: "active", now: now, maxAge: 100, maxCount: 2
        )
        #expect(retained.map(\.id) == ["new", "active"])
        #expect(retained.last?.eventCount == 4)
    }

    @Test func diagnosticRetentionWithoutActiveRunKeepsNewestEligibleEntries() {
        let retained = DeveloperDiagnosticsStore.retainedRuns(
            from: [run("first", updatedAt: 995), run("expired", updatedAt: 800), run("second", updatedAt: 990)],
            activeRunID: nil, now: Date(timeIntervalSince1970: 1_000), maxAge: 100, maxCount: 2
        )
        #expect(retained.map(\.id) == ["first", "second"])
    }

    private func run(_ id: String, updatedAt: TimeInterval) -> DiagnosticTestRun {
        DiagnosticTestRun(
            id: id, name: id, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updatedAt), appVersion: "test",
            buildNumber: "0", osVersion: "test", eventCount: 4
        )
    }
}
