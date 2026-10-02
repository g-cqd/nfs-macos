import FarCry2Core
import Foundation
import LauncherCore

/// Prepares, configures and launches Far Cry 2 under one exclusive session lock.
struct FarCry2Session {
  let paths: AppPaths
  let output: FileHandle

  func run(_ options: SessionOptions) throws -> Int32 {
    let files = FileManager.default
    try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
    return try SessionLock.withLock(at: paths.support.appendingPathComponent("session.lock")) {
      let lease = GameLease(url: paths.support.appendingPathComponent("game-session.json"))
      try lease.check()
      try FileTransaction(root: paths.support).recover()
      try GuestIsolation.recover(prefix: paths.prefix)
      try FarCry2Backups(paths: paths).recover()
      for folder in ["RuntimeHome/Player", "Temporary"] {
        try files.createDirectory(
          at: paths.support.appendingPathComponent(folder), withIntermediateDirectories: true)
      }
      let runtime = WineRuntime(paths: paths, output: output)
      var environment = runtime.environment(prefix: paths.prefix)
      guard
        try ProcessCommand(
          executable: URL(fileURLWithPath: "/usr/bin/arch"),
          arguments: ["-x86_64", "/usr/bin/true"], directory: paths.support,
          environment: environment
        ).run(output: output) == 0
      else {
        throw LauncherError.operation(
          "Install Rosetta from the starter before preparing this game.")
      }
      let manifest = try BundleManifest.read(
        from: paths.resources.appendingPathComponent("game-manifest.json"))
      let game = try GameInstaller(paths: paths, manifest: manifest).prepare(
        importing: options.action == .importGame ? options.request : nil,
        initializePrefix: runtime.initialize)
      try runtime.stop(paths.prefix)
      let drive = GameDrive(paths: paths)
      try drive.removeStale()
      try GuestIsolation.restrict(prefix: paths.prefix, root: paths.support)
      let linked = try FarCry2UserData(paths: paths).install()
      report(linked: linked)
      let store = FarCry2SettingsStore(paths: paths)
      var plan = FarCry2Settings.LaunchPlan()
      switch options.action {
      case .importGame, .prepare: break
      case .backups:
        let request = try decode(FarCry2BackupRequest.self, options.request)
        try FarCry2Backups(paths: paths).perform(request)
      case .configure, .play:
        let request = try decode(FarCry2LaunchRequest.self, options.request)
        let state = try store.apply(request.settings)
        plan = request.settings.launchPlan()
        if state != .ready {
          print("GamerProfile.xml was not changed (\(state.rawValue)); renderer settings were.")
        }
      }
      try snapshot()
      guard options.action == .play else { return 0 }
      let executable = game.appendingPathComponent(GameKind.farcry2.executable)
      guard files.fileExists(atPath: executable.path) else {
        throw LauncherError.operation("The imported game has no bin/FarCry2.exe. Import it again.")
      }
      try drive.install()
      for (name, value) in plan.environment { environment[name] = value }
      let arguments = try launchArguments(plan)
      let status: Int32
      do {
        // The working directory is bin, as when the game is started from its install folder.
        status = try ProcessCommand(
          executable: paths.wine, arguments: arguments,
          directory: game.appendingPathComponent("bin"), environment: environment
        ).run(output: output, onStart: lease.record)
        try runtime.stop(paths.prefix)
        try lease.clear()
      } catch {
        do {
          try runtime.stop(paths.prefix)
          try lease.clear()
          try drive.remove()
        } catch { print("Far Cry 2 session cleanup failed: \(error)") }
        throw error
      }
      try drive.remove()
      try snapshot()
      return status
    }
  }

  /// The game's own switches, plus the console script when any cheat or world option is chosen.
  private func launchArguments(_ plan: FarCry2Settings.LaunchPlan) throws -> [String] {
    var arguments = ["C:\\FarCry2\\bin\\FarCry2.exe"] + plan.arguments
    let user = FarCry2UserData(paths: paths)
    let script = user.documents.appendingPathComponent(FarCry2Console.scriptName)
    if plan.console.isEmpty {
      if FileManager.default.fileExists(atPath: script.path) {
        try FileManager.default.removeItem(at: script)
      }
      return arguments
    }
    try Data(FarCry2Console.script(plan.console).utf8).write(to: script, options: .atomic)
    let profile = try user.windowsProfile().lastPathComponent
    arguments += [FarCry2Console.startupSwitch, FarCry2Console.windowsPath(profile: profile)]
    print(
      "Console script: \(plan.console.count) line(s) passed with \(FarCry2Console.startupSwitch).")
    return arguments
  }

  private func decode<T: Decodable>(_ type: T.Type, _ url: URL?) throws -> T {
    guard let url else { throw LauncherError.operation("This operation requires a request.") }
    return try JSONDecoder().decode(type, from: BoundedFile.read(url, limit: 65_536))
  }

  private func report(linked: FarCry2UserData.Outcome) {
    for item in linked.migrated { print("Moved existing \(item) into persistent player data.") }
    for item in linked.conflicts {
      print("Kept the existing \(item) folder aside in Saves/FarCry2/Conflicts.")
    }
    if let game = GameInstaller.installedGame(paths: paths) {
      print(
        "Recognised installation: file version \(game.fileVersion ?? "unknown"), "
          + "build \(game.build ?? "not on the verified list"), "
          + "hints \(game.markers.isEmpty ? "none" : game.markers.joined(separator: ", ")).")
      let strings = game.versionStrings.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
      print("Version resource: \(strings.isEmpty ? "none" : strings)")
    }
  }

  private func snapshot() throws {
    let loaded = try FarCry2SettingsStore(paths: paths).load()
    let snapshot = FarCry2Snapshot(
      settings: loaded.settings, profile: loaded.state,
      installation: GameInstaller.installedGame(paths: paths),
      backups: try FarCry2Backups(paths: paths).list(),
      keptAside: try FarCry2UserData(paths: paths).keptAside())
    try JSONEncoder().encode(snapshot).write(
      to: paths.support.appendingPathComponent("launcher-state.json"), options: .atomic)
  }
}
