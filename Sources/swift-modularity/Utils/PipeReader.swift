import Foundation

/// Reads a pipe to its end on another thread, so that both pipes of a process can be read at
/// once: a process that fills one while only the other is read would block.
final class PipeReader: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
