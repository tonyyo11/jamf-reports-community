import Foundation
import Synchronization

/// Reads a child's pipe on a background handler so a child that writes past the pipe buffer
/// never blocks, and `finish()` returns what the child wrote, including what the handler had
/// not yet delivered when the child exited. `finish()` never waits for EOF, which a grandchild
/// that inherited the pipe can hold open long after the child is gone.
final class ProcessPipeDrainer: Sendable {
    /// Bytes kept per pipe; output past it is read and dropped, so a runaway child cannot grow
    /// memory without bound. A probe or tool answer (a version, `config list`) is far smaller.
    static let maxBytes = 64 * 1_024 * 1_024

    private struct State {
        var buffer = Data()
        var isFinishing = false
    }
    private let handle: FileHandle
    private let state = Mutex(State())

    init(pipe: Pipe) {
        handle = pipe.fileHandleForReading
    }

    func start() {
        handle.readabilityHandler = { [weak self] fileHandle in
            self?.drainAvailableData(from: fileHandle)
        }
    }

    func cancel() {
        handle.readabilityHandler = nil
    }

    /// Everything already in the pipe, without blocking. A byte the child wrote before it exited
    /// is in the kernel buffer; only a grandchild's later writes are left behind.
    func finish(deadline: TimeInterval = CLIBridge.timeoutKillGrace) -> Data {
        handle.readabilityHandler = nil

        return state.withLock { state in
            state.isFinishing = true
            let room = max(0, Self.maxBytes - state.buffer.count)
            Self.append(
                readWithoutBlocking(until: Date().addingTimeInterval(deadline), limit: room),
                to: &state)
            return state.buffer
        }
    }

    private static func append(_ data: Data, to state: inout State) {
        state.buffer.append(data.prefix(max(0, maxBytes - state.buffer.count)))
    }

    /// Reads until the pipe is empty (EAGAIN), at EOF, or at `deadline`, so a grandchild that
    /// keeps writing cannot hold the caller either.
    private func readWithoutBlocking(until deadline: Date, limit: Int) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                // Read on past the budget (to drain the pipe) but keep nothing beyond it.
                collected.append(contentsOf: chunk[0..<min(count, max(0, limit - collected.count))])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return collected
    }

    private func drainAvailableData(from fileHandle: FileHandle) {
        state.withLock { state in
            guard !state.isFinishing else { return }

            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }

            Self.append(data, to: &state)
        }
    }
}
