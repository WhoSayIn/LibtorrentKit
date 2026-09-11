import Foundation
import Testing
@testable import LibtorrentKit

@Test func mapsFileRelativeOffsetsToTorrentPieces() throws {
    let plan = try PieceWindowPlan.make(
        fileOffset: 1_000, fileSize: 2_000, pieceLength: 512,
        byteOffset: 100, criticalBufferBytes: 400, warmBufferBytes: 800,
        consumptionBytesPerSecond: 100
    )
    #expect(plan.firstPiece == 1)
    #expect(plan.playbackPiece == 2)
    #expect(plan.criticalLastPiece == 2)
    #expect(plan.warmLastPiece == 3)
}

@Test func clampsForwardWindowAtEOFAndHandlesPartialEdges() throws {
    let plan = try PieceWindowPlan.make(
        fileOffset: 100, fileSize: 1_000, pieceLength: 256,
        byteOffset: 999, criticalBufferBytes: 1_024, warmBufferBytes: 4_096,
        consumptionBytesPerSecond: 100
    )
    #expect(plan.firstPiece == 0)
    #expect(plan.playbackPiece == 4)
    #expect(plan.criticalLastPiece == 4)
    #expect(plan.warmLastPiece == 4)
}

@Test func rejectsEmptyFilesAndInvalidOffsets() {
    #expect(throws: TorrentError.self) {
        try PieceWindowPlan.make(
            fileOffset: 0, fileSize: 0, pieceLength: 16, byteOffset: 0,
            criticalBufferBytes: 1, warmBufferBytes: 1, consumptionBytesPerSecond: 1
        )
    }
    #expect(throws: TorrentError.self) {
        try PieceWindowPlan.make(
            fileOffset: 0, fileSize: 16, pieceLength: 16, byteOffset: 16,
            criticalBufferBytes: 1, warmBufferBytes: 1, consumptionBytesPerSecond: 1
        )
    }
}

