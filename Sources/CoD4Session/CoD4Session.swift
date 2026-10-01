import CoD4Core
import Foundation
import LauncherCore

struct CoD4Session {
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
      let profiles = CoD4ProfileStore(paths: paths)
      try profiles.recover()
      for folder in ["RuntimeHome/Player", "Temporary"] {
        try files.createDirectory(
          at: paths.support.appendingPathComponent(folder), withIntermediateDirectories: true)
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
        importing: options.action == "--import-game" ? options.request : nil,
        initializePrefix: runtime.initialize)
      try runtime.stop(paths.prefix)
      try GuestIsolation.restrict(prefix: paths.prefix, root: paths.support)
      if try profiles.list().isEmpty {
        try profiles.perform(.init(action: .create, name: "Player"))
      }
      let store = CoD4SettingsStore(paths: paths)
      var mode = options.mode
      var preferred = options.profile
      if options.action == "--profiles", let request = options.request {
        let operation = try JSONDecoder().decode(
          CoD4ProfileRequest.self, from: BoundedFile.read(request, limit: 65536))
        try profiles.perform(operation)
        preferred =
          [.create, .importProfile, .restore].contains(operation.action) ? operation.name : nil
      } else if ["--play", "--configure"].contains(options.action), let request = options.request {
        let configuration = try JSONDecoder().decode(
          CoD4LaunchRequest.self, from: BoundedFile.read(request, limit: 65536))
        try store.apply(configuration)
        mode = configuration.mode
        preferred = configuration.profile
      }
      let selected = try store.selectedProfile(preferred: preferred)
      try snapshot(mode: mode, profile: selected)
      guard options.action == "--play" else { return 0 }
      guard files.fileExists(atPath: game.appendingPathComponent(mode.executable).path) else {
        throw LauncherError.operation("This installation does not include the selected game mode.")
      }
      let drive = CoD4GameDrive(paths: paths)
      try drive.install()
      let status: Int32
      do {
        status = try ProcessCommand(
          executable: paths.wine,
          arguments: ["C:\\CoD4\\" + mode.executable, "+set", "com_playerProfile", selected],
          directory: game, environment: environment
        ).run(output: output, onStart: lease.record)
        try runtime.stop(paths.prefix)
        try lease.clear()
      } catch {
        do {
          try runtime.stop(paths.prefix)
          try lease.clear()
          try drive.remove()
        } catch { print("CoD4 session cleanup failed: \(error)") }
        throw error
      }
      try drive.remove()
      try snapshot(mode: mode, profile: selected)
      return status
    }
  }

  private func snapshot(mode: CoD4Mode, profile: String) throws {
    let settings =
      profile.isEmpty
      ? CoD4Settings() : try CoD4SettingsStore(paths: paths).load(profile: profile, mode: mode)
    let snapshot = CoD4Snapshot(
      settings: settings, profiles: try CoD4ProfileStore(paths: paths).list(),
      selectedProfile: profile)
    try JSONEncoder().encode(snapshot).write(
      to: paths.support.appendingPathComponent("launcher-state.json"), options: .atomic)
  }
}
