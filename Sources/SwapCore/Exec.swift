import Foundation

struct ExecResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct ExecTimeout: Error {}

/// A value written on one thread and read on another after a wait
/// (semaphore / group) has ordered the two.
final class Handoff<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Runs a binary synchronously with a hard timeout. Both pipes are drained on
/// their own threads so a chatty child can't deadlock us. Call off the main thread.
func execRun(_ path: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval) throws -> ExecResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let input = stdin.map { _ in Pipe() }
    p.standardInput = input ?? FileHandle.nullDevice
    try p.run()
    if let input, let stdin {
        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()
    }

    let outData = Handoff(Data()), errData = Handoff(Data())
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outData.value = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData.value = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = group.wait(timeout: .now() + 1)
        throw ExecTimeout()
    }
    p.waitUntilExit()
    return ExecResult(status: p.terminationStatus, stdout: outData.value, stderr: errData.value)
}
