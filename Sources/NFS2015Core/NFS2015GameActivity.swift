import Foundation
import LauncherCore

/// Whether Need for Speed (2015) is running on this Mac, however it was started.
///
/// The game reads its options file at start and rewrites it at exit, so a change made while it
/// runs is lost, and a write that races its exit could interleave with its own. The session lock
/// and game lease already exclude a game this app started; this also sees one started through
/// the EA app by hand. The check is by program name in the process list, so another program
/// whose command line names the game also counts: the wrong answer is a refusal, never a write.
package struct NFS2015GameActivity: Sendable {
  /// True when the game runs, false when it does not, nil when that could not be found out.
  package let isRunning: @Sendable () -> Bool?

  package init(isRunning: @escaping @Sendable () -> Bool?) { self.isRunning = isRunning }

  /// Looks for the game's executable in the process list.
  package static let system = Self {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axww", "-o", "command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // The pipe is drained before waiting so a long process list cannot block the child.
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0, data.count <= 16_777_216 else { return nil }
    return containsGame(inProcessList: String(decoding: data, as: UTF8.self))
  }

  /// Whether any line of a `ps` listing runs the game's executable.
  /// - Complexity: O(size of the listing).
  package static func containsGame(inProcessList text: String) -> Bool {
    let program = GameKind.nfs2015.executable.lowercased()
    return text.lowercased().split(separator: "\n").contains { line in
      guard let range = line.range(of: program) else { return false }
      // `NFS16.exe` must end a path component or a word; `NFS16.exe.bak` is not the game.
      let after = line[range.upperBound...].first
      return after == nil || after == " " || after == "\"" || after == "'"
    }
  }
}
