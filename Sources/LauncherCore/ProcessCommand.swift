import Foundation

/// A shell-free child process invocation.
package struct ProcessCommand {
  package let executable: URL
  package let arguments: [String]
  package let directory: URL
  package let environment: [String: String]
  /// `.foundation` (the default) is every Rosetta-based launch and uses `Process` unchanged.
  package let profile: SpawnProfile

  package init(
    executable: URL, arguments: [String], directory: URL, environment: [String: String],
    profile: SpawnProfile = .foundation
  ) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.environment = environment
    self.profile = profile
  }

  /// Starts the child and returns it still running, for a program the session must outlive.
  ///
  /// A store client keeps its own window open while the game it started runs, so the session
  /// cannot wait for it before taking the next step. The caller owns the returned process and
  /// must wait for or terminate it.
  package func start(output: FileHandle) throws(LauncherError) -> Process {
    guard profile == .foundation else {
      throw .operation(
        "\(executable.lastPathComponent) cannot be started as a Process under the native arm64 route."
      )
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch {
      throw .operation(
        "Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
    }
    return process
  }

  /// Runs on a synchronous helper process, never on the launcher's UI or cooperative executor.
  /// - Returns: The child's actual exit status.
  package func run(output: FileHandle, onStart: (Int32) throws(LauncherError) -> Void = { _ in })
    throws(LauncherError) -> Int32
  {
    if case .arm64Wow64(let fourKilobytePages) = profile {
      return try SpawnCommand(
        executable: executable, arguments: arguments, directory: directory,
        environment: environment, requestsFourKilobytePages: fourKilobytePages
      ).run(output: output, onStart: onStart)
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch {
      throw .operation(
        "Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
    }
    do { try onStart(process.processIdentifier) } catch {
      // Keep session ownership until the child exits even if its record could not be written.
      process.waitUntilExit()
      throw error
    }
    process.waitUntilExit()
    return process.terminationStatus
  }
}
