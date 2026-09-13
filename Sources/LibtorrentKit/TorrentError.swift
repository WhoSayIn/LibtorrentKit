import Foundation

public struct TorrentError: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    public enum Operation: String, Sendable, Codable, Equatable {
        case initialize, add, metadata, selection, priority, start, pause, status, pieces
        case streamingWindow, checkpoint, remove, shutdown, event
    }

    public enum Code: Int32, Sendable, Codable, Equatable {
        case unknown = 1
        case invalidArgument = 2
        case invalidSource = 3
        case invalidIdentifier = 4
        case duplicateIdentifier = 5
        case metadataUnavailable = 6
        case invalidFileIndex = 7
        case invalidPieceIndex = 8
        case invalidOffset = 9
        case corruptResumeData = 10
        case timedOut = 11
        case nativeFailure = 12
        case sessionShutDown = 13
        case allocationLimit = 14
        case pathViolation = 15
        case completionFailed = 16

        init(native: Int32) { self = Self(rawValue: native) ?? .unknown }
    }

    public let operation: Operation
    public let code: Code
    public let category: String
    public let description: String

    public init(operation: Operation, code: Code, category: String = "LibtorrentKit", description: String) {
        self.operation = operation
        self.code = code
        self.category = Self.sanitize(category)
        self.description = Self.sanitize(description)
    }

    static func native(operation: Operation, code: Int32, description: String?) -> Self {
        .init(
            operation: operation,
            code: .init(native: code),
            category: "LibtorrentNative",
            description: description ?? "The native operation failed."
        )
    }

    static func sanitize(_ input: String) -> String {
        let limited = String(input.prefix(512))
        let patterns = ["magnet:?", "http://", "https://", "udp://", "peer=", "passkey="]
        guard !patterns.contains(where: { limited.localizedCaseInsensitiveContains($0) }) else {
            return "Sensitive diagnostic details were removed."
        }
        return limited.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
            .map(String.init)
            .joined()
    }
}
