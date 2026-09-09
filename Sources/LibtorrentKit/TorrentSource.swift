import Foundation

public enum TorrentSource: Sendable, Equatable {
    case magnet(URL)
    case torrentData(Data)

    func validated() throws -> ValidatedTorrentSource {
        switch self {
        case .magnet(let url):
            guard url.scheme?.lowercased() == "magnet",
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name.lowercased() == "xt" && !($0.value ?? "").isEmpty }) == true
            else {
                throw TorrentError(operation: .add, code: .invalidSource, description: "The magnet source is invalid.")
            }
            return .magnet(url.absoluteString)
        case .torrentData(let data):
            guard !data.isEmpty, data.count <= 64 * 1_024 * 1_024 else {
                throw TorrentError(operation: .add, code: .invalidSource, description: "The torrent data is empty or exceeds the supported size.")
            }
            return .torrentData(data)
        }
    }
}

enum ValidatedTorrentSource {
    case magnet(String)
    case torrentData(Data)
}

public enum TorrentCompletionPolicy: String, Sendable, Codable, Equatable {
    case stopWithoutDeletingFiles
    case seed
}

/// libtorrent's stable download-priority scale. `.doNotDownload` is the only
/// value that disables a file or piece; `.default` is suitable for normal work.
public enum TorrentPriority: UInt8, Sendable, Codable, Equatable, CaseIterable {
    case doNotDownload = 0
    case lowest = 1
    case low = 2
    case belowNormal = 3
    case `default` = 4
    case aboveNormal = 5
    case high = 6
    case top = 7
}

public struct TorrentRateLimits: Sendable, Codable, Equatable {
    public var downloadBytesPerSecond: Int
    public var uploadBytesPerSecond: Int

    public init(downloadBytesPerSecond: Int = 0, uploadBytesPerSecond: Int = 0) {
        self.downloadBytesPerSecond = max(0, downloadBytesPerSecond)
        self.uploadBytesPerSecond = max(0, uploadBytesPerSecond)
    }
}

public struct TorrentAddRequest: Sendable, Equatable {
    public var id: UUID
    public var source: TorrentSource
    public var resumeData: Data?
    public var downloadDirectory: URL
    public var selectedFileIndexes: Set<Int>?
    public var primaryFileIndex: Int?
    public var beginsPaused: Bool
    public var rateLimits: TorrentRateLimits
    public var completionPolicy: TorrentCompletionPolicy

    public init(
        id: UUID,
        source: TorrentSource,
        resumeData: Data? = nil,
        downloadDirectory: URL,
        selectedFileIndexes: Set<Int>? = nil,
        primaryFileIndex: Int? = nil,
        beginsPaused: Bool = true,
        rateLimits: TorrentRateLimits = .init(),
        completionPolicy: TorrentCompletionPolicy = .stopWithoutDeletingFiles
    ) {
        self.id = id
        self.source = source
        self.resumeData = resumeData
        self.downloadDirectory = downloadDirectory
        self.selectedFileIndexes = selectedFileIndexes
        self.primaryFileIndex = primaryFileIndex
        self.beginsPaused = beginsPaused
        self.rateLimits = rateLimits
        self.completionPolicy = completionPolicy
    }
}
