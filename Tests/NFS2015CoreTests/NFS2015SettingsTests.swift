import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015CatalogTests {
  @Test
  func `identifiers and file keys are unique`() {
    let ids = NFS2015Catalog.settings.map(\.id)
    #expect(Set(ids).count == ids.count)
    let keys = NFS2015Catalog.keys
    #expect(Set(keys).count == keys.count)
  }

  /// The catalog may only reach the text file's three plain families. Nothing from the binary
  /// blob, and nothing about the field of view, cheats, telemetry or the multiplayer choice.
  @Test
  func `only offers keys from the three plain option families`() {
    let forbidden = [
      "fov", "fieldofview", "cheat", "trainer", "telemetry", "speedometer", "minimap", "camera",
      "playalone", "multiplayer", "fbchunks", "profileoptions", "keybinding",
    ]
    for key in NFS2015Catalog.keys {
      #expect(["GstRender.", "GstInput.", "GstAudio."].contains { key.hasPrefix($0) }, "\(key)")
      #expect(!forbidden.contains { key.lowercased().contains($0) }, "\(key)")
    }
  }

  @Test
  func `the catalog's keys all exist in a file of the game's shape`() throws {
    let document = try ProfileOptionsDocument(data: OptionsFixture.data())
    for key in NFS2015Catalog.keys { #expect(document.value(key) != nil, "\(key)") }
  }

  @Test
  func `each editable default is a value its own setting accepts`() {
    for setting in NFS2015Catalog.settings where setting.isEditable {
      #expect(setting.accepts(setting.defaultValue), "\(setting.id)")
      #expect(setting.fileValues(for: setting.defaultValue)?.count == setting.keys.count)
    }
  }

  @Test
  func `ranges are ordered and finite`() {
    for setting in NFS2015Catalog.settings {
      guard let range = setting.range else { continue }
      #expect(range.lowerBound < range.upperBound && range.lowerBound.isFinite)
      #expect(range.upperBound.isFinite && range.lowerBound >= 0, "\(setting.id)")
    }
  }

  @Test
  func `the experimental group holds exactly the keys whose meaning is unknown`() {
    let experimental = Set(NFS2015Catalog.settings(in: .experimental).flatMap(\.keys))
    #expect(
      experimental == [
        "GstRender.VSyncEnabled", "GstRender.PresentInterval", "GstRender.AntiAliasingPost",
        "GstRender.AmbientOcclusion", "GstRender.ScreenSafeAreaWidth",
        "GstRender.ScreenSafeAreaHeight",
      ])
    for group in NFS2015SettingGroup.allCases {
      #expect(!NFS2015Catalog.settings(in: group).isEmpty)
    }
  }

  @Test
  func `anti-aliasing and ambient occlusion are shown and never written`() throws {
    for id in ["render.antiAliasing", "render.ambientOcclusion"] {
      let setting = try #require(NFS2015Catalog.setting(id))
      #expect(!setting.isEditable)
      #expect(!setting.accepts("0") && !setting.accepts("2"))
      #expect(setting.fileValues(for: "2") == nil && setting.clamped("2") == nil)
      #expect(throws: LauncherError.self) { try NFS2015Settings.replacements(for: [id: "2"]) }
    }
  }

  @Test
  func `every setting says where its values come from and needs the game closed`() {
    for setting in NFS2015Catalog.settings {
      #expect(setting.needsGameClosed, "\(setting.id)")
      #expect(!setting.source.title.isEmpty)
    }
    #expect(NFS2015Catalog.setting("render.resolution")?.source == .verified)
    #expect(NFS2015Catalog.setting("input.sensitivitySteering")?.source == .reported)
  }

  @Test
  func `sensitivity is not clamped away from zero, which the game wrote`() throws {
    let setting = try #require(NFS2015Catalog.setting("input.sensitivitySteering"))
    #expect(setting.accepts("0") && setting.accepts("0.000000"))
    #expect(setting.clamped("0") == "0.000000")
    #expect(!setting.accepts("-0.5") && !setting.accepts("1000"))
  }

  @Test
  func `the maximum quality preset sets six levels and two effects, and no resolution`() throws {
    let preset = NFS2015Preset.maximumQuality
    #expect(preset.count == 8)
    for (id, value) in preset {
      let setting = try #require(NFS2015Catalog.setting(id))
      #expect(setting.accepts(value) && !setting.isExperimental)
    }
    let levels = ["texture", "mesh", "shadow", "effects", "terrain", "undergrowth"]
    for level in levels { #expect(preset["quality.\(level)"] == "3") }
    #expect(preset["render.motionBlur"] == "0" && preset["render.filmGrain"] == "0")
    #expect(preset["render.resolution"] == nil)
  }
}

struct NFS2015SettingsTests {
  @Test
  func `reads the values the game wrote`() throws {
    let settings = NFS2015Settings(
      document: try ProfileOptionsDocument(data: OptionsFixture.data()))
    #expect(settings.value("render.resolution") == "2560x1600")
    #expect(settings.value("render.fullscreen") == "1")
    #expect(settings.value("render.refreshRate") == "60.000000")
    #expect(settings.value("quality.shadow") == "1")
    #expect(settings.value("input.deadZoneSteering") == "0.100000")
    #expect(settings.value("input.vibration") == "2")
    #expect(settings.value("audio.music") == "0.750000")
    #expect(settings.value("render.safeAreaWidth") == "0.900000")
    #expect(settings.observed == ["render.antiAliasing": "2", "render.ambientOcclusion": "2"])
    try settings.validate()
  }

  @Test
  func `shows a value outside the offered domain without replacing it`() throws {
    let text = OptionsFixture.replacing("GstRender.TextureQuality", with: "7")
    let settings = NFS2015Settings(document: try ProfileOptionsDocument(text: text))
    #expect(!settings.isPresent("quality.texture"))
    #expect(settings.observed["quality.texture"] == "7")
    #expect(settings.value("quality.texture") == "3")
  }

  @Test
  func `survives a round trip through the helper's state file`() throws {
    let settings = NFS2015Settings(
      document: try ProfileOptionsDocument(data: OptionsFixture.data()))
    let decoded = try JSONDecoder().decode(
      NFS2015Settings.self, from: try JSONEncoder().encode(settings))
    #expect(decoded == settings)
    let older = try JSONDecoder().decode(
      NFS2015Settings.self, from: Data(#"{"values":{"render.vsync":"0"}}"#.utf8))
    #expect(older.observed.isEmpty && older.value("render.vsync") == "0")
  }

  @Test(arguments: ["", "4", "-1", "on", "1;2", "1 "])
  func `rejects a value outside the offered domain`(value: String) {
    var settings = NFS2015Settings()
    settings.values["quality.texture"] = value
    #expect(throws: LauncherError.self) { try settings.validate() }
  }

  @Test
  func `rejects an unknown setting identifier`() {
    var settings = NFS2015Settings()
    settings.values["render.raytracing"] = "1"
    #expect(throws: LauncherError.self) { try settings.validate() }
    #expect(throws: LauncherError.self) {
      try NFS2015Settings.replacements(for: ["render.raytracing": "1"])
    }
  }

  @Test
  func `turns chosen values into the lines the game uses`() throws {
    let replacements = try NFS2015Settings.replacements(for: [
      "render.resolution": "1920x1080", "render.brightness": "0.25", "quality.mesh": "3",
    ])
    #expect(
      replacements == [
        "GstRender.ResolutionWidth": "1920", "GstRender.ResolutionHeight": "1080",
        "GstRender.Brightness": "0.250000", "GstRender.MeshQuality": "3",
      ])
  }

  @Test(arguments: [
    ("render.brightness", "1.5"), ("quality.mesh", "4"), ("render.resolution", "9999x1"),
    ("render.refreshRate", "1000"), ("render.safeAreaWidth", "0.1"), ("audio.music", "-0.1"),
  ])
  func `refuses a value beyond its range instead of adjusting it`(id: String, value: String) {
    let error = #expect(throws: LauncherError.self) {
      try NFS2015Settings.replacements(for: [id: value])
    }
    #expect(error?.localizedDescription.contains("range") == true)
  }
}

