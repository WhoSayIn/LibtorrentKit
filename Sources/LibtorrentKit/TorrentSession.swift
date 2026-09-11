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

private final class NativeOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    func begin() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            running = true
            return true
        }
    }

    func finish() { lock.withLock { running = false } }

    func cancel() -> Bool {
        lock.withLock {
            cancelled = true
            return running
        }
    }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

private final class NativeSessionExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LibtorrentKit.NativeSession", qos: .utility)
    private let native: NativeSessionHandle

    init(native: NativeSessionHandle) {
        self.native = native
    }

    func perform<Result: Sendable>(
        _ operation: @escaping @Sendable (OpaquePointer) throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let cancellation = NativeOperationCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [native] in
                    guard cancellation.begin() else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    defer { cancellation.finish() }
                    guard let pointer = native.optionalPointer else {
                        continuation.resume(throwing: TorrentError(
                            operation: .shutdown,
                            code: .sessionShutDown,
                            description: "The torrent session has shut down."
                        ))
                        return
                    }
                    do {
                        let result = try operation(pointer)
                        if cancellation.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: result)
                        }
                    } catch {
                        continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: { [native] in
            if cancellation.cancel(), let pointer = native.optionalPointer {
                ltkit_session_wake(pointer)
            }
        }
    }

    func shutdown() async {
        if let pointer = native.optionalPointer { ltkit_session_wake(pointer) }
        await withCheckedContinuation { continuation in
            queue.async { [native] in
                native.destroy()
                continuation.resume()
            }
        }
    }
}

private struct TorrentGeometry: Sendable {
    struct File: Sendable {
        let offset: Int64
        let size: Int64
    }

    let pieceLength: Int
    let files: [Int: File]

    init(_ metadata: TorrentMetadata) {
        pieceLength = metadata.pieceLength
        files = Dictionary(uniqueKeysWithValues: metadata.files.map {
            ($0.index, File(offset: $0.torrentOffset, size: $0.size))
        })
    }
}

