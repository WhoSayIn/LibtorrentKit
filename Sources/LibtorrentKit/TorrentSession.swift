import Foundation
@preconcurrency import LibtorrentNative

private final class NativeSessionHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: OpaquePointer?
    var pointer: OpaquePointer {
        lock.withLock { storage! }
    }
    var optionalPointer: OpaquePointer? { lock.withLock { storage } }
    init(_ pointer: OpaquePointer) { self.storage = pointer }

    func destroy() {
        let value = lock.withLock {
            let value = storage
            storage = nil
            return value
        }
        if let value { ltkit_session_destroy(value) }
    }

    deinit { destroy() }
}

public actor TorrentSession {
    public nonisolated let events: AsyncStream<TorrentEvent>

    private let native: NativeSessionHandle
    private let eventTask: Task<Void, Never>
    private let checkpointTimeoutMilliseconds: Int32
    private var isShutDown = false
    private var identifiers: Set<UUID> = []

    public init(configuration: TorrentSessionConfiguration) throws {
        guard configuration.caBundleURL.isFileURL,
              FileManager.default.isReadableFile(atPath: configuration.caBundleURL.path) else {
            throw TorrentError(operation: .initialize, code: .invalidArgument, description: "The CA bundle is not a readable local file.")
        }
        var pointer: OpaquePointer?
        let result: Int32 = configuration.userAgent.withCString { userAgent in
            configuration.caBundleURL.path.withCString { caPath in
                var nativeConfiguration = ltkit_session_configuration_t(
                    user_agent: userAgent,
                    ca_bundle_path: caPath,
                    listen_port_start: configuration.listenPortRange.lowerBound,
                    listen_port_end: configuration.listenPortRange.upperBound,
                    enable_dht: configuration.enableDHT,
                    enable_lsd: configuration.enableLocalServiceDiscovery,
                    enable_upnp: configuration.enableUPnP,
                    enable_natpmp: configuration.enableNATPMP
                )
                return ltkit_session_create(&nativeConfiguration, &pointer)
            }
        }
        guard result == LTKIT_OK, let pointer else {
            throw TorrentError.native(operation: .initialize, code: result, description: "The native session could not be created.")
        }
        let native = NativeSessionHandle(pointer)
        self.native = native
        let components = configuration.checkpointTimeout.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        self.checkpointTimeoutMilliseconds = Int32(clamping: milliseconds)

        let (stream, continuation) = AsyncStream<TorrentEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.eventTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                guard let pointer = native.optionalPointer else { break }
                var buffer = ltkit_buffer_t(data: nil, size: 0)
                let code = ltkit_session_next_event(pointer, 500, &buffer)
                if code == LTKIT_OK, let data = Self.takeData(&buffer),
                   let envelope = try? JSONDecoder.ltkit.decode(NativeEventEnvelope.self, from: data),
                   let event = envelope.event() {
                    continuation.yield(event)
                } else if code != LTKIT_ERROR_TIMED_OUT && code != LTKIT_ERROR_SESSION_SHUT_DOWN {
                    let description = Self.takeNativeError(pointer)
                    continuation.yield(.error(id: nil, error: .native(operation: .event, code: code, description: description)))
                }
            }
            continuation.finish()
        }
    }

    deinit {
        eventTask.cancel()
        if let pointer = native.optionalPointer { ltkit_session_wake(pointer) }
    }

    public func add(_ request: TorrentAddRequest) async throws {
        try ensureRunning(operation: .add)
        let source = try request.source.validated()
        guard request.downloadDirectory.isFileURL else {
            throw TorrentError(operation: .add, code: .invalidArgument, description: "The download directory must be a local file URL.")
        }
        let selected = try nativeIndexes(request.selectedFileIndexes ?? [], operation: .add)
        if let primary = request.primaryFileIndex,
           request.selectedFileIndexes?.contains(primary) == false {
            throw TorrentError(operation: .add, code: .invalidFileIndex, description: "The primary file must be selected.")
        }
        try withSourceBytes(source) { sourceKind, sourceBytes in
            try request.resumeData.withOptionalUnsafeBytes { resumeBytes in
                try selected.withUnsafeBufferPointer { selectedBuffer in
                    try request.id.uuidString.withCString { identifier in
                        try request.downloadDirectory.path.withCString { path in
                            let code = ltkit_session_add(
                                native.pointer, identifier, sourceKind,
                                sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), sourceBytes.count,
                                resumeBytes?.baseAddress?.assumingMemoryBound(to: UInt8.self), resumeBytes?.count ?? 0,
                                path, selectedBuffer.baseAddress, selectedBuffer.count,
                                request.selectedFileIndexes != nil,
                                Int32(request.primaryFileIndex ?? -1), request.beginsPaused,
                                Int32(clamping: request.rateLimits.downloadBytesPerSecond),
                                Int32(clamping: request.rateLimits.uploadBytesPerSecond),
                                request.completionPolicy == .seed ? 1 : 0
                            )
                            try check(code, operation: .add)
                        }
                    }
                }
            }
        }
        identifiers.insert(request.id)
    }

    public func metadata(for id: UUID) async throws -> TorrentMetadata {
        try decodeJSON(operation: .metadata) { buffer in
            id.uuidString.withCString { ltkit_session_metadata(native.pointer, $0, 30_000, buffer) }
        }
    }

    public func selectFiles(for id: UUID, selectedFileIndexes: Set<Int>, primaryFileIndex: Int?) async throws {
        let indexes = try nativeIndexes(selectedFileIndexes, operation: .selection)
        if let primaryFileIndex, !selectedFileIndexes.contains(primaryFileIndex) {
            throw TorrentError(operation: .selection, code: .invalidFileIndex, description: "The primary file must be selected.")
        }
        try indexes.withUnsafeBufferPointer { values in
            let code = id.uuidString.withCString {
                ltkit_session_select_files(native.pointer, $0, values.baseAddress, values.count, Int32(primaryFileIndex ?? -1))
            }
            try check(code, operation: .selection)
        }
    }

    public func setFilePriority(_ priority: TorrentPriority, forFileAt fileIndex: Int, in id: UUID) async throws {
        guard let index = Int32(exactly: fileIndex), index >= 0 else {
            throw TorrentError(operation: .priority, code: .invalidFileIndex, description: "The file index is outside the supported range.")
        }
        let code = id.uuidString.withCString {
            ltkit_session_set_file_priority(native.pointer, $0, index, priority.rawValue)
        }
        try check(code, operation: .priority)
    }

    public func setPiecePriority(_ priority: TorrentPriority, forPieceAt pieceIndex: Int, in id: UUID) async throws {
        guard let index = Int32(exactly: pieceIndex), index >= 0 else {
            throw TorrentError(operation: .priority, code: .invalidPieceIndex, description: "The piece index is outside the supported range.")
        }
        let code = id.uuidString.withCString {
            ltkit_session_set_piece_priority(native.pointer, $0, index, priority.rawValue)
        }
        try check(code, operation: .priority)
    }

    public func start(_ id: UUID) async throws { try simple(id, .start, ltkit_session_start) }
    public func pause(_ id: UUID) async throws { try simple(id, .pause, ltkit_session_pause) }

    public func status(for id: UUID) async throws -> TorrentStatus {
        try decodeJSON(operation: .status) { buffer in
            id.uuidString.withCString { ltkit_session_status(native.pointer, $0, buffer) }
        }
    }

    public func pieces(for id: UUID) async throws -> TorrentPieceSnapshot {
        try decodeJSON(operation: .pieces) { buffer in
            id.uuidString.withCString { ltkit_session_pieces(native.pointer, $0, buffer) }
        }
    }

    public func updateStreamingWindow(
        for id: UUID,
        fileIndex: Int,
        byteOffset: Int64,
        criticalBufferBytes: Int64,
        warmBufferBytes: Int64,
        consumptionBytesPerSecond: Int64,
        prioritizeFirstAndLastPieces: Bool
    ) async throws -> TorrentStreamingWindow {
        guard let nativeFileIndex = Int32(exactly: fileIndex) else {
            throw TorrentError(operation: .streamingWindow, code: .invalidFileIndex, description: "The file index is outside the supported range.")
        }
        let currentMetadata = try await metadata(for: id)
        guard let file = currentMetadata.files.first(where: { $0.index == fileIndex }) else {
            throw TorrentError(operation: .streamingWindow, code: .invalidFileIndex, description: "The streaming file index is invalid.")
        }
        _ = try PieceWindowPlan.make(
            fileOffset: file.torrentOffset,
            fileSize: file.size,
            pieceLength: currentMetadata.pieceLength,
            byteOffset: byteOffset,
            criticalBufferBytes: criticalBufferBytes,
            warmBufferBytes: warmBufferBytes,
            consumptionBytesPerSecond: consumptionBytesPerSecond
        )
        return try decodeJSON(operation: .streamingWindow) { buffer in
            id.uuidString.withCString {
                ltkit_session_update_streaming_window(
                    native.pointer, $0, nativeFileIndex, byteOffset, criticalBufferBytes,
                    warmBufferBytes, consumptionBytesPerSecond,
                    prioritizeFirstAndLastPieces, buffer
                )
            }
        }
    }

    public func clearStreamingWindow(for id: UUID) async throws {
        try simple(id, .streamingWindow, ltkit_session_clear_streaming_window)
    }

    public func checkpoint(_ id: UUID, flushDiskCache: Bool) async throws -> Data {
        var buffer = ltkit_buffer_t(data: nil, size: 0)
        let code = id.uuidString.withCString {
            ltkit_session_checkpoint(native.pointer, $0, flushDiskCache, checkpointTimeoutMilliseconds, &buffer)
        }
        try check(code, operation: .checkpoint)
        return Self.takeData(&buffer) ?? Data()
    }

    public func checkpointAll(flushDiskCache: Bool) async -> [UUID: Result<Data, TorrentError>] {
        var results: [UUID: Result<Data, TorrentError>] = [:]
        for id in knownIdentifiers() {
            do { results[id] = .success(try await checkpoint(id, flushDiskCache: flushDiskCache)) }
            catch let error as TorrentError { results[id] = .failure(error) }
            catch { results[id] = .failure(.init(operation: .checkpoint, code: .unknown, description: "The checkpoint failed.")) }
        }
        return results
    }

    public func remove(_ id: UUID, deleteFiles: Bool) async throws {
        try simple(id, .remove) { session, identifier in ltkit_session_remove(session, identifier, deleteFiles) }
        identifiers.remove(id)
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        eventTask.cancel()
        ltkit_session_wake(native.pointer)
        await eventTask.value
        native.destroy()
    }

    private func knownIdentifiers() -> [UUID] {
        Array(identifiers)
    }

    private func nativeIndexes(_ indexes: Set<Int>, operation: TorrentError.Operation) throws -> [Int32] {
        try indexes.sorted().map {
            guard $0 >= 0, let value = Int32(exactly: $0) else {
                throw TorrentError(operation: operation, code: .invalidFileIndex, description: "A file index is outside the supported range.")
            }
            return value
        }
    }

    private func simple(
        _ id: UUID,
        _ operation: TorrentError.Operation,
        _ function: (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    ) throws {
        try ensureRunning(operation: operation)
        let code = id.uuidString.withCString { function(native.pointer, $0) }
        try check(code, operation: operation)
    }

    private func decodeJSON<Value: Decodable>(
        operation: TorrentError.Operation,
        _ body: (UnsafeMutablePointer<ltkit_buffer_t>) -> Int32
    ) throws -> Value {
        try ensureRunning(operation: operation)
        var buffer = ltkit_buffer_t(data: nil, size: 0)
        let code = body(&buffer)
        try check(code, operation: operation)
        guard let data = Self.takeData(&buffer) else {
            throw TorrentError(operation: operation, code: .nativeFailure, description: "The native response was empty.")
        }
        do { return try JSONDecoder.ltkit.decode(Value.self, from: data) }
        catch { throw TorrentError(operation: operation, code: .nativeFailure, description: "The native response was malformed.") }
    }

    private func check(_ code: Int32, operation: TorrentError.Operation) throws {
        guard code != LTKIT_OK else { return }
        throw TorrentError.native(operation: operation, code: code, description: Self.takeNativeError(native.pointer))
    }

    private func ensureRunning(operation: TorrentError.Operation) throws {
        guard !isShutDown else {
            throw TorrentError(operation: operation, code: .sessionShutDown, description: "The torrent session has shut down.")
        }
    }

    private static func takeData(_ buffer: inout ltkit_buffer_t) -> Data? {
        guard let bytes = buffer.data, buffer.size > 0 else { return nil }
        let data = Data(bytes: bytes, count: buffer.size)
        ltkit_buffer_free(buffer)
        buffer = .init(data: nil, size: 0)
        return data
    }

    private static func takeNativeError(_ session: OpaquePointer) -> String? {
        var buffer = ltkit_buffer_t(data: nil, size: 0)
        guard ltkit_session_take_last_error(session, &buffer) == LTKIT_OK,
              let data = takeData(&buffer) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func withSourceBytes<Result>(
        _ source: ValidatedTorrentSource,
        _ body: (Int32, UnsafeRawBufferPointer) throws -> Result
    ) throws -> Result {
        switch source {
        case .magnet(let value):
            return try Data(value.utf8).withUnsafeBytes { try body(0, $0) }
        case .torrentData(let data):
            return try data.withUnsafeBytes { try body(1, $0) }
        }
    }
}

private extension Optional where Wrapped == Data {
    func withOptionalUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer?) throws -> Result) rethrows -> Result {
        switch self {
        case .some(let data): return try data.withUnsafeBytes { try body($0) }
        case .none: return try body(nil)
        }
    }
}

private extension JSONDecoder {
    static var ltkit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
