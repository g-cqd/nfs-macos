import Foundation
import LauncherCore
import NFS2015Core

/// Keeps filesystem work and helper execution off the UI actor.
actor NFS2015SessionClient: NFS2015Serving {
  private let bundle: URL
  private let support: URL
  private var logURL: URL?

  /// The environment variable that points the starter at another player folder, for testing an
  /// app without touching the real one. `HOME` cannot do this: the system reports the account's
  /// home folder from the user database, so changing `HOME` never moved the player folder.
  static let supportFolderVariable = "NFS2015_SUPPORT_FOLDER"

  /// The player folder: the override when it names an absolute folder, else the account's own.
  static func supportFolder(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let override = environment[supportFolderVariable], override.hasPrefix("/"),
      !override.split(separator: "/").contains("..")
    {
      return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
    return home.appendingPathComponent("Library/Application Support/NFS2015Mac")
  }

  init(bundle: URL = Bundle.main.bundleURL, support: URL? = nil) {
    self.bundle = bundle
    self.support = support ?? Self.supportFolder()
  }

  func logLocation() -> URL? { logURL }

  /// Reads the staged game folder of a running first-launch preparation, never the player's files.
  func preparationProgress() -> PrefixSeed.Progress? {
    guard let paths = try? AppPaths(bundle: bundle, support: support, game: .nfs2015),
      let manifest = try? BundleManifest.read(
        from: paths.resources.appendingPathComponent("game-manifest.json"))
    else { return nil }
    return PrefixSeed(paths: paths, manifest: manifest).progress()
  }

  /// The newest crash report below the player folder's `Logs`, written at or after `date`.
  func latestCrashReport(since date: Date) -> NFS2015CrashNotice? {
    NFS2015CrashReportStore(folder: support.appendingPathComponent("Logs")).latest(since: date)
  }

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
    case .installClient(let installer):
      arguments += ["--install-client", "--request", installer.path]
    case .openClient: arguments.append("--open-client")
    case .configureMetalFX(let choice):
      try choice.validate()
      let request = support.appendingPathComponent("request-\(UUID().uuidString).json")
      try JSONEncoder().encode(choice).write(to: request, options: .withoutOverwriting)
      draft = request
      arguments += ["--configure-metalfx", "--request", request.path]
    case .configureDiagnostics(let choice):
      try choice.validate()
      let request = support.appendingPathComponent("request-\(UUID().uuidString).json")
      try JSONEncoder().encode(choice).write(to: request, options: .withoutOverwriting)
      draft = request
      arguments += ["--configure-diagnostics", "--request", request.path]
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
