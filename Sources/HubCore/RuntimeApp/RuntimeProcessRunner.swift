import Foundation

/// What a finished child process left behind.
package struct RuntimeProcessResult: Equatable, Sendable {
  package let exitCode: Int32
  /// Standard output and standard error, in that order, as text.
  package let output: String

  package init(exitCode: Int32, output: String) {
    self.exitCode = exitCode
    self.output = output
  }
}

/// Runs a program with exactly the environment it is given. Injected so tests need no Wine.
package protocol RuntimeProcessRunner: Sendable {
  /// - Throws: `.io` when the program cannot start or does not end within `timeout` seconds (it
  ///   is then terminated).
  func run(
    executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval
  ) throws(HubError) -> RuntimeProcessResult
}

/// Runs the program as a child process of this one.
///
/// On timeout the child process is terminated, then killed; processes the child started are not
/// (the child's process group is left alone). The result keeps at most the first 64 KiB of output.
package struct LiveRuntimeProcessRunner: RuntimeProcessRunner {
  package init() {}

  package func run(
    executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval
  ) throws(HubError) -> RuntimeProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    // A file, not a pipe: a chatty program cannot fill a pipe nobody is reading.
    let capture = FileManager.default.temporaryDirectory
      .appendingPathComponent("gamehub-runtime-\(UUID().uuidString).out")
    guard FileManager.default.createFile(atPath: capture.path, contents: nil) else {
      throw .io("Cannot create \(capture.path).")
    }
    defer { try? FileManager.default.removeItem(at: capture) }
    let sink: FileHandle
    do {
      sink = try FileHandle(forWritingTo: capture)
    } catch {
      throw .io("Cannot open \(capture.path): \(error.localizedDescription)")
    }
    defer { try? sink.close() }
    process.standardOutput = sink
    process.standardError = sink

    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    do {
      try process.run()
    } catch {
      throw .io("Cannot run \(executable.path): \(error.localizedDescription)")
    }
    if ended.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if ended.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
      throw .io("\(executable.path) did not finish within \(Int(timeout)) seconds.")
    }
    // Only the first 64 KiB: a runaway program must not fill this process's memory.
    let data: Data
    do {
      let reader = try FileHandle(forReadingFrom: capture)
      defer { try? reader.close() }
      data = try reader.read(upToCount: 64 * 1024) ?? Data()
    } catch {
      throw .io("Cannot read the output of \(executable.path): \(error.localizedDescription)")
    }
    return RuntimeProcessResult(
      exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
  }
}
