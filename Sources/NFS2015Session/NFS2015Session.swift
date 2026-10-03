import Foundation
import LauncherCore
import NFS2015Core

/// Runs one Need for Speed (2015) operation, in the player's referenced Windows folder or, for
/// the bundled edition, in the Windows folder this app created and seeded with its game.
///
/// Either way the game is activated by the player's own EA client, whose account session lives
/// in that one prefix; duplicating it invalidates the session. An import app records where the
/// player's prefix is and runs it in place. A bundled app creates one prefix on first launch,
/// copies the packaged game into it once, and never copies, replaces or resets it afterwards.
struct NFS2015Session {
  let paths: AppPaths
  let output: FileHandle

  func run(_ options: SessionOptions) throws -> Int32 {
    let files = FileManager.default
    try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
    return try SessionLock.withLock(at: paths.support.appendingPathComponent("session.lock")) {
      let lease = GameLease(url: paths.support.appendingPathComponent("game-session.json"))
      // An EA app this app started earlier and left running is reused, never refused, restarted
      // or stopped: it may be signed in, or waiting for the player to sign in.
      let adopted = runningClient(lease: lease, action: options.action)
      if adopted == nil { try lease.check() }
      try FileTransaction(root: paths.support).recover()
      try PlayerFileEdit(support: paths.support).recover()
      for folder in ["RuntimeHome/Player", "Temporary"] {
        try files.createDirectory(
          at: paths.support.appendingPathComponent(folder), withIntermediateDirectories: true)
      }
      let metalFX = metalFXState(for: options)
      let manifest = try BundleManifest.read(
        from: paths.resources.appendingPathComponent("game-manifest.json"))
      guard manifest.kind == paths.kind, let plan = manifest.client,
        manifest.references || manifest.seedsPrefix
      else {
        throw LauncherError.operation("The game manifest belongs to a different app.")
      }
      let owned = manifest.seedsPrefix
      let runtime = WineRuntime(
        paths: paths, output: output, tuning: manifest.tuning,
        renderers: manifest.rendererSelection, managedRuntime: manifest.managed,
        environments: NFS2015MetalFX.environment(for: metalFX.preference).map { [$0] } ?? [])
      var readiness: NFS2015Readiness
      if owned {
        guard options.action != "--choose-installation" else {
          throw LauncherError.operation("This app runs the game in its own Windows folder.")
        }
        _ = try PrefixSeed(paths: paths, manifest: manifest).prepare { prefix in
          try initialize(prefix, manifest: manifest, runtime: runtime)
        }
        readiness = try NFS2015Locator.resolve(prefix: paths.prefix, plan: plan)
      } else {
        guard !["--install-client", "--open-client"].contains(options.action) else {
          throw LauncherError.operation("This app runs the game in your own Windows folder.")
        }
        let reference = InstallReference(support: paths.support, plan: plan)
        readiness = try reference.readiness()
        if options.action == "--choose-installation", let request = options.request {
          readiness = try reference.adopt(
            request, transaction: FileTransaction(root: paths.support))
        }
      }
      var store = NFS2015SettingsStore(support: paths.support, install: readiness.install)
      var settingsOutcome: NFS2015SettingsOutcome?
      if options.action == "--configure", let request = options.request {
        let requested = try JSONDecoder().decode(
          NFS2015SettingsRequest.self, from: BoundedFile.read(request, limit: 65_536))
        // A refusal is an answer, not a failure: the starter shows the reason beside the
        // settings, and the snapshot below reports what the game's file holds.
        do { settingsOutcome = try store.apply(requested) } catch {
          settingsOutcome = .refused(error.localizedDescription)
        }
      }
      let prefix = owned ? paths.prefix : readiness.install?.prefix
      if options.action != "--configure", adopted == nil, let prefix {
        try recordPrefixSettings(manifest.registry, prefix: prefix, runtime: runtime)
      }
      if options.action == "--enable-controller" {
        try enableController(
          devices: manifest.controllers, readiness: readiness, runtime: runtime, owned: owned)
      }
      if options.action == "--install-client", let request = options.request {
        try installClient(request, plan: plan, runtime: runtime, lease: lease)
        readiness = try NFS2015Locator.resolve(prefix: paths.prefix, plan: plan)
        store = NFS2015SettingsStore(support: paths.support, install: readiness.install)
      }
      if options.action == "--open-client" {
        try openClient(plan: plan, runtime: runtime, lease: lease, adopted: adopted)
        readiness = try NFS2015Locator.resolve(prefix: paths.prefix, plan: plan)
        store = NFS2015SettingsStore(support: paths.support, install: readiness.install)
      }
      try snapshot(
        readiness: readiness, store: store, plan: plan, owned: owned, outcome: settingsOutcome,
        metalFX: metalFX)
      guard options.action == "--play" else { return 0 }
      guard let install = readiness.install else {
        throw LauncherError.operation(
          (owned ? readiness.ownedMessage : readiness.message)
            ?? "Choose your Windows folder before playing.")
      }
      let environment = try runtime.environment(prefix: install.prefix)
      try requireRosetta(environment)
      if metalFX.preference.spatialUpscaling {
        print(
          "MetalFX spatial upscaling is on at \(metalFX.preference.factor.rawValue)x for "
            + "\(NFS2015MetalFX.executable) only.")
      }
      if let notice = metalFX.notice { print(notice) }
      let outcome = try play(
        plan: try NFS2015LaunchPlan.make(install: install, plan: plan), environment: environment,
        runtime: runtime, prefix: install.prefix, lease: lease, adopted: adopted)
      switch outcome {
      case .finished(let status):
        try snapshot(
          readiness: readiness, store: store, plan: plan, owned: owned, metalFX: metalFX)
        return status
      case .notReady(let notice):
        print(notice)
        try snapshot(
          readiness: readiness, store: store, plan: plan, owned: owned, notice: notice,
          metalFX: metalFX)
        return 0
      }
    }
  }

