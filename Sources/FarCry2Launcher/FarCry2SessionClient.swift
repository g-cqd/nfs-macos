import FarCry2Core
import Foundation
import LauncherCore

/// Keeps filesystem work and helper execution off the UI actor.
actor FarCry2SessionClient: FarCry2Serving {
  private let bundle: URL
  private let support: URL
  private var logURL: URL?

  init(bundle: URL = Bundle.main.bundleURL, support: URL? = nil) {
    self.bundle = bundle
    self.support =
      support
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FarCry2Mac")
  }

  func hasGameData() throws -> Bool { try paths().hasGameData }
  func logLocation() -> URL? { logURL }

  func perform(_ operation: FarCry2Operation) async throws -> FarCry2Snapshot {
    try Task.checkCancellation()
    let paths = try paths()
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let logs = support.appendingPathComponent("Logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("session-\(UUID().uuidString).log")
    logURL = log
    try Data().write(to: log, options: .withoutOverwriting)
    let output = try FileHandle(forWritingTo: log)
    var draft: URL?
    defer {
      do { try output.close() } catch { print("Could not close Far Cry 2 log: \(error)") }
      if let draft {
        do { try FileManager.default.removeItem(at: draft) } catch {
          print("Could not remove Far Cry 2 request: \(error)")
        }
      }
    }
    var arguments = [paths.bundle.path, "--support", support.path]
    var data: Data?
    switch operation {
    case .prepare: arguments.append("--prepare")
    case .play(let request), .configure(let request):
      try request.settings.validate()
      if case .play = operation {
        arguments.append("--play")
      } else {
        arguments.append("--configure")
      }
      data = try JSONEncoder().encode(request)
    case .backups(let request):
      arguments.append("--backups")
      data = try JSONEncoder().encode(request)
    case .importGame(let source): arguments += ["--import-game", "--request", source.path]
    }
    if let data {
      let request = support.appendingPathComponent("request-\(UUID().uuidString).json")
      try data.write(to: request, options: .withoutOverwriting)
      draft = request
      arguments += ["--request", request.path]
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
    // The helper owns the game lock. UI cancellation detaches; it must not kill a live game.
    for await status in events {
      try Task.checkCancellation()
      guard status == 0 else {
        if status == 73 { throw LauncherError.alreadyRunning }
        throw LauncherError.operation(
          "The operation ended with status \(status). Open Log for details.")
      }
      return try JSONDecoder().decode(
        FarCry2Snapshot.self,
        from: BoundedFile.read(support.appendingPathComponent("launcher-state.json")))
    }
    throw CancellationError()
  }

  func readSetup(_ url: URL) throws -> FarCry2Settings {
    let settings = try JSONDecoder().decode(
      FarCry2Settings.self, from: BoundedFile.read(url, limit: 65_536))
    try settings.validate()
    return settings
  }

  func writeSetup(_ settings: FarCry2Settings, to url: URL) throws {
    try settings.validate()
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    let privatePath = support.standardizedFileURL.resolvingSymlinksInPath().path
    guard resolved.path != privatePath, !resolved.path.hasPrefix(privatePath + "/") else {
      throw LauncherError.operation("Export the setup outside the game's player data folder.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: resolved, options: .atomic)
  }

  private func paths() throws -> AppPaths {
    try AppPaths(bundle: bundle, support: support, game: .farcry2)
  }
}
