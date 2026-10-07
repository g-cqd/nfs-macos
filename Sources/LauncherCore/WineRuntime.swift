import Foundation

/// Owns prefix initialization and shutdown for a bundle-relative Wine runtime.
package struct WineRuntime {
  private let paths: AppPaths
  private let output: FileHandle
  private let tuning: RuntimeTuning
  private let renderers: [RendererSelection]
  private let managedRuntime: ManagedRuntime?
  private let environments: [ExecutableEnvironment]
  private let debugChannels: String
  private let usesSidecar: Bool
  package init(
    paths: AppPaths, output: FileHandle, tuning: RuntimeTuning = RuntimeTuning(),
    renderers: [RendererSelection] = [], managedRuntime: ManagedRuntime? = nil,
    environments: [ExecutableEnvironment] = [],
    debugChannels: String = LaunchEnvironment.silentDebugChannels, usesSidecar: Bool = true
  ) {
    self.paths = paths
    self.output = output
    self.tuning = tuning
    self.renderers = renderers
    self.managedRuntime = managedRuntime
    self.environments = environments
    self.debugChannels = debugChannels
    self.usesSidecar = usesSidecar
  }

  /// The environment for a Wine process in this prefix. The managed runtime is enabled exactly
  /// when the app declares one and the prefix really holds it, so the answer follows the prefix.
  package func environment(prefix: URL) throws(LauncherError) -> [String: String] {
    try LaunchEnvironment.make(
      paths: paths, prefix: prefix,
      home: paths.support.appendingPathComponent("RuntimeHome/Player"),
      temporary: paths.support.appendingPathComponent("Temporary"), tuning: tuning,
      renderers: renderers, managedCode: managedRuntime?.isInstalled(in: prefix) ?? false,
      environments: environments, debugChannels: debugChannels, usesSidecar: usesSidecar)
  }

  /// Puts the pinned managed runtime into the prefix unless it is already there.
  ///
  /// Runs `msiexec` through the bundled Wine, with the installer verified against its pin first,
  /// and stops this prefix's Wine server afterwards so the next process sees the new libraries.
  /// - Returns: Whether it installed anything; false when none is declared or it is present.
  /// - Throws: A failure when the installer is altered, Wine fails, or the libraries are absent.
  package func installManagedRuntime(into prefix: URL) throws -> Bool {
    guard let managedRuntime, !managedRuntime.isInstalled(in: prefix) else { return false }
    let installer = try managedRuntime.installer(in: paths.resources)
    print("Installing the Wine Mono \(managedRuntime.version) runtime the EA installer needs.")
    // The host path is shown to Wine on its Z: drive, with backslashes as Windows Installer wants.
    let windowsPath = "Z:" + installer.path.replacingOccurrences(of: "/", with: "\\")
    let status = try ProcessCommand(
      executable: paths.wine, arguments: ["msiexec", "/i", windowsPath, "/qn"],
      directory: paths.support, environment: try environment(prefix: prefix)
    ).run(output: output)
    do { try stop(prefix) } catch { print("Wine setup cleanup failed: \(error)") }
    guard status == 0, managedRuntime.isInstalled(in: prefix) else {
      throw LauncherError.operation(
        "Wine Mono could not be installed (status \(status)). Open the log, then try again.")
    }
    return true
  }

  /// Initializes an unpublished prefix and always stops its server before returning.
  package func initialize(_ prefix: URL) throws {
    try performInitialization(
      prefix,
      steps: [
        ["wineboot", "--init"],
        ["reg", "import", paths.resources.appendingPathComponent("Defaults/settings.reg").path],
      ])
  }

  /// Initializes an unpublished prefix with Wine's own defaults only.
  ///
  /// For a recipe that declares its registry values itself, so the caller records exactly those
  /// and the bundle carries no `Defaults/settings.reg`. The server is stopped before returning.
  package func initializeBare(_ prefix: URL) throws {
    try performInitialization(prefix, steps: [["wineboot", "--init"]])
  }

  private func performInitialization(_ prefix: URL, steps: [[String]]) throws {
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
    do {
      for arguments in steps {
        guard
          try ProcessCommand(
            executable: paths.wine, arguments: arguments, directory: prefix,
            environment: try environment(prefix: prefix)
          ).run(output: output) == 0
        else {
          throw LauncherError.operation(
            "Wine could not initialize the player folder or import its settings.")
        }
      }
      try stop(prefix)
    } catch {
      do { try stop(prefix) } catch { print("Wine setup cleanup failed: \(error)") }
      throw error
    }
  }

  /// Stops only this bundle's Wine server for the specified private prefix.
  package func stop(_ prefix: URL) throws {
    try WineShutdown.stop { argument in
      try ProcessCommand(
        executable: paths.wineServer, arguments: [argument], directory: prefix,
        environment: try environment(prefix: prefix)
      ).run(output: output)
    }
  }
}