  /// Carries out a MetalFX request, if this is one, and reads the choice the launch will use.
  ///
  /// A choice that cannot be read is MetalFX off with a notice, never a failure, so nothing here
  /// can stop Play from starting the game.
  private func metalFXState(for options: SessionOptions) -> NFS2015MetalFXState {
    let store = NFS2015MetalFXStore(support: paths.support)
    var outcome: NFS2015MetalFXOutcome?
    if options.action == "--configure-metalfx", let request = options.request {
      do {
        let requested = try JSONDecoder().decode(
          NFS2015MetalFXRequest.self, from: BoundedFile.read(request, limit: 4096))
        outcome = store.apply(requested)
      } catch { outcome = .refused(error.localizedDescription) }
    }
    let loaded = store.load()
    return NFS2015MetalFXState(
      preference: loaded.preference, notice: loaded.notice, outcome: outcome)
  }

  /// The EA app this app recorded earlier, when it is still running and the operation can use it.
  ///
  /// Only the EA client is reused. A recorded installer or game still running keeps being
  /// refused, and an operation that would stop Wine never adopts a running client.
  private func runningClient(lease: GameLease, action: String) -> Int32? {
    guard ["--play", "--open-client", "--prepare"].contains(action),
      let pid = lease.activeProcess(), ProcessFamily.runs(pid: pid, program: "EADesktop.exe")
    else { return nil }
    return pid
  }

  /// How a Play ended.
  private enum PlayOutcome {
    /// The client ended after the game was requested.
    case finished(Int32)
    /// The client is running and not ready; it was left running, with this to tell the player.
    case notReady(String)
  }

  /// Builds the unpublished prefix of a bundled app: Wine's defaults, then exactly the registry
  /// values the recipe declares, including the controller key, which is this app's to write, then
  /// the .NET runtime the EA client's own updater needs, then the EA client that comes with the
  /// app. The client layer is applied last and while Wine is stopped, because it edits the hives.
  private func initialize(_ prefix: URL, manifest: BundleManifest, runtime: WineRuntime) throws {
    try requireRosetta(try runtime.environment(prefix: prefix))
    try runtime.initializeBare(prefix)
    do {
      try recordPrefixSettings(manifest.registry, prefix: prefix, runtime: runtime)
      if !manifest.controllers.isEmpty {
        try importRegistry(
          try NFS2015Controller.registry(devices: manifest.controllers), named: "controller",
          prefix: prefix, runtime: runtime)
      }
      _ = try runtime.installManagedRuntime(into: prefix)
    } catch {
      do { try runtime.stop(prefix) } catch { print("Wine setup cleanup failed: \(error)") }
      throw error
    }
    try runtime.stop(prefix)
    if let reference = manifest.layer {
      let layer = try ClientLayer(
        root: paths.resources.appendingPathComponent(reference.path),
        expectedSHA256: reference.manifestSHA256)
      print("Installing the \(layer.summary) that comes with this app, without signing in to it.")
      try layer.apply(to: prefix)
    }
  }

  private func requireRosetta(_ environment: [String: String]) throws {
    guard
      try ProcessCommand(
        executable: URL(fileURLWithPath: "/usr/bin/arch"),
        arguments: ["-x86_64", "/usr/bin/true"], directory: paths.support,
        environment: environment
      ).run(output: output) == 0
    else {
      throw LauncherError.operation("Install Rosetta from the starter before playing.")
    }
  }

