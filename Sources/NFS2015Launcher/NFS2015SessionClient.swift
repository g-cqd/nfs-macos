import Foundation
import LauncherCore
import NFS2015Core

/// Keeps filesystem work and helper execution off the UI actor.
actor NFS2015SessionClient: NFS2015Serving {
  private let bundle: URL
  private let support: URL
  private var logURL: URL?

  init(bundle: URL = Bundle.main.bundleURL, support: URL? = nil) {
    self.bundle = bundle
    self.support =
      support
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/NFS2015Mac")
  }

  func logLocation() -> URL? { logURL }

  func perform(_ operation: NFS2015Operation) async throws -> NFS2015Snapshot {
    try Task.checkCancellation()
    let paths = try AppPaths(bundle: bundle, support: support, game: .nfs2015)
    let files = FileManager.default
    try files.createDirectory(at: support, withIntermediateDirectories: true)
    let logs = support.appendingPathComponent("Logs")
    try files.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("session-\(UUID().uuidString).log")
    logURL = log
    try Data().write(to: log, options: .withoutOverwriting)
    let output = try FileHandle(forWritingTo: log)
    var draft: URL?
    defer {
      do { try output.close() } catch { print("Could not close the session log: \(error)") }
      if let draft {
        do { try files.removeItem(at: draft) } catch {
          print("Could not remove the session request: \(error)")
        }
      }
    }
    var arguments = [paths.bundle.path, "--support", support.path]
    switch operation {
    case .prepare: arguments.append("--prepare")
    case .play: arguments.append("--play")
    case .enableController: arguments.append("--enable-controller")
    case .chooseInstallation(let folder):
      arguments += ["--choose-installation", "--request", folder.path]
    case .configure(let settings):
      try settings.validate()
      let request = support.appendingPathComponent("request-\(UUID().uuidString).json")
      try JSONEncoder().encode(settings).write(to: request, options: .withoutOverwriting)
      draft = request
      arguments += ["--configure", "--request", request.path]
    }
    let process = Process()
    process.executableURL = paths.session
    process.arguments = arguments
    process.currentDirectoryURL = bundle.deletingLastPathComponent()
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    let (events, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
    process.terminationHandler = { child in
      continuation.yield(child.terminationStatus)
      continuation.finish()
    }
    do { try process.run() } catch {
      continuation.finish()
      throw error
    }
    // The helper owns the game lock. UI cancellation detaches; it must not stop a live session.
    for await status in events {
      try Task.checkCancellation()
      guard status == 0 else {
        if status == 73 { throw LauncherError.alreadyRunning }
        throw LauncherError.operation(
          "The operation ended with status \(status). Open Log for details.")
      }
      return try NFS2015Snapshot.read(
        from: support.appendingPathComponent("launcher-state.json"))
    }
    throw CancellationError()
  }
}
