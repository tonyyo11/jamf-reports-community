import Foundation

/// Reads a child's pipe on a background handler so a child that writes past the pipe buffer
/// never blocks, and `finish()` returns what the child wrote, including what the handler had
/// not yet delivered when the child exited. `finish()` never waits for EOF, which a grandchild
/// that inherited the pipe can hold open long after the child is gone.
final class ProcessPipeDrainer: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinishing = false

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

        lock.lock()
        isFinishing = true
        buffer.append(readWithoutBlocking(until: Date().addingTimeInterval(deadline)))
        let data = buffer
        lock.unlock()

        return data
    }

    /// Reads until the pipe is empty (EAGAIN), at EOF, or at `deadline`, so a grandchild that
    /// keeps writing cannot hold the caller either.
    private func readWithoutBlocking(until deadline: Date) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: chunk[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return collected
    }

    private func drainAvailableData(from fileHandle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinishing else { return }

        let data = fileHandle.availableData
        guard !data.isEmpty else {
            fileHandle.readabilityHandler = nil
            return
        }

        buffer.append(data)
    }
}
