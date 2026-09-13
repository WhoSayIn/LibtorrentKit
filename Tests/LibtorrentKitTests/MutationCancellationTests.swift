import Foundation
import Testing
@testable import LibtorrentKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MutationCancellationTests {
    enum Mutation: CaseIterable, Sendable {
        case add, remove, selectFiles, start, pause
        case filePriority, piecePriority, streamingWindow, clearStreamingWindow

        func perform(session: TorrentSession, id: UUID, directory: URL) async throws {
            switch self {
            case .add:
                try await session.add(request(id: id, directory: directory))
            case .remove:
                try await session.remove(id, deleteFiles: false)
            case .selectFiles:
                try await session.selectFiles(for: id, selectedFileIndexes: [1], primaryFileIndex: 1)
            case .start:
                try await session.start(id)
            case .pause:
                try await session.pause(id)
            case .filePriority:
                try await session.setFilePriority(.high, forFileAt: 0, in: id)
            case .piecePriority:
                try await session.setPiecePriority(.high, forPieceAt: 0, in: id)
            case .streamingWindow:
                let window = try await setWindow(session: session, id: id)
                #expect(window.deadlinePieceIndexes == [0])
            case .clearStreamingWindow:
                try await session.clearStreamingWindow(for: id)
            }
        }
    }

    @Test(arguments: Mutation.allCases)
    func cancellationAfterNativeReturnPreservesCommittedSuccess(_ mutation: Mutation) async throws {
        try await withSession { session, gate, directory in
            let id = UUID()
            try await prepare(mutation, session: session, id: id, directory: directory)
            try await gate.cancel(at: .afterExecution) {
                try await mutation.perform(session: session, id: id, directory: directory)
                // Caller bookkeeping after the await must still be reachable.
                #expect(Task.isCancelled)
            }

            switch mutation {
            case .add:
                #expect(try await session.metadata(for: id).files.count == 2)
                let checkpoints = await session.checkpointAll(flushDiskCache: false)
                #expect(Set(checkpoints.keys) == [id])
                let checkpoint = try #require(checkpoints[id]).get()
                #expect(!checkpoint.isEmpty)
            case .remove:
                #expect(await session.checkpointAll(flushDiskCache: false).isEmpty)
                await #expect(throws: TorrentError.self) { try await session.status(for: id) }
                // Explicit removal retains unread lifecycle events. Consume the
                // original metadata event to release this identifier's reservation.
                var iterator = session.events.makeAsyncIterator()
                #expect(await iterator.next() == .metadataReady(id: id))
                // Reusing the identifier with larger geometry detects a stale cache:
                // byte offset 8 was outside the removed torrent's first file.
                try await session.add(request(id: id, directory: directory, firstFileSize: 12))
                let window = try await setWindow(session: session, id: id, byteOffset: 8)
                #expect(window.playbackPieceIndex == 2)
            case .selectFiles:
                #expect(try await session.metadata(for: id).files.filter(\.isSelected).map(\.index) == [1])
            case .start:
                #expect(try await !session.status(for: id).isPaused)
            case .pause:
                #expect(try await session.status(for: id).isPaused)
            case .filePriority, .piecePriority:
                #expect(try await session.pieces(for: id).priorities[0] == TorrentPriority.high.rawValue)
            case .streamingWindow:
                #expect(try await session.pieces(for: id).deadlinePieceIndexes == [0])
            case .clearStreamingWindow:
                #expect(try await session.pieces(for: id).deadlinePieceIndexes.isEmpty)
            }
        }
    }

    @Test(arguments: Mutation.allCases)
    func cancellationBeforeNativeExecutionLeavesStateUnchanged(_ mutation: Mutation) async throws {
        try await withSession { session, gate, directory in
            let id = UUID()
            try await prepare(mutation, session: session, id: id, directory: directory)
            await #expect(throws: CancellationError.self) {
                try await gate.cancel(at: .beforeExecution) {
                    try await mutation.perform(session: session, id: id, directory: directory)
                }
            }

            if mutation == .add {
                #expect(await session.checkpointAll(flushDiskCache: false).isEmpty)
                await #expect(throws: TorrentError.self) { try await session.status(for: id) }
                // The cancelled add must not leave a native duplicate behind.
                try await session.add(request(id: id, directory: directory))
            } else {
                #expect(try await session.metadata(for: id).files.filter(\.isSelected).map(\.index) == [0])
                #expect(try await session.status(for: id).isPaused == (mutation != .pause))
                let pieces = try await session.pieces(for: id)
                #expect(pieces.deadlinePieceIndexes == (mutation == .clearStreamingWindow ? [0] : []))
                if mutation == .filePriority || mutation == .piecePriority {
                    #expect(pieces.priorities[0] == TorrentPriority.default.rawValue)
                }
                if mutation == .remove {
                    #expect(Set(await session.checkpointAll(flushDiskCache: false).keys) == [id])
                }
            }
        }
    }

    @Test
    func cancellationAfterReadReturnStillDiscardsTheResult() async throws {
        try await withSession { session, gate, directory in
            let id = UUID()
            try await session.add(request(id: id, directory: directory))
            await #expect(throws: CancellationError.self) {
                try await gate.cancel(at: .afterExecution) { try await session.status(for: id) }
            }
            #expect(try await session.status(for: id).isPaused)
        }
    }

    @Test
    func cancellationAfterNativeFailurePreservesTheError() async throws {
        try await withSession { session, gate, directory in
            let id = UUID()
            try await session.add(request(id: id, directory: directory))
            do {
                try await gate.cancel(at: .afterExecution) {
                    try await session.add(request(id: id, directory: directory))
                }
                Issue.record("Expected the duplicate add to fail")
            } catch let error as TorrentError {
                #expect(error.code == .duplicateIdentifier)
            }
            #expect(try await session.metadata(for: id).files.count == 2)
        }
    }
}

