import Foundation

public struct TorrentMetadata: Sendable, Codable, Equatable {
    public let name: String
    public let infoHashV1: String?
    public let infoHashV2: String?
    public let pieceLength: Int
    public let pieceCount: Int
    public let totalBytes: Int64
    public let creationDate: Date?
    public let creator: String?
    public let files: [TorrentFileInfo]
}