struct NFS2015ClampingTests {
  @Test(arguments: [
    ("render.brightness", "2", "1.000000"), ("render.brightness", "-3", "0.000000"),
    ("render.brightness", "0.3", "0.300000"), ("render.refreshRate", "9999", "480.000000"),
    ("render.refreshRate", "1", "24.000000"), ("render.safeAreaWidth", "0", "0.300000"),
    ("input.deadZoneBrake", "0.9", "0.500000"), ("quality.texture", "3", "3"),
    ("render.resolution", "99999x1", "7680x480"),
    ("render.resolution", " 1920 X 1080 ", "1920x1080"),
    ("render.resolution", "100x100", "640x480"),
  ])
  func `holds a typed value inside its range`(id: String, typed: String, held: String) throws {
    let setting = try #require(NFS2015Catalog.setting(id))
    #expect(setting.clamped(typed) == held)
    #expect(setting.accepts(held))
  }

  @Test(arguments: [
    ("render.brightness", "nan"), ("render.brightness", "inf"), ("render.brightness", "abc"),
    ("render.brightness", ""), ("quality.texture", "9"), ("quality.texture", "1.0"),
    ("render.resolution", "1920"), ("render.resolution", "axb"), ("render.resolution", "1x2x3"),
  ])
  func `gives no value for something that is not a number or an offered choice`(
    id: String, typed: String
  ) throws {
    #expect(try #require(NFS2015Catalog.setting(id)).clamped(typed) == nil)
  }