@Test func validatesSourcesWithoutLeakingThem() throws {
    let valid = URL(string: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")!
    _ = try TorrentSource.magnet(valid).validated()
    #expect(throws: TorrentError.self) { try TorrentSource.magnet(URL(string: "https://example.invalid")!).validated() }
    #expect(throws: TorrentError.self) { try TorrentSource.torrentData(Data()).validated() }
}

@Test func sanitizesSensitiveDiagnostics() {
    let error = TorrentError(
        operation: .event, code: .nativeFailure,
        description: "tracker failed: https://tracker.invalid/a?passkey=secret"
    )
    #expect(error.description == "Sensitive diagnostic details were removed.")
}

@Test func completionDefaultsToNoSeeding() {
    let request = TorrentAddRequest(
        id: UUID(), source: .torrentData(Data([0x64, 0x65])),
        downloadDirectory: URL(fileURLWithPath: "/tmp")
    )
    #expect(request.completionPolicy == .stopWithoutDeletingFiles)
}

@Test func handlesVeryLargeWarmBufferWithoutOverflow() throws {
    let plan = try PieceWindowPlan.make(
        fileOffset: 0, fileSize: 32, pieceLength: 4,
        byteOffset: 8, criticalBufferBytes: 4, warmBufferBytes: .max,
        consumptionBytesPerSecond: 1
    )
    #expect(plan.playbackPiece == 2)
    #expect(plan.criticalLastPiece == 2)
    #expect(plan.warmLastPiece == 7)
}

@Test func convertsNativeErrorEvents() throws {
    let json = Data(#"{"kind":"error","code":7,"description":"A requested file index is invalid."}"#.utf8)
    let envelope = try JSONDecoder().decode(NativeEventEnvelope.self, from: json)
    guard case .error(let id, let error) = envelope.event() else {
        Issue.record("Expected a native error event")
        return
    }
    #expect(id == nil)
    #expect(error.code == .invalidFileIndex)
    #expect(error.operation == .event)
}

@Test(.timeLimit(.minutes(1)))
func nativeSelectionSeekCheckpointAndCorruptResume() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let ca = root.appending(path: "Vendor/cacert-2026-08-13.pem")
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configuration = TorrentSessionConfiguration(
        listenPortRange: 49_951...49_951,
        enableDHT: false, enableLocalServiceDiscovery: false,
        enableUPnP: false, enableNATPMP: false,
        caBundleURL: ca, checkpointTimeout: .seconds(10)
    )
    let id = UUID()
    let source = makeTwoFileTorrent()
    let session = try TorrentSession(configuration: configuration)
    let metadataOnlyID = UUID()
    try await session.add(.init(
        id: metadataOnlyID, source: .torrentData(source), downloadDirectory: directory,
        beginsPaused: true
    ))
    #expect(try await session.metadata(for: metadataOnlyID).files.allSatisfy { !$0.isSelected })
    try await session.remove(metadataOnlyID, deleteFiles: false)
    try await session.add(.init(
        id: id, source: .torrentData(source), downloadDirectory: directory,
        selectedFileIndexes: [0], primaryFileIndex: 0, beginsPaused: true
    ))
    let metadata = try await session.metadata(for: id)
    #expect(metadata.files.count == 2)
    #expect(metadata.files[0].isSelected)
    #expect(!metadata.files[1].isSelected)

    try await session.setFilePriority(.high, forFileAt: 0, in: id)
    try await session.setPiecePriority(.high, forPieceAt: 0, in: id)
    let first = try await session.updateStreamingWindow(
        for: id, fileIndex: 0, byteOffset: 0,
        criticalBufferBytes: 4, warmBufferBytes: 4,
        consumptionBytesPerSecond: 1, prioritizeFirstAndLastPieces: true
    )
    #expect(first.deadlinePieceIndexes == [0])

    try await session.selectFiles(for: id, selectedFileIndexes: [1], primaryFileIndex: 1)
    let second = try await session.updateStreamingWindow(
        for: id, fileIndex: 1, byteOffset: 4,
        criticalBufferBytes: 4, warmBufferBytes: 4,
        consumptionBytesPerSecond: 1, prioritizeFirstAndLastPieces: false
    )
    let pieces = try await session.pieces(for: id)
    let completion = try await session.pieceCompletion(for: id)
    #expect(second.deadlinePieceIndexes == [3])
    #expect(pieces.deadlinePieceIndexes == [3])
    #expect(pieces.priorities[0] == 0)
    #expect(completion.pieceCount == metadata.pieceCount)
    #expect(completion.completionBitset.count == (metadata.pieceCount + 7) / 8)
    #expect(!completion.isComplete(pieceAt: -1))
    #expect(!completion.isComplete(pieceAt: metadata.pieceCount))

    let checkpoint = try await session.checkpoint(id, flushDiskCache: true)
    #expect(!checkpoint.isEmpty)
    await session.shutdown()

    let corruptSession = try TorrentSession(configuration: configuration)
    do {
        try await corruptSession.add(.init(
            id: UUID(), source: .torrentData(source), resumeData: Data("not-resume-data".utf8),
            downloadDirectory: directory
        ))
        Issue.record("Expected corrupt resume data to fail")
    } catch let error as TorrentError {
        #expect(error.code == .corruptResumeData)
    }
    await corruptSession.shutdown()
    #expect(FileManager.default.fileExists(atPath: directory.path))
}

private enum BValue {
    case integer(Int)
    case bytes(Data)
    case list([BValue])
    case dictionary([String: BValue])
}

private func makeTwoFileTorrent() -> Data {
    encode(.dictionary([
        "info": .dictionary([
            "files": .list([
                .dictionary(["length": .integer(8), "path": .list([.bytes(Data("a.bin".utf8))])]),
                .dictionary(["length": .integer(8), "path": .list([.bytes(Data("b.bin".utf8))])]),
            ]),
            "name": .bytes(Data("fixture".utf8)),
            "piece length": .integer(4),
            "pieces": .bytes(Data(repeating: 0, count: 80)),
        ]),
    ]))
}

private func encode(_ value: BValue) -> Data {
    switch value {
    case .integer(let number): return Data("i\(number)e".utf8)
    case .bytes(let bytes):
        var output = Data("\(bytes.count):".utf8)
        output.append(bytes)
        return output
    case .list(let values):
        var output = Data("l".utf8)
        values.forEach { output.append(encode($0)) }
        output.append(Data("e".utf8))
        return output
    case .dictionary(let values):
        var output = Data("d".utf8)
        for key in values.keys.sorted() {
            output.append(encode(.bytes(Data(key.utf8))))
            output.append(encode(values[key]!))
        }
        output.append(Data("e".utf8))
        return output
    }
}
