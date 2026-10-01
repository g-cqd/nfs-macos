import Foundation
import LauncherCore
import NFS2015Core

/// Runs one Need for Speed (2015) operation against the player's referenced installation.
///
/// This session never creates, copies or restricts a Windows prefix. The game is activated by
/// the player's own EA client, whose account session lives in that one prefix; duplicating it
/// invalidates the session, so the app records where it is and runs it in place.
struct NFS2015Session {
  let paths: AppPaths
  let output: FileHandle

  func run(_ options: SessionOptions) throws -> Int32 {
    let files = FileManager.default
    try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
    return try SessionLock.withLock(at: paths.support.appendingPathComponent("session.lock")) {
      let lease = GameLease(url: paths.support.appendingPathComponent("game-session.json"))
      try lease.check()
      try FileTransaction(root: paths.support).recover()
      try PlayerFileEdit(support: paths.support).recover()
      for folder in ["RuntimeHome/Player", "Temporary"] {
        try files.createDirectory(
          at: paths.support.appendingPathComponent(folder), withIntermediateDirectories: true)
      }
      let manifest = try BundleManifest.read(
        from: paths.resources.appendingPathComponent("game-manifest.json"))
      guard manifest.kind == paths.kind, manifest.references, let plan = manifest.client else {
        throw LauncherError.operation("The game manifest belongs to a different app.")
      }
      let reference = InstallReference(support: paths.support, plan: plan)
      var readiness = try reference.readiness()
      if options.action == "--choose-installation", let request = options.request {
        readiness = try reference.adopt(request, transaction: FileTransaction(root: paths.support))
      }
      let store = NFS2015SettingsStore(support: paths.support, install: readiness.install)
      var settings = try store.load()
      if options.action == "--configure", let request = options.request {
        let requested = try JSONDecoder().decode(
          NFS2015Settings.self, from: BoundedFile.read(request, limit: 65_536))
        // The game's own file is the record, so the snapshot reports what it now holds.
        settings = try store.apply(requested)
      }
      if let install = readiness.install, options.action != "--configure" {
        try recordPrefixSettings(manifest.registry, install: install, tuning: manifest.tuning)
      }
      if options.action == "--enable-controller" {
        try enableController(
          devices: manifest.controllers, readiness: readiness, tuning: manifest.tuning)
      }
      try snapshot(readiness: readiness, store: store, settings: settings)
      guard options.action == "--play" else { return 0 }
      guard let install = readiness.install else {
        throw LauncherError.operation(
          readiness.message ?? "Choose your Windows folder before playing.")
      }
      let runtime = WineRuntime(paths: paths, output: output, tuning: manifest.tuning)
      let environment = try runtime.environment(prefix: install.prefix)
      guard
        try ProcessCommand(
          executable: URL(fileURLWithPath: "/usr/bin/arch"),
          arguments: ["-x86_64", "/usr/bin/true"], directory: paths.support,
          environment: environment
        ).run(output: output) == 0
      else {
        throw LauncherError.operation("Install Rosetta from the starter before playing.")
      }
      let status = try play(
        plan: try NFS2015LaunchPlan.make(install: install, plan: plan), environment: environment,
        runtime: runtime, prefix: install.prefix, lease: lease)
      try snapshot(readiness: readiness, store: store, settings: try store.load())
      return status
    }
  }

  /// Records the display and runtime registry values this game needs in the referenced prefix.
  ///
  /// These are not game options, so the game's own file cannot hold them: Wine reads them from
  /// the prefix. Without `RetinaMode` the driver advertises the scaled logical desktop instead
  /// of the native panel, the full-screen mode the game asks for does not exist, and Wine
  /// substitutes the nearest one. Each value is imported only when the prefix lacks it, so a
  /// prepared prefix is left completely untouched.
  private func recordPrefixSettings(
    _ settings: [RegistrySetting], install: NFS2015Install, tuning: RuntimeTuning
  ) throws {
    let runtime = WineRuntime(paths: paths, output: output, tuning: tuning)
    let applied = try PrefixPreparation(support: paths.support).apply(
      settings, in: install.prefix
    ) { script in
      guard
        try ProcessCommand(
          executable: paths.wine, arguments: ["reg", "import", script.path],
          directory: paths.support, environment: try runtime.environment(prefix: install.prefix)
        ).run(output: output) == 0
      else {
        throw LauncherError.operation("Wine could not record the prefix settings.")
      }
    }
    guard !applied.isEmpty else { return }
    for setting in applied {
      print("Recorded \(setting.name)=\(setting.value) in your Windows folder: \(setting.reason)")
    }
    try runtime.stop(install.prefix)
  }