  @Test
  func `shows numbers the way a person writes them`() throws {
    let rate = try #require(NFS2015Catalog.setting("render.refreshRate"))
    #expect(rate.displayText("60.000000") == "60" && rate.displayText("59.940000") == "59.94")
    #expect(rate.rangeDescription == "24 to 480")
    #expect(try #require(NFS2015Catalog.setting("render.resolution")).rangeDescription != nil)
    #expect(try #require(NFS2015Catalog.setting("render.fullscreen")).rangeDescription == nil)
    #expect(try #require(NFS2015Catalog.setting("audio.music")).prefersSlider)
    #expect(!rate.prefersSlider)
  }
}

struct NFS2015RequestTests {
  private let digest = String(repeating: "a1", count: 32)

  @Test
  func `accepts a save that names the file it was made for`() throws {
    try NFS2015SettingsRequest(
      action: .save, changes: ["render.vsync": "1"], expectedDigest: digest
    ).validate()
  }

  @Test(arguments: [
    "", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64),
  ])
  func `refuses a request that does not identify the file`(digest: String) {
    #expect(throws: LauncherError.self) {
      try NFS2015SettingsRequest(action: .save, changes: [:], expectedDigest: digest).validate()
    }
  }

  @Test
  func `refuses a restore that also carries changes, and a save of an unknown setting`() {
    #expect(throws: LauncherError.self) {
      try NFS2015SettingsRequest(
        action: .restoreOriginal, changes: ["render.vsync": "1"], expectedDigest: digest
      ).validate()
    }
    #expect(throws: LauncherError.self) {
      try NFS2015SettingsRequest(
        action: .save, changes: ["cheat.money": "1"], expectedDigest: digest
      ).validate()
    }
  }
}

struct NFS2015GameActivityTests {
  @Test(arguments: [
    #"C:\Program Files\EA Games\Need for Speed\NFS16.exe"#,
    #""C:\Program Files\EA Games\Need for Speed\NFS16.exe" -Origin_Auth"#,
    "/usr/bin/wine c:\\games\\nfs16.exe --flag", "wine NFS16.EXE",
  ])
  func `sees the game in a process list`(line: String) {
    #expect(NFS2015GameActivity.containsGame(inProcessList: "/sbin/launchd\n\(line)\n/bin/zsh"))
  }

  @Test(arguments: [
    "", "/sbin/launchd\n/bin/zsh", #"C:\Program Files\EA Games\Need for Speed\NFS16.exe.bak"#,
    #"C:\EA Desktop\EADesktop.exe --in-process-gpu"#, "wine NFS16_trial.exe",
  ])
  func `does not mistake other programs for the game`(list: String) {
    #expect(!NFS2015GameActivity.containsGame(inProcessList: list))
  }
}
