import Darwin
import Foundation

/// What the plan may ask of the running system. Injected so tests can answer without Wine or
/// `lsof`.
///
/// A probe that cannot answer throws; the check that asked then fails, because "nothing running"
/// must never be the answer to "could not look".
package protocol DatastoreProbe: Sendable {
  /// The command line of every process on the machine.
  func processCommandLines() throws(HubError) -> [String]
  /// The path of every file any process has open.
  func openFilePaths() throws(HubError) -> [String]
}

/// The probe of the live system: `ps` for processes and `lsof` for open files.
package struct LiveDatastoreProbe: DatastoreProbe {
  package init() {}

  package func processCommandLines() throws(HubError) -> [String] {
    let output = try Self.run("/bin/ps", ["-axww", "-o", "command="], tolerateFailure: false)
    return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  package func openFilePaths() throws(HubError) -> [String] {
    // lsof exits non-zero when it cannot read some processes; what it printed is still valid.
    let output = try Self.run("/usr/sbin/lsof", ["-nP", "-Fn"], tolerateFailure: true)
    return Self.parseOpenFiles(output)
  }

  /// The paths in `lsof -F n` output: the `n` lines that name a file (they start with `/`).
  package static func parseOpenFiles(_ output: String) -> [String] {
    var paths: [String] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard line.hasPrefix("n/") else { continue }
      paths.append(String(line.dropFirst()))
    }
    return paths
  }

  private static func run(
    _ executable: String, _ arguments: [String], tolerateFailure: Bool
  ) throws(HubError) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw .io("Cannot run \(executable): \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    if process.terminationStatus != 0 && !(tolerateFailure && !text.isEmpty) {
      throw .io("\(executable) exited with status \(process.terminationStatus).")
    }
    return text
  }
}

/// What the probe reported, taken once so a whole run sees one consistent picture.
package struct DatastoreProbeSnapshot: Sendable {
  private let processes: Result<[String], HubError>?
  private let files: Result<[String], HubError>?

  /// Takes only the readings asked for; asking for neither never touches the probe.
  package init(probe: any DatastoreProbe, processes wantProcesses: Bool, files wantFiles: Bool) {
    if wantProcesses {
      do {
        processes = .success(try probe.processCommandLines())
      } catch {
        processes = .failure(error)
      }
    } else {
      processes = nil
    }
    if wantFiles {
      do {
        files = .success(try probe.openFilePaths())
      } catch {
        files = .failure(error)
      }
    } else {
      files = nil
    }
  }

  /// The command lines that look like Wine: `wine` (which covers `wineserver`), `-preloader`, or
  /// `.exe`, ignoring case.
  /// - Throws: the probe's failure, or `.invalid` if processes were not read.
  package func wineProcessLines() throws(HubError) -> [String] {
    guard let processes else { throw .invalid("The process list was not read.") }
    let lines = try processes.get()
    return lines.filter {
      let lowered = $0.lowercased()
      return lowered.contains("wine") || lowered.contains("-preloader") || lowered.contains(".exe")
    }
  }

  /// The command line of every process.
  /// - Throws: the probe's failure, or `.invalid` if processes were not read.
  package func commandLines() throws(HubError) -> [String] {
    guard let processes else { throw .invalid("The process list was not read.") }
    return try processes.get()
  }

  /// The open files at or below `path`, for the path as written and for its resolved form.
  /// - Throws: the probe's failure, or `.invalid` if open files were not read.
  package func openFiles(under paths: [String]) throws(HubError) -> [String] {
    guard let files else { throw .invalid("The open-file list was not read.") }
    let all = try files.get()
    return all.filter { open in paths.contains { DatastorePath.isWithin(open, $0) } }
  }
}