  /// Imports a registry script into a prefix through the bundle's own Wine.
  private func importRegistry(
    _ script: String, named name: String, prefix: URL, runtime: WineRuntime
  ) throws {
    let url = paths.support.appendingPathComponent("Temporary/\(name).reg")
    try Data(script.utf8).write(to: url, options: .atomic)
    defer {
      do { try FileManager.default.removeItem(at: url) } catch {
        print("Could not remove the \(name) script: \(error)")
      }
    }
    guard
      try ProcessCommand(
        executable: paths.wine, arguments: ["reg", "import", url.path],
        directory: paths.support, environment: try runtime.environment(prefix: prefix)
      ).run(output: output) == 0
    else {
      throw LauncherError.operation("Wine could not record the \(name) setting.")
    }
  }

  /// Records the display and runtime registry values this game needs in a prefix.
  ///
  /// These are not game options, so the game's own file cannot hold them: Wine reads them from
  /// the prefix. Without `RetinaMode` the driver advertises the scaled logical desktop instead
  /// of the native panel, the full-screen mode the game asks for does not exist, and Wine
  /// substitutes the nearest one. Each value is imported only when the prefix lacks it, so a
  /// prepared prefix is left completely untouched.
  private func recordPrefixSettings(
    _ settings: [RegistrySetting], prefix: URL, runtime: WineRuntime
  ) throws {
    let applied = try PrefixPreparation(support: paths.support).apply(settings, in: prefix) {
      script in
      let environment = try runtime.environment(prefix: prefix)
      try requireRosetta(environment)
      guard
        try ProcessCommand(
          executable: paths.wine, arguments: ["reg", "import", script.path],
          directory: paths.support, environment: environment
        ).run(output: output) == 0
      else {
        throw LauncherError.operation("Wine could not record the prefix settings.")
      }
    }
    guard !applied.isEmpty else { return }
    for setting in applied {
      print("Recorded \(setting.name)=\(setting.value) in your Windows folder: \(setting.reason)")
    }
    try runtime.stop(prefix)
  }

  /// Imports the controller key into the prefix, with the player asking for it.
  ///
  /// In a folder the player chose, this is the one registry change the app makes to a prefix it
  /// does not own, so it never happens as part of a launch. A bundled app writes the same key
  /// while it creates its own prefix, and this stays available to apply it again.
  private func enableController(
    devices: [String], readiness: NFS2015Readiness, runtime: WineRuntime, owned: Bool
  ) throws {
    guard let install = readiness.install else {
      throw LauncherError.operation(
        (owned ? readiness.ownedMessage : readiness.message)
          ?? "Choose your Windows folder before enabling a controller.")
    }
    try importRegistry(
      try NFS2015Controller.registry(devices: devices), named: "controller", prefix: install.prefix,
      runtime: runtime)
    try runtime.stop(install.prefix)
  }

  /// Runs the EA app installer the player chose, inside this app's own Windows folder.
  ///
  /// The installer is the player's own download from ea.com; nothing here fetches, verifies or
  /// alters it. Wine is stopped when it exits, so an EA app it started is not left running. The
  /// bundled .NET runtime is installed first, because without it the installer's MSI fails.
  private func installClient(
    _ request: URL, plan: StoreClientPlan, runtime: WineRuntime, lease: GameLease
  ) throws {
    let installer = try ClientInstaller.validate(request)
    try requireRosetta(try runtime.environment(prefix: paths.prefix))
    // EA's installer runs a managed custom action, which needs a .NET runtime in the prefix; the
    // environment is read again afterwards because it then enables that runtime.
    _ = try runtime.installManagedRuntime(into: paths.prefix)
    let environment = try runtime.environment(prefix: paths.prefix)
    let status: Int32
    do {
      status = try ProcessCommand(
        executable: paths.wine, arguments: [installer.path], directory: paths.support,
        environment: environment
      ).run(output: output, onStart: lease.record)
    } catch {
      do {
        try lease.clear()
        try runtime.stop(paths.prefix)
      } catch { print("EA app installer cleanup failed: \(error)") }
      throw error
    }
    try lease.clear()
    try runtime.stop(paths.prefix)
    guard try NFS2015Locator.client(prefix: paths.prefix, plan: plan) != nil else {
      throw LauncherError.operation(
        """
        The EA app was not installed (the installer ended with status \(status)). Open the log, \
        then try Install EA App again.
        """)
    }
    print("The \(plan.name) is installed.")
  }

