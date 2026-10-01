import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015SettingsTests {
  @Test
  func `reads the display settings the game wrote`() throws {
    let document = try ProfileOptionsDocument(
      text: SyntheticPrefix.writtenOptions.joined(separator: "\n") + "\n")
    let settings = NFS2015Settings(document: document)
    #expect(settings.value("render.resolution") == "2560x1600")
    #expect(settings.value("render.fullscreen") == "1")
    #expect(settings.value("render.vsync") == "0")
    #expect(settings.value("render.refreshRate") == "60.000000")
    #expect(settings.value("quality.texture") == "3")
    #expect(settings.value("quality.terrain") == "1")
    #expect(settings.value("input.deadZoneSteering") == "0.000000")
    try settings.validate()
  }

  @Test
  func `changes only the values asked for and keeps every other line`() throws {
    let original = SyntheticPrefix.writtenOptions.joined(separator: "\n") + "\n"
    var settings = NFS2015Settings(document: try ProfileOptionsDocument(text: original))
    settings.values["render.resolution"] = "1920x1080"
    settings.values["render.vsync"] = "1"
    let updated = try settings.applying(to: original)
    let lines = updated.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == original.split(separator: "\n", omittingEmptySubsequences: false).count)
    #expect(updated.contains("GstRender.ResolutionWidth 1920"))
    #expect(updated.contains("GstRender.ResolutionHeight 1080"))
    #expect(updated.contains("GstRender.VSyncEnabled 1"))
    #expect(updated.contains("GstAudio.MusicVolume 1.000000"))
    #expect(updated.hasSuffix("\n"))
  }

  @Test
  func `leaves an unmanaged audio or binding line untouched`() throws {
    let original = """
      GstAudio.MusicVolume 0.250000
      GstKeyBinding.racevehicle.ConceptYaw.5.button 38
      GstRender.VSyncEnabled 0

      """
    var settings = NFS2015Settings()
    settings.values["render.vsync"] = "1"
    let updated = try settings.applying(to: original)
    #expect(updated.contains("GstAudio.MusicVolume 0.250000"))
    #expect(updated.contains("GstKeyBinding.racevehicle.ConceptYaw.5.button 38"))
    #expect(updated.contains("GstRender.VSyncEnabled 1"))
  }

  @Test
  func `refuses to invent a key the game has not written`() throws {
    var settings = NFS2015Settings()
    settings.values["render.vsync"] = "1"
    let error = #expect(throws: LauncherError.self) {
      try settings.applying(to: "GstAudio.MusicVolume 1.000000\n")
    }
    #expect(error?.localizedDescription.contains("GstRender.VSyncEnabled") == true)
  }

  @Test(arguments: ["\u{0}", "é", "\r"])
  func `refuses an options file this editor cannot rewrite byte for byte`(byte: String) {
    #expect(throws: LauncherError.self) {
      try ProfileOptionsDocument(text: "GstRender.VSyncEnabled 0" + byte + "\n")
    }
  }

  @Test
  func `refuses a duplicated key rather than guessing which one wins`() throws {
    let document = try ProfileOptionsDocument(
      text: "GstRender.VSyncEnabled 0\nGstRender.VSyncEnabled 1\n")
    #expect(throws: LauncherError.self) {
      try document.applying(["GstRender.VSyncEnabled": "1"])
    }
  }

  @Test(arguments: ["", "4", "-1", "on", "1;2"])
  func `rejects a value outside the offered domain`(value: String) throws {
    var settings = NFS2015Settings()
    settings.values["quality.texture"] = value
    #expect(throws: LauncherError.self) { try settings.validate() }
  }

  @Test
  func `rejects an unknown setting identifier`() throws {
    var settings = NFS2015Settings()
    settings.values["render.raytracing"] = "1"
    #expect(throws: LauncherError.self) { try settings.validate() }
  }

  @Test
  func `writes a float with the precision the game uses`() throws {
    let setting = try #require(NFS2015Catalog.setting("render.brightness"))
    #expect(setting.fileValues(for: "0.25") == ["0.250000"])
    #expect(setting.value(from: ["0.500000"]) == "0.500000")
  }

  @Test
  func `loads from the game's own file and records the chosen values`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    try prefix.options(SyntheticPrefix.writtenOptions)
    let support = prefix.root.appendingPathComponent("Player")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let install = try #require(
      try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan).install)
    let store = NFS2015SettingsStore(support: support, install: install)
    #expect(try store.optionsFile() != nil)
    var settings = try store.load()
    #expect(settings.value("render.resolution") == "2560x1600")
    settings.values["render.resolution"] = "1920x1080"
    try store.apply(settings)
    #expect(try store.load().value("render.resolution") == "1920x1080")
    let written = try String(contentsOf: try #require(try store.optionsFile()), encoding: .utf8)
    #expect(written.contains("GstRender.ResolutionWidth 1920"))
    #expect(written.contains("GstAudio.MusicVolume 1.000000"))
  }

  @Test
  func `reports no options file before the game has written one`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let support = prefix.root.appendingPathComponent("Player")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let install = try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan)
      .install
    let store = NFS2015SettingsStore(support: support, install: install)
    #expect(try store.optionsFile() == nil)
    #expect(try store.load() == NFS2015Settings())
  }

  @Test
  func `restores the player's file when an interrupted edit is replayed`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let options = try prefix.options(SyntheticPrefix.writtenOptions)
    let support = prefix.root.appendingPathComponent("Player")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let original = try Data(contentsOf: options)
    let edit = PlayerFileEdit(support: support)
    try edit.replace(options, with: Data("GstRender.VSyncEnabled 1\n".utf8))
    #expect(try Data(contentsOf: options) != original)
    // Leave the journal behind the way an interrupted write would, then replay it.
    let journal = support.appendingPathComponent("player-file-edit.json")
    try JSONEncoder().encode(["path": options.path, "bytes": original.base64EncodedString()])
      .write(to: journal)
    try edit.recover()
    #expect(try Data(contentsOf: options) == original)
    #expect(!FileManager.default.fileExists(atPath: journal.path))
  }

  @Test
  func `refuses a journal that names a file outside the player's own folders`() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    try JSONEncoder().encode(["path": "relative/options", "bytes": "AA=="]).write(
      to: support.appendingPathComponent("player-file-edit.json"))
    #expect(throws: LauncherError.self) { try PlayerFileEdit(support: support).recover() }
  }
}
