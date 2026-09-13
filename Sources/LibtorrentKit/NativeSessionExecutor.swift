import Foundation
@preconcurrency import LibtorrentNative

final class NativeSessionHandle: @unchecked Sendable {
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

    func wake() {
        lock.withLock { if let storage { ltkit_session_wake(storage) } }
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

final class NativeSessionExecutor: @unchecked Sendable {
    enum Semantics: Sendable {
        case cancellable
        /// Cancellation can prevent execution, but cannot replace its committed result.
        case mutation
    }

    enum OperationBoundary: Sendable {
        case beforeExecution, afterExecution
    }

    private let queue = DispatchQueue(label: "LibtorrentKit.NativeSession", qos: .utility)
    private let native: NativeSessionHandle
    // Internal injection point for deterministic native-return cancellation races.
    private let operationBoundary: (@Sendable (OperationBoundary) -> Void)?

    init(
        native: NativeSessionHandle,
        operationBoundary: (@Sendable (OperationBoundary) -> Void)? = nil
    ) {
        self.native = native
        self.operationBoundary = operationBoundary
    }

    func perform<Value: Sendable>(
        semantics: Semantics = .cancellable,
        _ operation: @escaping @Sendable (OpaquePointer) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let cancellation = NativeOperationCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [native, operationBoundary] in
                    operationBoundary?(.beforeExecution)
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
                    let result = Result { try operation(pointer) }
                    operationBoundary?(.afterExecution)
                    if semantics == .cancellable && cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        // Once a mutation starts, deliver the native outcome even if
                        // cancelled so the actor and its caller can reconcile state.
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: { [native] in
            if cancellation.cancel(), semantics == .cancellable { native.wake() }
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func shutdown() async {
        native.wake()
        await withCheckedContinuation { continuation in
            queue.async { [native] in
                native.destroy()
                continuation.resume()
            }
        }
    }
}
