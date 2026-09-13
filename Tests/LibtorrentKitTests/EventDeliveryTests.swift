import CryptoKit
import Foundation
import Testing
@testable import LibtorrentKit

@Test(.timeLimit(.minutes(1)))
func slowConsumerRetainsMoreThan256NativeLifecycleEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try eventTestSession(port: 49_953)
    do {
        let payload = Data(repeating: 42, count: 16_384)
        var identifiers = Set<UUID>()
        for index in 0..<128 {
            let id = UUID()
            identifiers.insert(id)
            let name = "fixture-\(index).bin"
            try payload.write(to: directory.appending(path: name))
            try await session.add(.init(
                id: id, source: .torrentData(completedFixture(name: name, payload: payload)),
                downloadDirectory: directory, selectedFileIndexes: [0], primaryFileIndex: 0,
                beginsPaused: true
            ))
            try await session.start(id)
        }
        // Deliberately never create an iterator until all 384 critical events
        // have been produced. Polling uses the independent native operation lane.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var pending = identifiers
        while !pending.isEmpty && ContinuousClock.now < deadline {
            for id in pending where try await session.status(for: id).state == .stopped {
                pending.remove(id)
            }
            if !pending.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        try #require(pending.isEmpty, "Fixture torrents did not finish before the deadline")
        var phases = [UUID: Int]()
        var iterator = session.events.makeAsyncIterator()
        for _ in 0..<(identifiers.count * 3) {
            let event = try #require(await iterator.next())
            switch event {
            case .metadataReady(let id):
                #expect(phases[id] == nil)
                let metadata = try await session.metadata(for: id)
                #expect(metadata.files.filter(\.isSelected).map(\.index) == [0])
                phases[id] = 1
            case .completed(let id, let status):
                #expect(phases[id] == 1)
                #expect(status.progress == 1)
                phases[id] = 2
            case .stoppedAfterCompletion(let id):
                #expect(phases[id] == 2)
                phases[id] = 3
                try await session.remove(id, deleteFiles: false)
            default:
                Issue.record("Expected a critical lifecycle event, received \(event)")
            }
        }
        #expect(Set(phases.keys) == identifiers)
        #expect(phases.values.allSatisfy { $0 == 3 })
        await session.shutdown()
        #expect(await iterator.next() == nil)
    } catch {
        await session.shutdown()
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func fullMailboxRejectsAdmissionUntilRemovedJobsEventsAreRead() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try eventTestSession(port: 49_956)
    do {
        let payload = Data(repeating: 0, count: 16_384)
        var expected = Set<UUID>()
        for index in 0..<256 {
            let id = UUID()
            expected.insert(id)
            try await session.add(.init(
                id: id, source: .torrentData(completedFixture(name: "pending-\(index)", payload: payload)),
                downloadDirectory: directory, beginsPaused: true
            ))
            // Remove must retain the metadata event, and its reservation,
            // without requiring an event consumer to make remove progress.
            try await session.remove(id, deleteFiles: false)
        }
        let request = TorrentAddRequest(
            id: UUID(), source: .torrentData(completedFixture(name: "overflow", payload: payload)),
            downloadDirectory: directory, beginsPaused: true
        )
        do {
            try await session.add(request)
            Issue.record("Expected bounded admission to reject the next torrent")
        } catch let error as TorrentError {
            #expect(error.code == .allocationLimit)
        }
        var iterator = session.events.makeAsyncIterator()
        for _ in 0..<256 {
            guard case .metadataReady(let id) = await iterator.next() else {
                Issue.record("Expected retained metadata")
                continue
            }
            #expect(expected.remove(id) != nil)
        }
        #expect(expected.isEmpty)
        try await session.add(request)
        #expect(await iterator.next() == .metadataReady(id: request.id))
        try await session.remove(request.id, deleteFiles: false)
        await session.shutdown()
    } catch {
        await session.shutdown()
        throw error
    }
}

@Test(.timeLimit(.minutes(1)))
func shutdownAndCancellationReleaseAnIdleEventRead() async throws {
    let session = try eventTestSession(port: 49_954)
    let waiting = Task {
        var iterator = session.events.makeAsyncIterator()
        return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(50))
    await session.shutdown()
    #expect(await waiting.value == nil)

    let cancelledSession = try eventTestSession(port: 49_955)
    let cancelled = Task {
        var iterator = cancelledSession.events.makeAsyncIterator()
        return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(50))
    cancelled.cancel()
    #expect(await cancelled.value == nil)
    await cancelledSession.shutdown()
}

private func eventTestSession(port: UInt16) throws -> TorrentSession {
    try TorrentSession(configuration: .init(
        listenPortRange: port...port,
        enableDHT: false, enableLocalServiceDiscovery: false,
        enableUPnP: false, enableNATPMP: false,
        caBundleURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Vendor/cacert-2026-08-13.pem")
    ))
}

private func completedFixture(name: String, payload: Data) -> Data {
    var data = Data("d4:infod6:lengthi\(payload.count)e4:name\(name.utf8.count):\(name)12:piece lengthi16384e6:pieces20:".utf8)
    data.append(contentsOf: Insecure.SHA1.hash(data: payload))
    data.append(Data("ee".utf8))
    return data
}
