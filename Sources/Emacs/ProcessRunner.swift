import Foundation

/// Shared subprocess runner: drains stdout/stderr concurrently while the
/// process runs (so large output cannot deadlock the pipes), enforces a
/// timeout with terminate-then-SIGKILL escalation, and caps captured output.
enum ProcessRunner {
  struct Output {
    let exitStatus: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
  }

  static let defaultTimeout: TimeInterval = 30
  static let defaultMaxOutputBytes = 5 * 1024 * 1024

  static func run(
    executable: String,
    arguments: [String],
    timeout: TimeInterval = defaultTimeout,
    maxOutputBytes: Int = defaultMaxOutputBytes
  ) throws -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = FileHandle.nullDevice

    let lock = NSLock()
    var stdoutData = Data()
    var stderrData = Data()

    func appendCapped(_ chunk: Data, to buffer: inout Data) {
      let remaining = maxOutputBytes - buffer.count
      guard remaining > 0 else { return }
      buffer.append(chunk.prefix(remaining))
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      lock.lock()
      appendCapped(chunk, to: &stdoutData)
      lock.unlock()
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      lock.lock()
      appendCapped(chunk, to: &stderrData)
      lock.unlock()
    }

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    try process.run()

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      process.terminate()
      if exited.wait(timeout: .now() + 2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 2)
      }
    }
    process.waitUntilExit()

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
      lock.lock()
      appendCapped(rest, to: &stdoutData)
      lock.unlock()
    }
    if let rest = try? stderrPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
      lock.lock()
      appendCapped(rest, to: &stderrData)
      lock.unlock()
    }

    lock.lock()
    defer { lock.unlock() }
    return Output(
      exitStatus: process.terminationStatus,
      stdout: stdoutData,
      stderr: stderrData,
      timedOut: timedOut
    )
  }
}
