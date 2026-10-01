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
    readinessEvidence: ["AppData/Local/Electronic Arts/EA Desktop/Logs"], readinessChildren: 1,
    readinessSeconds: 120, gameRoot: "Program Files/EA Games/Need for Speed")

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

  /// The game's own options file, as the installed game writes it.
  @discardableResult
  func options(_ lines: [String]) throws -> URL {
    let url = driveC.appendingPathComponent(
      "users/crossover/" + NFS2015SettingsStore.optionsPath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    return url
  }

  static let writtenOptions = [
    "GstAudio.MusicVolume 1.000000",
    "GstInput.AutoReverseForManualGears 1",
    "GstInput.DeadZonePadBrake 0.000000",
    "GstInput.DeadZonePadSteering 0.000000",
    "GstInput.DeadZonePadThrottle 0.000000",
    "GstRender.Brightness 0.500000",
    "GstRender.EffectsQuality 3",
    "GstRender.FilmGrain 1",
    "GstRender.FullscreenEnabled 1",
    "GstRender.FullscreenRefreshRate 60.000000",
    "GstRender.MeshQuality 3",
    "GstRender.MotionBlurEnabled 1",
    "GstRender.ResolutionHeight 1600",
    "GstRender.ResolutionWidth 2560",
    "GstRender.ShadowQuality 3",
    "GstRender.TerrainQuality 1",
    "GstRender.TextureQuality 3",
    "GstRender.UndergrowthQuality 1",
    "GstRender.VSyncEnabled 0",
  ]
}
