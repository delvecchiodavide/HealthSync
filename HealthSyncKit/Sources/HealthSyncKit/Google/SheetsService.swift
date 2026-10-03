import Foundation

/// Google Sheets v4. Each app spreadsheet has a single tab named "Data".
public struct SheetsService: Sendable {
    static let base = "https://sheets.googleapis.com/v4/spreadsheets"
    public static let sheetTitle = "Data"
    /// Rows per append request.
    public static let maxRowsPerRequest = 1_000

    let client: GoogleAPIClient

    public init(client: GoogleAPIClient) {
        self.client = client
    }

    /// Renames the first tab, sizes the grid to the columns, freezes and bolds the header row.
    public func prepare(spreadsheetID: String, headers: [String]) async throws {
        struct Meta: Decodable {
            struct Sheet: Decodable { struct Props: Decodable { let sheetId: Int }; let properties: Props }
            let sheets: [Sheet]
        }
        let meta = try await client.decode(Meta.self, "GET", GoogleAPIClient.url(
            Self.base, path: "/\(spreadsheetID)", query: ["fields": "sheets.properties.sheetId"]))
        let sheetID = meta.sheets.first?.properties.sheetId ?? 0

        _ = try await client.data("POST", GoogleAPIClient.url(Self.base, path: "/\(spreadsheetID):batchUpdate"), json: [
            "requests": [
                ["updateSheetProperties": [
                    "properties": [
                        "sheetId": sheetID,
                        "title": Self.sheetTitle,
                        // Keep the grid tight: Google's cell limit counts empty grid cells too.
                        "gridProperties": ["frozenRowCount": 1, "rowCount": 2, "columnCount": headers.count],
                    ],
                    "fields": "title,gridProperties.frozenRowCount,gridProperties.rowCount,gridProperties.columnCount",
                ]],
                ["repeatCell": [
                    "range": ["sheetId": sheetID, "startRowIndex": 0, "endRowIndex": 1],
                    "cell": ["userEnteredFormat": ["textFormat": ["bold": true]]],
                    "fields": "userEnteredFormat.textFormat.bold",
                ]],
            ],
        ])

        let range = "\(Self.sheetTitle)!A1"
        _ = try await client.data("PUT", GoogleAPIClient.url(
            Self.base, path: "/\(spreadsheetID)/values/\(range)", query: ["valueInputOption": "RAW"]), json: [
            "range": range,
            "majorDimension": "ROWS",
            "values": [headers],
        ])
    }

    /// Appends rows and returns the 1-based row number each one landed on.
    public func append(spreadsheetID: String, rows: [[CellValue]]) async throws -> [Int] {
        precondition(rows.count <= Self.maxRowsPerRequest, "Batch appends before calling")
        guard !rows.isEmpty else { return [] }
        struct Response: Decodable { struct Updates: Decodable { let updatedRange: String }; let updates: Updates }

        let url = GoogleAPIClient.url(Self.base, path: "/\(spreadsheetID)/values/\(Self.sheetTitle)!A1:append", query: [
            "valueInputOption": "RAW",
            "insertDataOption": "INSERT_ROWS",
        ])
        let response = try await client.decode(Response.self, "POST", url, json: [
            "majorDimension": "ROWS",
            "values": rows.map { $0.map(\.jsonValue) },
        ])
        guard let span = A1.rowSpan(of: response.updates.updatedRange), span.count == rows.count else {
            throw GoogleAPIError.invalidResponse
        }
        return Array(span)
    }

    /// Overwrites whole rows in place, starting at column A.
    public func updateRows(spreadsheetID: String, rows: [(row: Int, values: [CellValue])]) async throws {
        try await batchUpdateValues(spreadsheetID: spreadsheetID, data: rows.map { row in
            (range: "\(Self.sheetTitle)!A\(row.row)", values: [row.values])
        })
    }

    /// Sets the `deleted` column to TRUE for the given rows.
    public func markDeleted(spreadsheetID: String, rows: [Int], deletedColumnIndex: Int) async throws {
        let column = A1.columnLetter(deletedColumnIndex)
        try await batchUpdateValues(spreadsheetID: spreadsheetID, data: rows.map { row in
            (range: "\(Self.sheetTitle)!\(column)\(row)", values: [[.bool(true)]])
        })
    }

    private func batchUpdateValues(spreadsheetID: String, data: [(range: String, values: [[CellValue]])]) async throws {
        for chunk in data.chunked(into: Self.maxRowsPerRequest) {
            _ = try await client.data("POST", GoogleAPIClient.url(Self.base, path: "/\(spreadsheetID)/values:batchUpdate"), json: [
                "valueInputOption": "RAW",
                "data": chunk.map { ["range": $0.range, "values": $0.values.map { $0.map(\.jsonValue) }] },
            ])
        }
    }
}