private func request(id: UUID, directory: URL, firstFileSize: Int = 8) -> TorrentAddRequest {
    .init(
        id: id, source: .torrentData(makeTwoFileTorrent(firstFileSize: firstFileSize)),
        downloadDirectory: directory, selectedFileIndexes: [0], primaryFileIndex: 0,
        beginsPaused: true
    )
}

private func setWindow(session: TorrentSession, id: UUID, byteOffset: Int64 = 0) async throws -> TorrentStreamingWindow {
    try await session.updateStreamingWindow(
        for: id, fileIndex: 0, byteOffset: byteOffset, criticalBufferBytes: 4,
        warmBufferBytes: 4, consumptionBytesPerSecond: 1, prioritizeFirstAndLastPieces: false
    )
}

private func prepare(
    _ mutation: MutationCancellationTests.Mutation, session: TorrentSession, id: UUID, directory: URL
) async throws {
    guard mutation != .add else { return }
    try await session.add(request(id: id, directory: directory))
    _ = try await session.metadata(for: id) // Prime geometry before remove/window mutations.
    if mutation == .pause { try await session.start(id) }
    if mutation == .clearStreamingWindow { _ = try await setWindow(session: session, id: id) }
}

private func withSession(
    _ body: (TorrentSession, NativeCancellationGate, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = NativeCancellationGate()
    let session = try TorrentSession(
        configuration: .init(
            listenPortRange: 49_957...49_957,
            enableDHT: false, enableLocalServiceDiscovery: false,
            enableUPnP: false, enableNATPMP: false,
            caBundleURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Vendor/cacert-2026-08-13.pem"),
            checkpointTimeout: .seconds(5)
        ),
        nativeOperationBoundary: { gate.pause(at: $0) }
    )
    do {
        try await body(session, gate, directory)
        await session.shutdown()
    } catch {
        await session.shutdown()
        throw error
    }
}

/// Blocks only the native dispatch lane, never a Swift cooperative executor.
/// Cancellation occurs while execution is parked at an exact boundary; elapsed
/// time is only a failure bound, never the mechanism for creating the race.
private final class NativeCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var target: NativeSessionExecutor.OperationBoundary?
    private var reached = false

    func pause(at boundary: NativeSessionExecutor.OperationBoundary) {
        let shouldPause = lock.withLock {
            guard target == boundary else { return false }
            target = nil
            reached = true
            return true
        }
        if shouldPause {
            #expect(release.wait(timeout: .now() + 10) == .success, "Native boundary was not released")
        }
    }

    func cancel<Value: Sendable>(
        at boundary: NativeSessionExecutor.OperationBoundary,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        lock.withLock { target = boundary; reached = false }
        let task = Task { try await operation() }
        var didRelease = false
        defer {
            task.cancel()
            if !didRelease { release.signal() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !lock.withLock({ reached }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(lock.withLock { reached }, "Native operation did not reach the cancellation boundary")
        task.cancel()
        release.signal()
        didRelease = true
        return try await task.value
    }
}
