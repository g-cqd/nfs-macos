import Foundation
import LauncherCore

struct Session {
  let paths: AppPaths
  let output: FileHandle

  func run(mode: String, configuration: URL?) throws -> Int32 {
    let files = FileManager.default
    let runtime = WineRuntime(paths: paths, output: output)
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
      var environment = runtime.environment(prefix: paths.prefix)
      let rosetta = ProcessCommand(
        executable: URL(fileURLWithPath: "/usr/bin/arch"),
        arguments: ["-x86_64", "/usr/bin/true"], directory: paths.support, environment: environment)
      guard try rosetta.run(output: output) == 0 else {
        throw LauncherError.operation(
          "Rosetta is required. Install Rosetta, then reopen Most Wanted.")
      }
      let game = try GameInstaller(paths: paths, manifest: manifest).prepare(
        importing: mode == "--import-game" ? configuration : nil,
        initializePrefix: runtime.initialize)
      try runtime.stop(paths.prefix)
      try GuestIsolation.restrict(prefix: paths.prefix, root: paths.support)
      let store = SettingsStore(paths: paths)
      var settings = try store.load()
      if mode == "--save", let configuration {
        let action = try JSONDecoder().decode(
          SaveRequest.self, from: BoundedFile.read(configuration, limit: 262_144))
        try SaveStore(paths: paths).perform(action)
      } else if let configuration, mode != "--import-game" {
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
      try runtime.stop(paths.prefix)
      try LauncherSnapshot.read(paths: paths).write(paths: paths)
      return status
    }
  }

}