  /// Imports the controller key into the referenced prefix, with the player asking for it.
  ///
  /// This is the one registry change the app makes to a prefix it does not own, so it never
  /// happens as part of a launch.
  private func enableController(
    devices: [String], readiness: NFS2015Readiness, tuning: RuntimeTuning
  ) throws {
    guard let install = readiness.install else {
      throw LauncherError.operation(
        readiness.message ?? "Choose your Windows folder before enabling a controller.")
    }
    let script = paths.support.appendingPathComponent("Temporary/controller.reg")
    try Data(try NFS2015Controller.registry(devices: devices).utf8).write(
      to: script, options: .atomic)
    defer {
      do { try FileManager.default.removeItem(at: script) } catch {
        print("Could not remove the controller script: \(error)")
      }
    }
    let runtime = WineRuntime(paths: paths, output: output, tuning: tuning)
    guard
      try ProcessCommand(
        executable: paths.wine, arguments: ["reg", "import", script.path],
        directory: paths.support, environment: try runtime.environment(prefix: install.prefix)
      ).run(output: output) == 0
    else {
      throw LauncherError.operation("Wine could not record the controller setting.")
    }
    try runtime.stop(install.prefix)
  }

  /// Starts the client, waits for it to come up, then hands it the launch request.
  ///
  /// The session owns the client process for the whole play session: the client keeps running
  /// while the game it started runs, so quitting the client ends the session.
  private func play(
    plan: NFS2015LaunchPlan, environment: [String: String], runtime: WineRuntime, prefix: URL,
    lease: GameLease
  ) throws -> Int32 {
    let started = Date()
    let client = try ProcessCommand(
      executable: paths.wine, arguments: plan.client.wineArguments,
      directory: plan.workingDirectory, environment: environment
    ).start(output: output)
    do {
      try lease.record(process: client.processIdentifier)
      let waited = try ClientReadiness(
        evidence: plan.readinessEvidence, children: plan.readinessChildren,
        deadline: plan.readinessSeconds
      ).wait(
        since: started, modified: ClientReadiness.newestModification,
        isRunning: { client.isRunning },
        helpers: { ProcessFamily.descendants(of: client.processIdentifier) },
        wait: { seconds in Thread.sleep(forTimeInterval: Double(seconds)) })
      print("The EA app was ready after \(waited) seconds.")
      let request = try ProcessCommand(
        executable: paths.wine, arguments: plan.request.wineArguments,
        directory: plan.workingDirectory, environment: environment
      ).run(output: output)
      guard request == 0 else {
        throw LauncherError.operation(
          """
          The EA app refused the launch request (\(request)). Open the EA app, make sure Need \
          for Speed is installed and your account is signed in, then play again.
          """)
      }
      client.waitUntilExit()
    } catch {
      if client.isRunning { client.terminate() }
      client.waitUntilExit()
      do {
        try lease.clear()
        try runtime.stop(prefix)
      } catch { print("Need for Speed session cleanup failed: \(error)") }
      throw error
    }
    try lease.clear()
    try runtime.stop(prefix)
    return client.terminationStatus
  }

  private func snapshot(
    readiness: NFS2015Readiness, store: NFS2015SettingsStore, settings: NFS2015Settings
  ) throws {
    try NFS2015Snapshot(
      blocker: readiness.message, clientVersion: readiness.install?.clientVersion,
      installedAt: readiness.install?.prefix.path,
      hasOptionsFile: try store.optionsFile() != nil, settings: settings
    ).write(to: paths.support.appendingPathComponent("launcher-state.json"))
  }
}
