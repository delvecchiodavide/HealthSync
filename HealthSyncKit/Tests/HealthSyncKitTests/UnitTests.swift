import Foundation
import Testing
@testable import HealthSyncKit

@Suite struct RowMappingTests {
    @Test func quantityRowMatchesColumns() throws {
        let steps = try #require(HealthMetric.metric(id: "steps"))
        let row = RowMapper.row(for: sample("ABC"), syncedAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(row.count == steps.columns.count)
        #expect(row[0] == .string("ABC"))
        #expect(row[3] == .number(100))
        #expect(row[4] == .string("count"))
        #expect(row[8] == .string("Asia/Dubai"))
        #expect(row[steps.deletedColumnIndex] == .bool(false))
    }

    @Test func datesUseSampleTimeZoneWithOffset() {
        // 2026-09-21T14:13:20Z
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(RowMapper.isoString(date, timeZone: TimeZone(identifier: "Asia/Dubai")!) == "2026-09-21T18:13:20+04:00")
    }

    @Test func everyMetricHasUniqueIDAndDeletedLast() {
        #expect(Set(HealthMetric.all.map(\.id)).count == HealthMetric.all.count)
        for metric in HealthMetric.all {
            #expect(metric.columns.last == "deleted")
            #expect(metric.columns.first == "uuid")
        }
    }

    @Test func roundingDropsFloatNoise() {
        #expect(CellValue.rounded(72.000000001) == .number(72))
        #expect(CellValue.rounded(nil) == .empty)
        #expect(CellValue.rounded(.nan) == .empty)
    }

    @Test func dailySummaryRowMatchesColumns() {
        let row = DailySummary(day: "2026-10-03", steps: 8_123.4, workoutCount: 1).row(updatedAt: Date())
        #expect(row.count == DailySummary.columns.count)
        #expect(row[1] == .number(8_123))
        #expect(row[3] == .empty)
    }
}

@Suite struct A1Tests {
    @Test(arguments: [(0, "A"), (10, "K"), (25, "Z"), (26, "AA"), (51, "AZ"), (701, "ZZ"), (702, "AAA")])
    func columnLetters(index: Int, letters: String) {
        #expect(A1.columnLetter(index) == letters)
    }

    @Test func rowSpans() {
        #expect(A1.rowSpan(of: "Data!A2:K5") == 2...5)
        #expect(A1.rowSpan(of: "'Data'!A7") == 7...7)
        #expect(A1.rowSpan(of: "Data!A1001:K2000")?.count == 1_000)
        #expect(A1.rowSpan(of: "Data") == nil)
    }
}

@Suite struct IntervalTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func clampsToFifteenMinutes() {
        let interval = SyncInterval(value: 5, unit: .minutes)
        #expect(interval.seconds == 900)
        #expect(interval.isBelowMinimum)
        #expect(!SyncInterval(value: 15, unit: .minutes).isBelowMinimum)
    }

    @Test func dueLogic() {
        let interval = SyncInterval(value: 2, unit: .hours)
        #expect(interval.isDue(lastSuccess: nil, now: now))
        #expect(!interval.isDue(lastSuccess: now.addingTimeInterval(-3_600), now: now))
        #expect(interval.isDue(lastSuccess: now.addingTimeInterval(-7_200), now: now))
        // Within the one-minute tolerance.
        #expect(interval.isDue(lastSuccess: now.addingTimeInterval(-7_170), now: now))
    }

    @Test func nextDateNeverInThePast() {
        let interval = SyncInterval(value: 1, unit: .hours)
        #expect(interval.nextDate(after: now.addingTimeInterval(-10_000), now: now) == now)
        #expect(interval.nextDate(after: now, now: now) == now.addingTimeInterval(3_600))
    }

    @Test func backgroundFrequencyMapping() {
        #expect(SyncInterval(value: 30, unit: .minutes).backgroundFrequency == .immediate)
        #expect(SyncInterval(value: 6, unit: .hours).backgroundFrequency == .hourly)
        #expect(SyncInterval(value: 1, unit: .days).backgroundFrequency == .daily)
    }

    @Test func displayText() {
        #expect(SyncInterval(value: 1, unit: .days).displayText == "Every 1 day")
        #expect(SyncInterval(value: 30, unit: .minutes).displayText == "Every 30 minutes")
    }

