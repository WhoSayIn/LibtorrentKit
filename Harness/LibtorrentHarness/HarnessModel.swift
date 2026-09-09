import Foundation
import LibtorrentKit
import Observation

@MainActor
@Observable
final class HarnessModel {
    private static let fixtureURL = URL(string: "https://webtorrent.io/torrents/sintel.torrent")!
    private let id = UUID(uuidString: "45F81D6C-46E3-41A0-9DD8-2F0A35AB80A2")!
    private var sourceData: Data?
    private var session: TorrentSession?
    private var selectedFile: TorrentFileInfo?
    private var statusTask: Task<Void, Never>?
    private var byteOffset: Int64 = 0

    var state = "idle"
    var progress = 0.0
    var downloadRate = 0
    var checkpointState = "none"
    var name = ""
    var files: [TorrentFileInfo] = []
    var windowDescription = "none"
    var deadlineDescription = "none"
    var error: String?
    var selectedFileDescription: String { selectedFile?.path ?? "none" }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var resumeURL: URL { documents.appending(path: "fixture.fastresume") }

    func prepare() async {
        do { try await createSession() }
        catch { self.error = safe(error) }
    }

    func loadFixture() async {
        do {
            if session == nil { try await createSession() }
            let (data, response) = try await URLSession.shared.data(from: Self.fixtureURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HarnessError.fixtureUnavailable }
            sourceData = data
            try await session?.add(.init(
                id: id, source: .torrentData(data), downloadDirectory: documents,
                beginsPaused: true
            ))
            let metadata = try await session!.metadata(for: id)
            name = metadata.name
            files = metadata.files
            guard let primary = metadata.files.filter({ $0.size > 0 }).max(by: { $0.size < $1.size }) else {
                throw HarnessError.noPayload
            }
            selectedFile = primary
            try await session?.selectFiles(for: id, selectedFileIndexes: [primary.index], primaryFileIndex: primary.index)
            _ = try await updateWindow()
            state = "ready"
            beginStatusUpdates()
        } catch { self.error = safe(error) }
    }

    func start() async { await perform { try await self.session?.start(self.id) } }
    func pause() async { await perform { try await self.session?.pause(self.id) } }

