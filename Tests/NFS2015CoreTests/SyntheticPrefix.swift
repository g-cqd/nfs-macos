import Foundation
import LauncherCore
import NFS2015Core

/// Builds a synthetic Windows prefix. No real game, client or account data is used anywhere.
struct SyntheticPrefix {
  let root: URL
  let driveC: URL

  static let plan = StoreClientPlan(
    name: "EA app", installRoot: "Program Files/Electronic Arts/EA Desktop",
    clientExecutable: "EA Desktop/EADesktop.exe", clientArguments: ["--in-process-gpu"],
    launcherExecutable: "EA Desktop/EALauncher.exe",
    launchURL: "origin2://game/launch/?offerIds={offer}", offerID: "1024486",
    signInEvidence: ["AppData/Local/Electronic Arts/EA Desktop"],
    readinessLog: "ProgramData/EA Desktop/Logs/EADesktop.log", startMarker: "[STARTUP]",
    readyEvents: ["login", "client.boot.ready"], readinessSeconds: 120,
    gameRoot: "Program Files/EA Games/Need for Speed")

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    driveC = root.appendingPathComponent("drive_c")
    try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  @discardableResult
  func file(_ relative: String, contents: String = "synthetic") throws -> URL {
    let url = driveC.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
  }

  @discardableResult
  func directory(_ relative: String) throws -> URL {
    let url = driveC.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A complete, recognisable installation with a signed-in client.
  static func complete(version: String = "13.796.0.6309") throws -> Self {
    let prefix = try Self()
    try prefix.file("Program Files/EA Games/Need for Speed/NFS16.exe")
    let client = "Program Files/Electronic Arts/EA Desktop/\(version)/EA Desktop"
    try prefix.file(client + "/EADesktop.exe")
    try prefix.file(client + "/EALauncher.exe")
    try prefix.directory("users/crossover/AppData/Local/Electronic Arts/EA Desktop/Logs")
    try prefix.directory("users/Public/Documents")
    return prefix
  }

  /// The game's own options file, with exactly these bytes.
  @discardableResult
  func options(_ bytes: Data) throws -> URL {
    let url = driveC.appendingPathComponent(
      "users/crossover/" + NFS2015SettingsStore.optionsPath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
    return url
  }
}
