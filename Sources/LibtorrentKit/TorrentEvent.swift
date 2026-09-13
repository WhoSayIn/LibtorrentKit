import Foundation

public enum TorrentEvent: Sendable, Equatable {
    case metadataReady(id: UUID)
    case statusChanged(id: UUID, status: TorrentStatus)
    /// Retained for source compatibility. Sessions no longer emit per-piece
    /// notifications; query `pieceCompletion(for:)` or `pieces(for:)` instead.
    case pieceCompleted(id: UUID, pieceIndex: Int)
    case completed(id: UUID, finalStatus: TorrentStatus)
    case stoppedAfterCompletion(id: UUID)
    case error(id: UUID?, error: TorrentError)
}

struct NativeEventEnvelope: Decodable {
    let kind: String
    let id: UUID?
    let pieceIndex: Int?
    let status: TorrentStatus?
    let errorCode: Int32?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case kind, id, pieceIndex, status
        case errorCode = "code"
        case errorDescription = "description"
    }

    func event() -> TorrentEvent? {
        switch kind {
        case "metadataReady": return id.map(TorrentEvent.metadataReady)
        case "statusChanged": return id.flatMap { id in status.map { .statusChanged(id: id, status: $0) } }
        case "pieceCompleted": return id.flatMap { id in pieceIndex.map { .pieceCompleted(id: id, pieceIndex: $0) } }
        case "completed": return id.flatMap { id in status.map { .completed(id: id, finalStatus: $0) } }
        case "stoppedAfterCompletion": return id.map(TorrentEvent.stoppedAfterCompletion)
        case "error":
            return .error(id: id, error: .native(operation: .event, code: errorCode ?? 1, description: errorDescription))
        default: return nil
        }
    }
}
