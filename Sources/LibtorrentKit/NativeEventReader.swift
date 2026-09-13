import Foundation
@preconcurrency import LibtorrentNative

// AsyncStream's unfolding initializer has no intermediate buffer. Read one
// event per next() on a separate native lane so checkpoint calls cannot block
// event delivery, and slow consumers leave events in the bounded mailbox.
final class NativeEventReader: @unchecked Sendable {
    private let native: NativeSessionHandle
    private let executor: NativeSessionExecutor
    private let lock = NSLock()
    private var closed = false

    init(native: NativeSessionHandle) {
        self.native = native
        self.executor = NativeSessionExecutor(native: native)
    }

    private var isClosed: Bool { lock.withLock { closed } }

    func close() {
        lock.withLock { closed = true }
        native.wake()
    }

    func shutdown() async {
        close()
        await executor.drain()
    }

    func next() async -> TorrentEvent? {
        while !isClosed && !Task.isCancelled {
            do {
                let event = try await executor.perform { [self] pointer -> TorrentEvent? in
                    guard !isClosed else { return nil }
                    var buffer = ltkit_buffer_t(data: nil, size: 0)
                    let code = ltkit_session_next_event(pointer, 500, &buffer)
                    defer { ltkit_buffer_free(buffer) }
                    if code == LTKIT_ERROR_TIMED_OUT { return nil }
                    if code == LTKIT_ERROR_SESSION_SHUT_DOWN {
                        close()
                        return nil
                    }
                    guard code == LTKIT_OK, let bytes = buffer.data else {
                        return .error(id: nil, error: .native(
                            operation: .event, code: code,
                            description: "The native event could not be read."
                        ))
                    }
                    let data = Data(bytes: bytes, count: buffer.size)
                    guard let envelope = try? JSONDecoder().decode(NativeEventEnvelope.self, from: data),
                          let event = envelope.event() else {
                        return .error(id: nil, error: .native(
                            operation: .event, code: Int32(LTKIT_ERROR_NATIVE_FAILURE),
                            description: "The native event could not be decoded."
                        ))
                    }
                    return event
                }
                guard !isClosed && !Task.isCancelled else { return nil }
                if let event { return event }
            } catch is CancellationError {
                return nil
            } catch {
                close()
                return nil
            }
        }
        return nil
    }
}
