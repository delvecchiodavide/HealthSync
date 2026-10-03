import Foundation
@testable import HealthSyncKit

struct StaticToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { forceRefresh ? "fresh" : "stale" }
}

/// Scripted HTTP responses, one per request, recording what was sent.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, String)]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { respond(to: request) }
    }

    private func respond(to request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// An in-memory imitation of the Drive and Sheets endpoints the app uses.
final class FakeGoogle: HTTPTransport, @unchecked Sendable {
    struct Sheet { var name: String; var parents: [String]; var rows: [[Any]] = [] }

    private let lock = NSLock()
    private var nextID = 1
    private(set) var sheets: [String: Sheet] = [:]
    var deletedSpreadsheets: Set<String> = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { handle(request) }
    }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let path = url.path
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        func respond(_ object: Any, status: Int = 200) -> (Data, HTTPURLResponse) {
            (try! JSONSerialization.data(withJSONObject: object),
             HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        if path == "/drive/v3/files", request.httpMethod == "POST" {
            let id = "file-\(nextID)"; nextID += 1
            sheets[id] = Sheet(name: body["name"] as! String, parents: body["parents"] as? [String] ?? [])
            return respond(["id": id, "name": body["name"]!])
        }

        guard path.hasPrefix("/v4/spreadsheets/") else { return respond(["error": ["message": "unknown"]], status: 400) }
        let rest = String(path.dropFirst("/v4/spreadsheets/".count))
        let id = String(rest.prefix { $0 != "/" && $0 != ":" })
        guard sheets[id] != nil, !deletedSpreadsheets.contains(id) else {
            return respond(["error": ["message": "Requested entity was not found."]], status: 404)
        }

        if rest == id, request.httpMethod == "GET" {
            return respond(["sheets": [["properties": ["sheetId": 0]]]])
        }
        if rest.hasSuffix(":batchUpdate") && !rest.contains("values") {
            return respond([:])
        }
        if rest.hasPrefix("\(id)/values/Data!A1"), request.httpMethod == "PUT" {
            let values = body["values"] as! [[Any]]
            sheets[id]!.rows = values + sheets[id]!.rows.dropFirst(min(1, sheets[id]!.rows.count))
            return respond([:])
        }
        if rest.hasSuffix(":append") {
            let values = body["values"] as! [[Any]]
            let first = sheets[id]!.rows.count + 1
            sheets[id]!.rows += values
            let last = first + values.count - 1
            return respond(["updates": ["updatedRange": "Data!A\(first):Z\(last)"]])
        }
        if rest.hasSuffix("values:batchUpdate") {
            for item in body["data"] as! [[String: Any]] {
                let range = item["range"] as! String
                let cells = String(range.split(separator: "!").last!)
                let row = Int(cells.filter(\.isNumber))!
                let column = cells.filter(\.isLetter).unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
                let values = (item["values"] as! [[Any]])[0]
                for (offset, value) in values.enumerated() {
                    sheets[id]!.rows[row - 1][column + offset] = value
                }
            }
            return respond([:])
        }
        return respond(["error": ["message": "unhandled \(path)"]], status: 400)
    }

    func sheet(named name: String) -> Sheet? {
        lock.lock(); defer { lock.unlock() }
        return sheets.values.first { $0.name == name }
    }

    func spreadsheetID(named name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sheets.first { $0.value.name == name }?.key
    }

    func markSpreadsheetDeleted(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        deletedSpreadsheets.insert(id)
    }
}

/// A HealthKit stand-in. The anchor is the number of change events already delivered.
final class FakeHealth: HealthDataSource, @unchecked Sendable {
    enum Event { case add(SampleRecord), delete(String) }

    private let lock = NSLock()
    private var events: [String: [Event]] = [:]
    var lockedError = false
    var summaries: [DailySummary] = []

    func add(_ metricID: String, _ records: [SampleRecord]) {
        lock.lock(); defer { lock.unlock() }
        events[metricID, default: []] += records.map(Event.add)
    }

    func delete(_ metricID: String, _ uuid: String) {
        lock.lock(); defer { lock.unlock() }
        events[metricID, default: []].append(.delete(uuid))
    }

    func changes(for metric: HealthMetric, anchor: Data?, since: Date?, limit: Int) async throws -> HealthChanges {
        try lock.withLock { try page(for: metric, anchor: anchor, limit: limit) }
    }

    private func page(for metric: HealthMetric, anchor: Data?, limit: Int) throws -> HealthChanges {
        if lockedError { throw SyncError.healthDataLocked }
        let position = anchor.map { Int(String(decoding: $0, as: UTF8.self))! } ?? 0
        let all = events[metric.id] ?? []
        let page = Array(all.dropFirst(position).prefix(limit))
        var added: [SampleRecord] = []
        var deleted: [String] = []
        for event in page {
            switch event {
            case .add(let record): added.append(record)
            case .delete(let uuid): deleted.append(uuid)
            }
        }
        return HealthChanges(added: added, deletedUUIDs: deleted, newAnchor: Data(String(position + page.count).utf8),
                             hasMore: page.count >= limit)
    }

    func dailySummaries(from start: Date, to end: Date) async throws -> [DailySummary] {
        lock.withLock { summaries }
    }
}

func sample(_ uuid: String, value: Double = 100, at date: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> SampleRecord {
    SampleRecord(uuid: uuid, start: date, end: date.addingTimeInterval(60), values: [.number(value), .string("count")],
                 sourceName: "iPhone", sourceBundleID: "com.apple.health", device: "iPhone", timeZoneID: "Asia/Dubai")
}
