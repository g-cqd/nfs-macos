import Foundation

/// Owns prefix initialization and shutdown for a bundle-relative Wine runtime.
package struct WineRuntime {
  private let paths: AppPaths
  private let output: FileHandle
  package init(paths: AppPaths, output: FileHandle) {
    self.paths = paths
    self.output = output
  }

  package func environment(prefix: URL) -> [String: String] {
    LaunchEnvironment.make(
      paths: paths, prefix: prefix,
      home: paths.support.appendingPathComponent("RuntimeHome/Player"),
      temporary: paths.support.appendingPathComponent("Temporary"))
  }

  /// Initializes an unpublished prefix and always stops its server before returning.
  package func initialize(_ prefix: URL) throws {
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
    do {
      for arguments in [
        ["wineboot", "--init"],
        ["reg", "import", paths.resources.appendingPathComponent("Defaults/settings.reg").path],
      ] {
        guard
          try ProcessCommand(
            executable: paths.wine, arguments: arguments, directory: prefix,
            environment: environment(prefix: prefix)
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
        environment: environment(prefix: prefix)
      ).run(output: output)
    }
  }
}