  /// Starts the EA app by itself so the player can sign in, and waits until it is quit.
  ///
  /// An EA app already running from an earlier Play is the one the player signs in to; it is
  /// waited for, not started twice.
  private func openClient(
    plan: StoreClientPlan, runtime: WineRuntime, lease: GameLease, adopted: Int32?
  ) throws {
    guard let client = try NFS2015Locator.client(prefix: paths.prefix, plan: plan) else {
      throw LauncherError.operation(
        "The \(plan.name) is not installed yet. Press Install EA App first.")
    }
    if let adopted {
      print("The \(plan.name) is already running; sign in to it, then quit it.")
      while lease.activeProcess() == adopted { Thread.sleep(forTimeInterval: 1) }
      try lease.clear()
      try runtime.stop(paths.prefix)
      return
    }
    let environment = try runtime.environment(prefix: paths.prefix)
    try requireRosetta(environment)
    let driveC = paths.prefix.appendingPathComponent("drive_c")
    let directory = try GuestPath.resolve(plan.gameRoot, in: driveC) ?? paths.support
    let command = GuestCommand(
      windowsPath: try NFS2015Install.windowsPath(of: client.executable, in: paths.prefix),
      arguments: plan.clientArguments)
    let process = try ProcessCommand(
      executable: paths.wine, arguments: command.wineArguments, directory: directory,
      environment: environment
    ).start(output: output)
    do {
      try lease.record(process: process.processIdentifier)
      process.waitUntilExit()
    } catch {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      do {
        try lease.clear()
        try runtime.stop(paths.prefix)
      } catch { print("EA app cleanup failed: \(error)") }
      throw error
    }
    try lease.clear()
    try runtime.stop(paths.prefix)
  }

  /// Starts the client, or reuses the one already running, waits until it reports that it is
  /// signed in and booted, then hands it the launch request.
  ///
  /// The session owns the client process for the whole play session: the client keeps running
  /// while the game it started runs, so quitting the client ends the session. A client that is
  /// alive is never ended here, not when the wait runs out and not when the request fails: it
  /// is left running for the player to sign in to and for the next Play to reuse. Only a client
  /// that has already exited is cleaned up.
  private func play(
    plan: NFS2015LaunchPlan, environment: [String: String], runtime: WineRuntime, prefix: URL,
    lease: GameLease, adopted: Int32?
  ) throws -> PlayOutcome {
    let started = Date()
    var owned: Process?
    let pid: Int32
    if let adopted {
      pid = adopted
      print("Reusing the EA app that is already running.")
    } else {
      let client = try ProcessCommand(
        executable: paths.wine, arguments: plan.client.wineArguments,
        directory: plan.workingDirectory, environment: environment
      ).start(output: output)
      owned = client
      pid = client.processIdentifier
    }
    let isRunning: () -> Bool = { owned?.isRunning ?? (lease.activeProcess() == pid) }
    do {
      if adopted == nil { try lease.record(process: pid) }
      let result = try ClientWait(deadline: plan.readinessSeconds).run(
        phase: { plan.readiness.phase(since: adopted == nil ? started : nil) },
        isRunning: isRunning, wait: { seconds in Thread.sleep(forTimeInterval: Double(seconds)) })
      guard case .ready(let waited) = result else {
        return .notReady(result.notice ?? "The EA app is running; press Play again.")
      }
      print("The EA app was ready after \(waited) seconds.")
      let request = try ProcessCommand(
        executable: paths.wine, arguments: plan.request.wineArguments,
        directory: plan.workingDirectory, environment: environment
      ).run(output: output)
      guard request == 0 else {
        throw LauncherError.operation(
          """
          The EA app refused the launch request (\(request)). It is still running: make sure Need \
          for Speed is installed in it and your account is signed in, then press Play again.
          """)
      }
      if let owned {
        owned.waitUntilExit()
      } else {
        while isRunning() { Thread.sleep(forTimeInterval: 1) }
      }
    } catch {
      if !isRunning() {
        do {
          try lease.clear()
          try runtime.stop(prefix)
        } catch { print("Need for Speed session cleanup failed: \(error)") }
      }
      throw error
    }
    try lease.clear()
    try runtime.stop(prefix)
    return .finished(owned?.terminationStatus ?? 0)
  }

  private func snapshot(
    readiness: NFS2015Readiness, store: NFS2015SettingsStore, plan: StoreClientPlan, owned: Bool,
    outcome: NFS2015SettingsOutcome? = nil, notice: String? = nil, metalFX: NFS2015MetalFXState
  ) throws {
    let installed = readiness.install
    var version = installed?.clientVersion
    if version == nil, owned {
      version = try NFS2015Locator.client(prefix: paths.prefix, plan: plan)?.version
    }
    let options = try store.inspect()
    try NFS2015Snapshot(
      blocker: owned ? readiness.ownedMessage : readiness.message, clientVersion: version,
      installedAt: owned ? paths.prefix.path : installed?.prefix.path,
      hasOptionsFile: try store.optionsFile() != nil, settings: options.settings,
      optionsDigest: options.digest, optionsProblem: options.problem, backups: options.backups,
      outcome: outcome, ownsWindowsFolder: owned ? true : nil,
      setup: owned ? readiness.setup : nil, notice: notice, metalFX: metalFX
    ).write(to: paths.support.appendingPathComponent("launcher-state.json"))
  }
}
