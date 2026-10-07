import Foundation
import LauncherCore
import Synchronization

/// Drains the Wine processes' output during a diagnostic launch, bounded and rotated.
///
/// The Wine processes write to `output`, the write end of a pipe. A reader thread splits what
/// arrives into lines, appends the `trace` lines to rotating debug files
/// (`NFS2015DiagnosticLog.Segments`) and passes every other line on to the session log. The
/// thread keeps reading whatever happens to a file it writes: a pipe nobody reads would stop the
/// game. It ends when every holder of the write end has closed it, which is when Wine is stopped.
package final class NFS2015DiagnosticCapture: Sendable {
  private struct State {
    var finished = false
    var segments: [URL] = []
    var failure: String?
  }

  /// What Wine's standard output and error are set to for this launch.
  package let output: FileHandle
  private let reader: FileHandle
  private let state = Mutex(State())
  private let condition = NSCondition()

  /// - Parameters:
  ///   - folder: Where the debug files go; created if absent. Old files are pruned first.
  ///   - main: The session log, which receives every line that is not a debug line.
  package convenience init(folder: URL, stamp: String, main: FileHandle) throws(LauncherError) {
    try self.init(folder: folder, stamp: stamp, main: main, pipe: Pipe())
  }

  /// The same, reading from a pipe the caller made, which a test can break.
  init(folder: URL, stamp: String, main: FileHandle, pipe: Pipe) throws(LauncherError) {
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw .operation("Could not create the log folder: \(error.localizedDescription)")
    }
    NFS2015DiagnosticLog.prune(in: folder, limit: NFS2015DiagnosticLog.totalBytes / 2)
    output = pipe.fileHandleForWriting
    reader = pipe.fileHandleForReading
    let thread = Thread { [self] in drain(folder: folder, stamp: stamp, main: main) }
    thread.name = "NFS2015 diagnostic log"
    thread.start()
  }

  private func drain(folder: URL, stamp: String, main: FileHandle) {
    var router = NFS2015DiagnosticLog.Router()
    var segments = NFS2015DiagnosticLog.Segments(folder: folder, stamp: stamp)
    func place(_ lines: [(route: NFS2015DiagnosticLog.Route, line: [UInt8])]) {
      for entry in lines {
        switch entry.route {
        case .debug: segments.append(entry.line)
        case .session:
          // A failed write to the session log must not stop the drain.
          try? main.write(contentsOf: Data(entry.line + [10]))
        }
      }
    }
    while true {
      let chunk: Data?
      do { chunk = try reader.read(upToCount: 65_536) } catch {
        // Closing the read end makes Wine's writes fail instead of blocking the game for good.
        state.withLock { $0.failure = error.localizedDescription }
        try? reader.close()
        break
      }
      guard let chunk, !chunk.isEmpty else { break }
      place(router.feed(chunk))
    }
    place(router.finish())
    segments.close()
    state.withLock {
      $0.segments = segments.files
      $0.failure = $0.failure ?? segments.failure
      $0.finished = true
    }
    condition.lock()
    condition.broadcast()
    condition.unlock()
  }

  /// The debug files this launch wrote so far.
  package var files: [URL] { state.withLock { $0.segments } }

  /// Why debug lines stopped being kept, if they did.
  package var failure: String? { state.withLock { $0.failure } }

  /// Closes this process's copy of the write end and waits for the reader to see the end.
  /// - Returns: Whether the reader finished within `timeout` seconds.
  @discardableResult
  package func finish(timeout: TimeInterval) -> Bool {
    do { try output.close() } catch { print("Could not close the diagnostic log pipe: \(error)") }
    let deadline = Date(timeIntervalSinceNow: timeout)
    condition.lock()
    defer { condition.unlock() }
    while !state.withLock({ $0.finished }) {
      if !condition.wait(until: deadline) { break }
    }
    return state.withLock { $0.finished }
  }
}