    @Test func historyRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = HistoryRange.week.startDate(now: now, calendar: calendar)
        #expect(start == calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)))
        #expect(HistoryRange.all.startDate(now: now) == nil)
    }

    @Test func mergedSleepDurationCountsOverlapOnce() {
        let t = now
        let intervals = [
            DateInterval(start: t, end: t.addingTimeInterval(3_600)),
            DateInterval(start: t.addingTimeInterval(1_800), end: t.addingTimeInterval(5_400)),
            DateInterval(start: t.addingTimeInterval(7_200), end: t.addingTimeInterval(9_000)),
        ]
        #expect(IntervalMath.mergedDuration(intervals) == 5_400 + 1_800)
        #expect(IntervalMath.mergedDuration([]) == 0)
    }

    @Test func chunking() {
        #expect(Array(0..<2_500).chunked(into: 1_000).map(\.count) == [1_000, 1_000, 500])
        #expect([Int]().chunked(into: 10).isEmpty)
    }

    @Test func dayKey() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        #expect(DayKey.string(for: Date(timeIntervalSince1970: 1_790_000_000), calendar: calendar) == "2026-09-21")
    }
}

@Suite struct GoogleClientTests {
    func client(_ transport: ScriptedTransport, delays: DelayRecorder = DelayRecorder()) -> GoogleAPIClient {
        GoogleAPIClient(transport: transport, tokens: StaticToken(),
                        sleep: { await delays.record($0) }, jitter: { 1 })
    }

    @Test func backoffGrowsAndCaps() {
        let policy = RetryPolicy()
        #expect(policy.delay(forAttempt: 0, jitter: 1) == 1)
        #expect(policy.delay(forAttempt: 3, jitter: 1) == 8)
        #expect(policy.delay(forAttempt: 10, jitter: 1) == 32)
        #expect(policy.delay(forAttempt: 3, jitter: 0) == 4)
    }

    @Test func retriesOn429And5xx() async throws {
        let transport = ScriptedTransport([(429, "{}"), (503, "{}"), (200, #"{"ok":true}"#)])
        let delays = DelayRecorder()
        let data = try await client(transport, delays: delays).data("GET", URL(string: "https://example.com")!)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(transport.requests.count == 3)
        #expect(await delays.values == [1, 2])
    }

    @Test func retriesDriveRateLimit403ButNotOther403() async throws {
        let rateLimited = ScriptedTransport([(403, #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#), (200, "{}")])
        _ = try await client(rateLimited).data("GET", URL(string: "https://example.com")!)
        #expect(rateLimited.requests.count == 2)

        let forbidden = ScriptedTransport([(403, #"{"error":{"message":"Insufficient permissions"}}"#)])
        await #expect(throws: GoogleAPIError.http(status: 403, message: "Insufficient permissions")) {
            _ = try await client(forbidden).data("GET", URL(string: "https://example.com")!)
        }
    }

    @Test func gives_up_after_max_attempts() async {
        let transport = ScriptedTransport(Array(repeating: (500, "{}"), count: 5))
        await #expect(throws: GoogleAPIError.self) {
            _ = try await client(transport).data("GET", URL(string: "https://example.com")!)
        }
        #expect(transport.requests.count == 5)
    }

    @Test func refreshesTokenOnceOn401() async throws {
        let transport = ScriptedTransport([(401, "{}"), (200, "{}")])
        _ = try await client(transport).data("GET", URL(string: "https://example.com")!)
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer stale", "Bearer fresh"])

        let twice = ScriptedTransport([(401, "{}"), (401, "{}")])
        await #expect(throws: GoogleAPIError.unauthorized) {
            _ = try await client(twice).data("GET", URL(string: "https://example.com")!)
        }
    }

    @Test func appendParsesRowNumbers() async throws {
        let transport = ScriptedTransport([(200, #"{"updates":{"updatedRange":"Data!A12:K13"}}"#)])
        let rows = try await SheetsService(client: client(transport)).append(spreadsheetID: "s1", rows: [[.string("a")], [.string("b")]])
        #expect(rows == [12, 13])
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url.contains("/v4/spreadsheets/s1/values/Data!A1:append"))
        #expect(url.contains("valueInputOption=RAW"))
    }
}

actor DelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}
