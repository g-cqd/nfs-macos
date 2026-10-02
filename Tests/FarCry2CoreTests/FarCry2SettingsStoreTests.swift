import Foundation
import Testing

@testable import FarCry2Core
@testable import LauncherCore

struct FarCry2SettingsStoreTests {
  private func prepared(profile: String? = FarCry2Fixture.profileXML, renderer: String? = nil)
    throws -> (FarCry2Fixture, FarCry2SettingsStore)
  {
    let fixture = try FarCry2Fixture()
    try fixture.user.install()
    try fixture.installGameFolder(renderer: renderer)
    if let profile { try fixture.write(profile, to: fixture.user.profileFile) }
    return (fixture, FarCry2SettingsStore(paths: fixture.paths))
  }

  @Test
  func `loading reports a missing profile instead of inventing one`() throws {
    let (fixture, store) = try prepared(profile: nil, renderer: "render.scale = 0.5\n")
    defer { fixture.remove() }
    let loaded = try store.load()
    #expect(loaded.state == .missing)
    #expect(loaded.settings.value("render.scale") == "0.5")
    #expect(!FileManager.default.fileExists(atPath: fixture.user.profileFile.path))
  }

  @Test
  func `loading reads the game's own profile`() throws {
    let (fixture, store) = try prepared()
    defer { fixture.remove() }
    let loaded = try store.load()
    #expect(loaded.state == .ready)
    #expect(loaded.settings.value("resolution") == "1440x900")
  }

  @Test(arguments: ["not xml at all", "<GamerProfile><Audio/></GamerProfile>", "<!DOCTYPE a><a/>"])
  func `an unrecognised profile is never modified but the renderer file still is`(profile: String)
    throws
  {
    let (fixture, store) = try prepared(profile: profile, renderer: "# keep\n")
    defer { fixture.remove() }
    #expect(try store.load().state == .unrecognized)
    var settings = FarCry2Settings()
    settings.values["render.scale"] = "0.75"
    #expect(try store.apply(settings) == .unrecognized)
    #expect(try fixture.read(fixture.user.profileFile) == profile)
    let renderer = try fixture.read(
      fixture.paths.currentGame.appendingPathComponent("bin/mtld3d.conf"))
    #expect(renderer.contains("# keep") && renderer.contains("render.scale = 0.75"))
  }

  @Test
  func `applying edits both files and keeps the game's original profile once`() throws {
    let (fixture, store) = try prepared(renderer: "# keep\n")
    defer { fixture.remove() }
    var settings = try store.load().settings
    settings.maximumQuality(width: 3024, height: 1964)
    #expect(try store.apply(settings) == .ready)
    let edited = try fixture.read(fixture.user.profileFile)
    #expect(edited.contains("Platform=\"d3d9\"") && edited.contains("ResolutionX=\"3024\""))
    #expect(
      edited.contains(
        "<!-- <RenderProfile Platform=\"d3d10\"> inside a comment must be ignored -->"))
    let backups = FarCry2Backups(paths: fixture.paths)
    #expect(try fixture.read(backups.originalProfile) == FarCry2Fixture.profileXML)
    settings.values["vsync"] = "1"
    try store.apply(settings)
    #expect(
      try fixture.read(backups.originalProfile) == FarCry2Fixture.profileXML,
      "the first backup is never overwritten")
    let again = try store.load()
    #expect(again.settings.value("resolution") == "3024x1964")
    #expect(again.settings.value("antialiasing") == "4")
  }

  @Test
  func `without a profile only the renderer file is written`() throws {
    let (fixture, store) = try prepared(profile: nil)
    defer { fixture.remove() }
    var settings = FarCry2Settings()
    settings.maximumQuality(width: 1920, height: 1080)
    #expect(try store.apply(settings) == .missing)
    #expect(!FileManager.default.fileExists(atPath: fixture.user.profileFile.path))
    let renderer = try fixture.read(
      fixture.paths.currentGame.appendingPathComponent("bin/mtld3d.conf"))
    #expect(renderer.contains("shader.asyncCompile = false"))
  }

  @Test
  func `invalid settings change nothing`() throws {
    let (fixture, store) = try prepared(renderer: "# keep\n")
    defer { fixture.remove() }
    var settings = FarCry2Settings()
    settings.values["antialiasing"] = "99"
    #expect(throws: LauncherError.self) { try store.apply(settings) }
    #expect(try fixture.read(fixture.user.profileFile) == FarCry2Fixture.profileXML)
    #expect(
      try fixture.read(fixture.paths.currentGame.appendingPathComponent("bin/mtld3d.conf"))
        == "# keep\n")
  }
}
