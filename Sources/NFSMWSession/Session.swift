import Foundation
import LauncherCore

struct Session {
  let paths: AppPaths
  let output: FileHandle

  func run(mode: String, configuration: URL?) throws -> Int32 {
    let files = FileManager.default
    try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
    return try SessionLock.withLock(at: paths.support.appendingPathComponent("session.lock")) {
      let lease = GameLease(url: paths.support.appendingPathComponent("game-session.json"))
      try lease.check()
      try FileTransaction(root: paths.support).recover()
      try GuestIsolation.recover(prefix: paths.prefix)
      for name in ["RuntimeHome/Player", "Temporary"] {
        try files.createDirectory(
          at: paths.support.appendingPathComponent(name), withIntermediateDirectories: true)
      }
      let manifest = try BundleManifest.read(
        from: paths.resources.appendingPathComponent("game-manifest.json"))
      var environment = environment(prefix: paths.prefix)
      let rosetta = ProcessCommand(
        executable: URL(fileURLWithPath: "/usr/bin/arch"),
        arguments: ["-x86_64", "/usr/bin/true"], directory: paths.support, environment: environment)
      guard try rosetta.run(output: output) == 0 else {
        throw LauncherError.operation(
          "Rosetta is required. Install Rosetta, then reopen Most Wanted.")
      }
      let game = try GameInstaller(paths: paths, manifest: manifest).prepare(
        initializePrefix: preparePrefix)
      try stopServer(prefix: paths.prefix)
      try GuestIsolation.restrict(prefix: paths.prefix, root: paths.support)
      let store = SettingsStore(paths: paths)
      var settings = try store.load()
      if mode == "--save", let configuration {
        let action = try JSONDecoder().decode(
          SaveRequest.self, from: BoundedFile.read(configuration, limit: 262_144))
        try SaveStore(paths: paths).perform(action)
      } else if let configuration {
        settings = try JSONDecoder().decode(
          GameSettings.self, from: BoundedFile.read(configuration, limit: 1_048_576))
        try settings.validate()
        try store.apply(settings)
      } else if mode == "--play" {
        settings.mappings = try store.mapping(profile: settings.mappingProfile)
        try store.apply(settings)
      }
      try LauncherSnapshot.read(paths: paths).write(paths: paths)
      guard mode == "--play" else { return 0 }
      environment["MTL_HUD_ENABLED"] = settings.value("hud")
      let status = try ProcessCommand(
        executable: paths.wine, arguments: ["C:\\NFSMW\\speed.exe"],
        directory: game, environment: environment
      ).run(output: output, onStart: lease.record)
      try lease.clear()
      try stopServer(prefix: paths.prefix)
      try LauncherSnapshot.read(paths: paths).write(paths: paths)
      return status
    }
  }

  private func environment(prefix: URL) -> [String: String] {
    LaunchEnvironment.make(
      paths: paths, prefix: prefix,
      home: paths.support.appendingPathComponent("RuntimeHome/Player"),
      temporary: paths.support.appendingPathComponent("Temporary"))
  }

  private func preparePrefix(_ prefix: URL) throws {
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
    let environment = environment(prefix: prefix)
    do {
      let boot = ProcessCommand(
        executable: paths.wine, arguments: ["wineboot", "--init"],
        directory: prefix, environment: environment)
      guard try boot.run(output: output) == 0 else {
        throw LauncherError.operation("Wine could not initialize the player folder.")
      }
      let settings = ProcessCommand(
        executable: paths.wine,
        arguments: [
          "reg", "import", paths.resources.appendingPathComponent("Defaults/settings.reg").path,
        ],
        directory: prefix, environment: environment)
      guard try settings.run(output: output) == 0 else {
        throw LauncherError.operation("Wine could not import the game and controller settings.")
      }
      try stopServer(prefix: prefix)
    } catch {
      do { try stopServer(prefix: prefix) } catch { print("Setup cleanup failed: \(error)") }
      throw error
    }
  }

  private func stopServer(prefix: URL) throws {
    let environment = environment(prefix: prefix)
    try WineShutdown.stop { argument in
      let command = ProcessCommand(
        executable: paths.wineServer, arguments: [argument],
        directory: prefix, environment: environment)
      return try command.run(output: output)
    }
  }
}
