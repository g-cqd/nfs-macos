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
      let cache = shaderCache()
      // A crashed session leaves its cache in the game folder, and a new generation would not carry it.
      if files.fileExists(atPath: paths.currentGame.path) {
        attempt("take back the previous cache") {
          report(harvest: try cache.harvest(game: paths.currentGame))
        }
      }
      let runtime = WineRuntime(paths: paths, output: output)
      let environment = try runtime.environment(prefix: paths.prefix)
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
      switch options.action {
      case .importGame, .prepare: break
      case .backups:
        let request = try decode(FarCry2BackupRequest.self, options.request)
        try FarCry2Backups(paths: paths).perform(request)
      case .configure, .play:
        let request = try decode(FarCry2LaunchRequest.self, options.request)
        let state = try store.apply(request.settings)
        if state != .ready {
          print("GamerProfile.xml was not changed (\(state.rawValue)); renderer settings were.")
        }
      case .shaderCache:
        try perform(try decode(FarCry2ShaderCacheRequest.self, options.request), cache, game: game)
      }
      try snapshot(cache)
      guard options.action == .play else { return 0 }
      let executable = game.appendingPathComponent(GameKind.farcry2.executable)
      guard files.fileExists(atPath: executable.path) else {
        throw LauncherError.operation("The imported game has no bin/FarCry2.exe. Import it again.")
      }
      attempt("place the cache") { report(launch: try cache.prepare(game: game)) }
      try drive.install()
      let status: Int32
      do {
        // The working directory is bin, as when the game is started from its install folder.
        status = try ProcessCommand(
          executable: paths.wine, arguments: ["C:\\FarCry2\\bin\\FarCry2.exe"],
          directory: game.appendingPathComponent("bin"), environment: environment
        ).run(output: output, onStart: lease.record)
        try runtime.stop(paths.prefix)
        attempt("save the cache") { report(harvest: try cache.harvest(game: game)) }
        try lease.clear()
      } catch {
        do {
          try runtime.stop(paths.prefix)
          attempt("save the cache") { report(harvest: try cache.harvest(game: game)) }
          try lease.clear()
          try drive.remove()
        } catch { print("Far Cry 2 session cleanup failed: \(error)") }
        throw error
      }
      try drive.remove()
      try snapshot(cache)
      return status
    }
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

  private func snapshot(_ cache: FarCry2ShaderCache) throws {
    let loaded = try FarCry2SettingsStore(paths: paths).load()
    let snapshot = FarCry2Snapshot(
      settings: loaded.settings, profile: loaded.state,
      installation: GameInstaller.installedGame(paths: paths),
      backups: try FarCry2Backups(paths: paths).list(),
      keptAside: try FarCry2UserData(paths: paths).keptAside(),
      shaderCache: cache.status())
    try JSONEncoder().encode(snapshot).write(
      to: paths.support.appendingPathComponent("launcher-state.json"), options: .atomic)
  }
}
