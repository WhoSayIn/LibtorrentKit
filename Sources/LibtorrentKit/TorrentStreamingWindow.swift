import Foundation

public struct TorrentStreamingWindow: Sendable, Codable, Equatable {
    public let fileIndex: Int
    public let requestedByteOffset: Int64
    public let firstPieceIndex: Int
    public let lastPieceIndex: Int
    public let playbackPieceIndex: Int
    public let prioritizedPieceIndexes: [Int]
    public let deadlinePieceIndexes: [Int]
}

struct PieceWindowPlan: Sendable, Equatable {
    let firstPiece: Int
    let criticalLastPiece: Int
    let warmLastPiece: Int
    let playbackPiece: Int

    static func make(
        fileOffset: Int64,
        fileSize: Int64,
        pieceLength: Int,
        byteOffset: Int64,
        criticalBufferBytes: Int64,
        warmBufferBytes: Int64,
        consumptionBytesPerSecond: Int64
    ) throws -> Self {
        guard fileSize > 0 else {
            throw TorrentError(operation: .streamingWindow, code: .invalidOffset, description: "A streaming window cannot target an empty file.")
        }
        guard pieceLength > 0, fileOffset >= 0, byteOffset >= 0, byteOffset < fileSize,
              criticalBufferBytes > 0, warmBufferBytes >= criticalBufferBytes,
              consumptionBytesPerSecond > 0 else {
            throw TorrentError(operation: .streamingWindow, code: .invalidOffset, description: "The streaming byte range is invalid.")
        }
        let fileFirst = Int(fileOffset / Int64(pieceLength))
        let fileLast = Int((fileOffset + fileSize - 1) / Int64(pieceLength))
        let playback = min(fileLast, max(fileFirst, Int((fileOffset + byteOffset) / Int64(pieceLength))))
        func lastPiece(for byteCount: Int64) -> Int {
            let inclusiveEnd = byteOffset + min(fileSize - 1 - byteOffset, byteCount - 1)
            return min(fileLast, max(playback, Int((fileOffset + inclusiveEnd) / Int64(pieceLength))))
        }
        return .init(
            firstPiece: fileFirst,
            criticalLastPiece: lastPiece(for: criticalBufferBytes),
            warmLastPiece: lastPiece(for: warmBufferBytes),
            playbackPiece: playback
        )
    }
}