public actor TorrentSession {
    public nonisolated let events: AsyncStream<TorrentEvent>

    private let native: NativeSessionHandle
    private let nativeExecutor: NativeSessionExecutor
    private let eventTask: Task<Void, Never>
    private let checkpointTimeoutMilliseconds: Int32
    private var isShutDown = false
    private var identifiers: Set<UUID> = []
    private var geometry = [UUID: TorrentGeometry]()

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
        self.nativeExecutor = NativeSessionExecutor(native: native)
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
        try await nativeExecutor.perform { pointer in
            try Self.withSourceBytes(source) { sourceKind, sourceBytes in
                try request.resumeData.withOptionalUnsafeBytes { resumeBytes in
                    try selected.withUnsafeBufferPointer { selectedBuffer in
                        try request.id.uuidString.withCString { identifier in
                            try request.downloadDirectory.path.withCString { path in
                                let code = ltkit_session_add(
                                    pointer, identifier, sourceKind,
                                    sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), sourceBytes.count,
                                    resumeBytes?.baseAddress?.assumingMemoryBound(to: UInt8.self), resumeBytes?.count ?? 0,
                                    path, selectedBuffer.baseAddress, selectedBuffer.count,
                                    request.selectedFileIndexes != nil,
                                    Int32(request.primaryFileIndex ?? -1), request.beginsPaused,
                                    Int32(clamping: request.rateLimits.downloadBytesPerSecond),
                                    Int32(clamping: request.rateLimits.uploadBytesPerSecond),
                                    request.completionPolicy == .seed ? 1 : 0
                                )
                                try Self.check(code, operation: .add, pointer: pointer)
                            }
                        }
                    }
                }
            }
        }
        identifiers.insert(request.id)
    }

    public func metadata(for id: UUID) async throws -> TorrentMetadata {
        try ensureRunning(operation: .metadata)
        let metadata: TorrentMetadata = try await nativeExecutor.perform { pointer in
            try Self.decodeJSON(operation: .metadata, pointer: pointer) { buffer in
                id.uuidString.withCString { ltkit_session_metadata(pointer, $0, 30_000, buffer) }
            }
        }
        geometry[id] = TorrentGeometry(metadata)
        return metadata
    }

    public func selectFiles(for id: UUID, selectedFileIndexes: Set<Int>, primaryFileIndex: Int?) async throws {
        let indexes = try nativeIndexes(selectedFileIndexes, operation: .selection)
        if let primaryFileIndex, !selectedFileIndexes.contains(primaryFileIndex) {
            throw TorrentError(operation: .selection, code: .invalidFileIndex, description: "The primary file must be selected.")
        }
        try ensureRunning(operation: .selection)
        try await nativeExecutor.perform { pointer in
            try indexes.withUnsafeBufferPointer { values in
                let code = id.uuidString.withCString {
                    ltkit_session_select_files(pointer, $0, values.baseAddress, values.count, Int32(primaryFileIndex ?? -1))
                }
                try Self.check(code, operation: .selection, pointer: pointer)
            }
        }
    }

    public func setFilePriority(_ priority: TorrentPriority, forFileAt fileIndex: Int, in id: UUID) async throws {
        guard let index = Int32(exactly: fileIndex), index >= 0 else {
            throw TorrentError(operation: .priority, code: .invalidFileIndex, description: "The file index is outside the supported range.")
        }
        try ensureRunning(operation: .priority)
        try await nativeExecutor.perform { pointer in
            let code = id.uuidString.withCString {
                ltkit_session_set_file_priority(pointer, $0, index, priority.rawValue)
            }
            try Self.check(code, operation: .priority, pointer: pointer)
        }
    }

    public func setPiecePriority(_ priority: TorrentPriority, forPieceAt pieceIndex: Int, in id: UUID) async throws {
        guard let index = Int32(exactly: pieceIndex), index >= 0 else {
            throw TorrentError(operation: .priority, code: .invalidPieceIndex, description: "The piece index is outside the supported range.")
        }
        try ensureRunning(operation: .priority)
        try await nativeExecutor.perform { pointer in
            let code = id.uuidString.withCString {
                ltkit_session_set_piece_priority(pointer, $0, index, priority.rawValue)
            }
            try Self.check(code, operation: .priority, pointer: pointer)
        }
    }

    public func start(_ id: UUID) async throws { try await simple(id, .start, ltkit_session_start) }
    public func pause(_ id: UUID) async throws { try await simple(id, .pause, ltkit_session_pause) }

    public func status(for id: UUID) async throws -> TorrentStatus {
        try ensureRunning(operation: .status)
        return try await nativeExecutor.perform { pointer in
            try Self.decodeJSON(operation: .status, pointer: pointer) { buffer in
                id.uuidString.withCString { ltkit_session_status(pointer, $0, buffer) }
            }
        }
    }

    public func pieces(for id: UUID) async throws -> TorrentPieceSnapshot {
        try ensureRunning(operation: .pieces)
        return try await nativeExecutor.perform { pointer in
            try Self.decodeJSON(operation: .pieces, pointer: pointer) { buffer in
                id.uuidString.withCString { ltkit_session_pieces(pointer, $0, buffer) }
            }
        }
    }

    /// Returns completion-only piece state without constructing or decoding JSON.
    public func pieceCompletion(for id: UUID) async throws -> TorrentPieceCompletion {
        try ensureRunning(operation: .pieces)
        return try await nativeExecutor.perform { pointer in
            var pieceCount: Int32 = 0
            var buffer = ltkit_buffer_t(data: nil, size: 0)
            let code = id.uuidString.withCString {
                ltkit_session_piece_completion(pointer, $0, &pieceCount, &buffer)
            }
            try Self.check(code, operation: .pieces, pointer: pointer)
            let completionBitset = Self.takeData(&buffer) ?? Data()
            let count = Int(pieceCount)
            guard count >= 0, completionBitset.count == (count + 7) / 8 else {
                throw TorrentError(operation: .pieces, code: .nativeFailure, description: "The native piece completion response was malformed.")
            }
            return TorrentPieceCompletion(pieceCount: count, completionBitset: completionBitset)
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
        let currentGeometry: TorrentGeometry
        if let cached = geometry[id] {
            currentGeometry = cached
        } else {
            currentGeometry = TorrentGeometry(try await metadata(for: id))
            geometry[id] = currentGeometry
        }
        guard let file = currentGeometry.files[fileIndex] else {
            throw TorrentError(operation: .streamingWindow, code: .invalidFileIndex, description: "The streaming file index is invalid.")
        }
        _ = try PieceWindowPlan.make(
            fileOffset: file.offset,
            fileSize: file.size,
            pieceLength: currentGeometry.pieceLength,
            byteOffset: byteOffset,
            criticalBufferBytes: criticalBufferBytes,
            warmBufferBytes: warmBufferBytes,
            consumptionBytesPerSecond: consumptionBytesPerSecond
        )
        return try await nativeExecutor.perform { pointer in
            try Self.decodeJSON(operation: .streamingWindow, pointer: pointer) { buffer in
                id.uuidString.withCString {
                    ltkit_session_update_streaming_window(
                        pointer, $0, nativeFileIndex, byteOffset, criticalBufferBytes,
                        warmBufferBytes, consumptionBytesPerSecond,
                        prioritizeFirstAndLastPieces, buffer
                    )
                }
            }
        }
    }

    public func clearStreamingWindow(for id: UUID) async throws {
        try await simple(id, .streamingWindow, ltkit_session_clear_streaming_window)
    }

    public func checkpoint(_ id: UUID, flushDiskCache: Bool) async throws -> Data {
        try ensureRunning(operation: .checkpoint)
        let timeout = checkpointTimeoutMilliseconds
        return try await nativeExecutor.perform { pointer in
            var buffer = ltkit_buffer_t(data: nil, size: 0)
            let code = id.uuidString.withCString {
                ltkit_session_checkpoint(pointer, $0, flushDiskCache, timeout, &buffer)
            }
            try Self.check(code, operation: .checkpoint, pointer: pointer)
            return Self.takeData(&buffer) ?? Data()
        }
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
        try await simple(id, .remove) { session, identifier in ltkit_session_remove(session, identifier, deleteFiles) }
        identifiers.remove(id)
        geometry.removeValue(forKey: id)
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        eventTask.cancel()
        ltkit_session_wake(native.pointer)
        await eventTask.value
        geometry.removeAll()
        await nativeExecutor.shutdown()
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
        _ function: @escaping @Sendable (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    ) async throws {
        try ensureRunning(operation: operation)
        try await nativeExecutor.perform { pointer in
            let code = id.uuidString.withCString { function(pointer, $0) }
            try Self.check(code, operation: operation, pointer: pointer)
        }
    }

    private static func decodeJSON<Value: Decodable>(
        operation: TorrentError.Operation,
        pointer: OpaquePointer,
        _ body: (UnsafeMutablePointer<ltkit_buffer_t>) -> Int32
    ) throws -> Value {
        var buffer = ltkit_buffer_t(data: nil, size: 0)
        let code = body(&buffer)
        try check(code, operation: operation, pointer: pointer)
        guard let data = Self.takeData(&buffer) else {
            throw TorrentError(operation: operation, code: .nativeFailure, description: "The native response was empty.")
        }
        do { return try JSONDecoder.ltkit.decode(Value.self, from: data) }
        catch { throw TorrentError(operation: operation, code: .nativeFailure, description: "The native response was malformed.") }
    }

    private static func check(_ code: Int32, operation: TorrentError.Operation, pointer: OpaquePointer) throws {
        guard code != LTKIT_OK else { return }
        throw TorrentError.native(operation: operation, code: code, description: takeNativeError(pointer))
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

    private static func withSourceBytes<Result>(
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
