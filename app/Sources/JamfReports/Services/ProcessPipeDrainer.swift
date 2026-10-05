import Foundation

/// Reads a child's pipe on a background handler so a child that writes past the pipe buffer
/// never blocks, and `finish()` returns everything up to EOF, including what the handler had
/// not yet delivered when the child exited.
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

    func finish() -> Data {
        handle.readabilityHandler = nil

        lock.lock()
        isFinishing = true
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty {
            buffer.append(remaining)
        }
        let data = buffer
        lock.unlock()

        return data
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
