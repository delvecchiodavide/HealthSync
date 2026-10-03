import Foundation

public struct DriveFile: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let webViewLink: String?
    public let trashed: Bool?
}

/// Google Drive v3. With the `drive.file` scope only files this app created are visible.
public struct DriveService: Sendable {
    static let filesBase = "https://www.googleapis.com/drive/v3/files"
    public static let folderMimeType = "application/vnd.google-apps.folder"
    public static let spreadsheetMimeType = "application/vnd.google-apps.spreadsheet"
    static let fileFields = "id,name,webViewLink,trashed"

    let client: GoogleAPIClient

    public init(client: GoogleAPIClient) {
        self.client = client
    }

    public func createFolder(named name: String) async throws -> DriveFile {
        try await client.decode(DriveFile.self, "POST",
                                GoogleAPIClient.url(Self.filesBase, query: ["fields": Self.fileFields]),
                                json: ["name": name, "mimeType": Self.folderMimeType])
    }

    /// Folders created by this app (the only ones visible with `drive.file`).
    public func listFolders() async throws -> [DriveFile] {
        struct List: Decodable { let files: [DriveFile] }
        let url = GoogleAPIClient.url(Self.filesBase, query: [
            "q": "mimeType='\(Self.folderMimeType)' and trashed=false",
            "fields": "files(\(Self.fileFields))",
            "orderBy": "name",
            "pageSize": "100",
        ])
        return try await client.decode(List.self, "GET", url).files
    }

    public func file(id: String) async throws -> DriveFile {
        try await client.decode(DriveFile.self, "GET",
                                GoogleAPIClient.url(Self.filesBase, path: "/\(id)", query: ["fields": Self.fileFields]))
    }

    public func createSpreadsheet(named name: String, inFolder folderID: String) async throws -> DriveFile {
        try await client.decode(DriveFile.self, "POST",
                                GoogleAPIClient.url(Self.filesBase, query: ["fields": Self.fileFields]),
                                json: ["name": name, "mimeType": Self.spreadsheetMimeType, "parents": [folderID]])
    }

    public static func folderURL(id: String) -> URL {
        URL(string: "https://drive.google.com/drive/folders/\(id)")!
    }
}
