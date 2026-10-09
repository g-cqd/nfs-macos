import AppKit
import Foundation
import LauncherCore
import Observation
import SharedLauncher

/// The helper's status line, decoded from `BF3Session --status`.
struct BF3Status: Decodable, Equatable {
  var prepared = false
  var server = false
  var service = false
  var running: [String] = []
  var sidecar = true
  var browser: String?
  var profile = false
  var client = "notRunning"
}

/// Runs the session helper off the main actor and keeps the starter's state.
@MainActor @Observable
final class BF3Model {
  private(set) var status = BF3Status()
  private(set) var message = "Checking this app's Windows folder."
  private(set) var busy = false
  let rosetta = RosettaSetup()
  /// Whether the store client was seen running since the last start, so its exit can stop the
  /// prefix: the anti-cheat service keeps a core busy after the game and the client are closed.
  private var clientSeen = false
  private var quietPolls = 0

  /// The environment variable that points the starter at another player folder, for testing.
  nonisolated static let supportFolderVariable = "BF3_SUPPORT_FOLDER"

  nonisolated static func supportFolder(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let override = environment[supportFolderVariable], override.hasPrefix("/"),
      !override.split(separator: "/").contains("..")
    {
      return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
    return home.appendingPathComponent("Library/Application Support/BF3Mac")
  }

  let bundle = Bundle.main.bundleURL
  let support = BF3Model.supportFolder()
  var helper: URL { bundle.appendingPathComponent("Contents/Helpers/BF3Session") }
  var logs: URL { support.appendingPathComponent("Logs") }

  /// Runs one helper action and returns its exit status and output.
  nonisolated static func runHelper(
    _ helper: URL, bundle: URL, support: URL, arguments: [String]
  ) async -> (Int32, String) {
    await Task.detached {
      let process = Process()
      process.executableURL = helper
      process.arguments = [bundle.path, "--support", support.path] + arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch { return (1, error.localizedDescription) }
      HelperProcesses.shared.insert(process)
      defer { HelperProcesses.shared.remove(process) }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
  }

  @discardableResult
  func perform(_ arguments: [String], busyText: String) async -> Bool {
    guard !busy else { return false }
    busy = true
    message = busyText
    let (status, output) = await Self.runHelper(
      helper, bundle: bundle, support: support, arguments: arguments)
    let lines = output.split(separator: "\n").map(String.init)
    message = lines.last ?? (status == 0 ? "Done." : "The operation failed (\(status)).")
    appendLog(arguments: arguments, output: output)
    busy = false
    await refresh()
    return status == 0
  }

  func refresh() async {
    let (_, output) = await Self.runHelper(
      helper, bundle: bundle, support: support, arguments: ["--status"])
    if let line = output.split(separator: "\n").last,
      let decoded = try? JSONDecoder().decode(BF3Status.self, from: Data(line.utf8))
    {
      status = decoded
    }
  }

  func start() async {
    await rosetta.refresh()
    await refresh()
    if !status.prepared {
      await perform(
        ["--prepare"],
        busyText:
          "Preparing the Windows folder. The first start copies about 24 GB and verifies it; this takes a few minutes."
      )
    } else {
      message = "Ready. Open the EA app, sign in, then open Battlelog and press Play there."
    }
  }

  func openClient() async {
    clientSeen = true
    quietPolls = 0
    await perform(
      ["--start-client"], busyText: "Starting the EA app and waiting for its local service.")
  }

  func openStore(page: String) async {
    clientSeen = true
    quietPolls = 0
    await perform(
      ["--open-store", page],
      busyText: status.client == "ready"
        ? "Opening Battlelog."
        : "Starting the EA app first; Battlelog opens once it is signed in and lists the game.")
  }

  func applyPreset(_ name: String) async {
    await perform(["--preset", name], busyText: "Applying the settings preset.")
  }

  func setSidecar(_ on: Bool) async {
    await perform(["--sidecar", on ? "on" : "off"], busyText: "Saving the x87 sidecar choice.")
  }

  /// - Returns: Whether the helper stopped the prefix; on failure the supervisor tries again.
  @discardableResult
  func stop() async -> Bool {
    let stopped = await perform(["--stop"], busyText: "Stopping the Windows side of this app.")
    if stopped { clientSeen = false }
    return stopped
  }

  /// Polls the status; when the EA app and the game have both been gone for two polls after
  /// the EA app ran, stops the prefix so its background services do not keep running.
  func supervise() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(5))
      guard !busy else { continue }
      await refresh()
      let active = status.running.contains { ["EADesktop.exe", "bf3.exe"].contains($0) }
      if active {
        clientSeen = true
        quietPolls = 0
      } else if clientSeen, status.server {
        quietPolls += 1
        if quietPolls >= 2, !busy, await stop() {
          message = "The EA app was closed, so the Windows side was stopped."
        }
      }
    }
  }

  func openLogs() {
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    NSWorkspace.shared.open(logs)
  }

  private func appendLog(arguments: [String], output: String) {
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let url = logs.appendingPathComponent("session.log")
    let text = "== \(Date()) \(arguments.joined(separator: " "))\n\(output)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(text.utf8))
      try? handle.close()
    } else {
      try? Data(text.utf8).write(to: url)
    }
  }

  /// Stops the prefix synchronously when the starter quits, so nothing is left running.
  ///
  /// A helper still running (a start that waits for the EA app holds the session lock) is ended
  /// first, and a stop that finds the lock taken (status 73) is tried again for a few seconds.
  nonisolated static func stopOnQuit(helper: URL, bundle: URL, support: URL) {
    HelperProcesses.shared.terminateAll()
    for _ in 0..<10 {
      let process = Process()
      process.executableURL = helper
      process.arguments = [bundle.path, "--support", support.path, "--stop"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return }
      process.waitUntilExit()
      guard process.terminationStatus == 73 else { return }
      Thread.sleep(forTimeInterval: 1)
    }
  }
}

/// The helper processes the starter is running, so quitting can end them before it stops.
final class HelperProcesses: @unchecked Sendable {
  static let shared = HelperProcesses()
  private let lock = NSLock()
  private var running: [ObjectIdentifier: Process] = [:]

  func insert(_ process: Process) { lock.withLock { running[ObjectIdentifier(process)] = process } }
  func remove(_ process: Process) { lock.withLock { running[ObjectIdentifier(process)] = nil } }
  func terminateAll() {
    let all = lock.withLock { Array(running.values) }
    for process in all where process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}
