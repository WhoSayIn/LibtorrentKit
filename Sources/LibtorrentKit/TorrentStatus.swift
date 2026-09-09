import Foundation

public enum TorrentState: String, Sendable, Codable, Equatable {
    case checkingFiles, downloadingMetadata, downloading, finished, seeding
    case allocating, checkingResumeData, paused, stopped, unknown
}

public struct TorrentStatus: Sendable, Codable, Equatable {
    public let state: TorrentState
    public let progress: Double
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let downloadRate: Int
    public let uploadRate: Int
    public let connectedPeers: Int
    public let isPaused: Bool
    public let hasMetadata: Bool
    public let isParticipatingInSwarm: Bool
}

public struct TorrentPieceSnapshot: Sendable, Codable, Equatable {
    public let completed: [Bool]
    public let availability: [Int]
    public let priorities: [Int]
    public let deadlinePieceIndexes: [Int]
}

