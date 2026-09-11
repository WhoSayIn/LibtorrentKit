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

/// Compact completion-only state. Piece `n` is stored in bit `n % 8` of byte `n / 8`.
public struct TorrentPieceCompletion: Sendable, Equatable {
    public let pieceCount: Int
    public let completionBitset: Data

    init(pieceCount: Int, completionBitset: Data) {
        self.pieceCount = pieceCount
        self.completionBitset = completionBitset
    }

    public func isComplete(pieceAt index: Int) -> Bool {
        guard index >= 0, index < pieceCount else { return false }
        return completionBitset[index / 8] & (UInt8(1) << UInt8(index % 8)) != 0
    }

    public func areComplete(in range: ClosedRange<Int>) -> Bool {
        guard range.lowerBound >= 0, range.upperBound < pieceCount else { return false }
        return range.allSatisfy { isComplete(pieceAt: $0) }
    }
}
