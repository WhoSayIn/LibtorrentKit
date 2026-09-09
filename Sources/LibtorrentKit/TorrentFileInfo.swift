import Foundation

public struct TorrentFileInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let path: String
    public let size: Int64
    public let torrentOffset: Int64
    public let firstPieceIndex: Int?
    public let lastPieceIndex: Int?
    public let isSelected: Bool
    public let completedBytes: Int64
}