    func checkpointForBackground() async {
        guard let session else { return }
        do {
            let data = try await session.checkpoint(id, flushDiskCache: true)
            try data.write(to: resumeURL, options: [.atomic])
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: resumeURL.path)
            checkpointState = "saved \(data.count) bytes"
        } catch { self.error = safe(error); checkpointState = "failed" }
    }

    func destroyAndRestore() async {
        guard let sourceData else { return }
        await checkpointForBackground()
        await session?.shutdown()
        session = nil
        do {
            let resume = try Data(contentsOf: resumeURL)
            try await createSession()
            try await session?.add(.init(
                id: id, source: .torrentData(sourceData), resumeData: resume,
                downloadDirectory: documents,
                selectedFileIndexes: selectedFile.map { [$0.index] },
                primaryFileIndex: selectedFile?.index,
                beginsPaused: false
            ))
            _ = try await session?.metadata(for: id)
            _ = try await updateWindow()
            state = "restored"
            beginStatusUpdates()
        } catch { self.error = safe(error) }
    }

    func moveWindow() async {
        guard let file = selectedFile else { return }
        byteOffset = min(max(0, file.size - 1), byteOffset + 1_048_576)
        do { _ = try await updateWindow() }
        catch { self.error = safe(error) }
    }

    func remove() async {
        await perform { try await self.session?.remove(self.id, deleteFiles: false) }
        state = "removed"
    }

    func runAcceptanceIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--ltkit-acceptance") else { return }
        let reportURL = documents.appending(path: "acceptance.json")
        try? FileManager.default.removeItem(at: reportURL)
        await loadFixture()
        guard error == nil, let session, let selectedFile else {
            writeAcceptance(["metadata": false, "error": error ?? "fixture setup failed"], to: reportURL)
            return
        }
        do {
            let initialDeadlines = try await session.pieces(for: id).deadlinePieceIndexes
            await moveWindow()
            let movedDeadlines = try await session.pieces(for: id).deadlinePieceIndexes
            let initial = try await session.status(for: id)
            try await session.start(id)
            var advanced = initial.completedBytes
            for _ in 0..<30 where advanced <= initial.completedBytes {
                try await Task.sleep(for: .seconds(1))
                advanced = try await session.status(for: id).completedBytes
            }
            try await session.pause(id)
            let paused = try await session.status(for: id).completedBytes
            try await Task.sleep(for: .seconds(3))
            let pausedLater = try await session.status(for: id).completedBytes
            let checkpoint = try await session.checkpoint(id, flushDiskCache: true)
            await destroyAndRestore()
            guard let restoredSession = self.session else { throw HarnessError.noPayload }
            let restored = try await restoredSession.status(for: id)
            var report: [String: Any] = [
                "metadata": true,
                "fileCount": files.count,
                "selectedFile": selectedFile.path,
                "initialDeadlines": initialDeadlines,
                "movedDeadlines": movedDeadlines,
                "seekReplacedWindow": initialDeadlines != movedDeadlines
                    && Set(initialDeadlines).subtracting(movedDeadlines).isEmpty == false,
                "progressAdvanced": advanced > initial.completedBytes,
                "pausedStable": pausedLater == paused,
                "checkpointBytes": checkpoint.count,
                "restoredBytes": restored.completedBytes,
                "window": windowDescription,
                "deadlines": deadlineDescription,
                "completion": "pending",
            ]
            writeAcceptance(report, to: reportURL)
            var completionStatus = restored
            for _ in 0..<180 where completionStatus.state != .stopped {
                try await Task.sleep(for: .seconds(1))
                completionStatus = try await restoredSession.status(for: id)
            }
            let payloadURL = documents.appending(path: selectedFile.path)
            report["completion"] = completionStatus.state.rawValue
            report["completionProgress"] = completionStatus.progress
            report["completionUploadRate"] = completionStatus.uploadRate
            report["completionPeers"] = completionStatus.connectedPeers
            report["completionInSwarm"] = completionStatus.isParticipatingInSwarm
            report["payloadPresent"] = FileManager.default.fileExists(atPath: payloadURL.path)
            writeAcceptance(report, to: reportURL)
        } catch {
            writeAcceptance(["metadata": true, "error": safe(error)], to: reportURL)
        }
    }

    private func writeAcceptance(_ value: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private func createSession() async throws {
        guard let ca = Bundle.main.url(forResource: "cacert-2026-08-13", withExtension: "pem") else {
            throw HarnessError.missingCABundle
        }
        session = try TorrentSession(configuration: .init(caBundleURL: ca))
    }

    @discardableResult
    private func updateWindow() async throws -> TorrentStreamingWindow {
        guard let session, let file = selectedFile else { throw HarnessError.noPayload }
        let window = try await session.updateStreamingWindow(
            for: id, fileIndex: file.index, byteOffset: byteOffset,
            forwardBufferBytes: 8 * 1_048_576, prioritizeFirstAndLastPieces: true
        )
        let pieces = try await session.pieces(for: id)
        windowDescription = "\(window.firstPieceIndex)...\(window.lastPieceIndex)"
        deadlineDescription = pieces.deadlinePieceIndexes.map(String.init).joined(separator: ", ")
        return window
    }

    private func beginStatusUpdates() {
        statusTask?.cancel()
        statusTask = Task {
            while !Task.isCancelled {
                guard let status = try? await session?.status(for: id) else { break }
                state = status.state.rawValue
                progress = status.progress
                downloadRate = status.downloadRate
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation(); error = nil }
        catch { self.error = safe(error) }
    }

    private func safe(_ error: Error) -> String {
        (error as? TorrentError)?.description ?? "Harness operation failed."
    }
}

private enum HarnessError: Error { case fixtureUnavailable, noPayload, missingCABundle }
