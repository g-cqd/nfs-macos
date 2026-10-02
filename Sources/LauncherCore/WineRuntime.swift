import Foundation

/// Owns prefix initialization and shutdown for a bundle-relative Wine runtime.
package struct WineRuntime {
  private let paths: AppPaths
  private let output: FileHandle
  private let tuning: RuntimeTuning
  private let renderers: [RendererSelection]
  package init(
    paths: AppPaths, output: FileHandle, tuning: RuntimeTuning = RuntimeTuning(),
    renderers: [RendererSelection] = []
  ) {
    self.paths = paths
    self.output = output
    self.tuning = tuning
    self.renderers = renderers
  }

  package func environment(prefix: URL) throws(LauncherError) -> [String: String] {
    try LaunchEnvironment.make(
      paths: paths, prefix: prefix,
      home: paths.support.appendingPathComponent("RuntimeHome/Player"),
      temporary: paths.support.appendingPathComponent("Temporary"), tuning: tuning,
      renderers: renderers)
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
