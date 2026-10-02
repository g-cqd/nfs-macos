import Foundation
import Testing

@testable import FarCry2Core
@testable import LauncherCore

struct FarCry2OptionsTests {
  private func real() throws -> GamerProfileDocument {
    try GamerProfileDocument(Data(FarCry2Fixture.realProfileXML.utf8))
  }

  @Test
  func `every profile option exists in the profile the game wrote and its default is valid`() throws
  {
    let document = try real()
    for setting in FarCry2Catalog.settings {
      #expect(setting.accepts(setting.defaultValue), "\(setting.id) default must be valid")
      guard case .profile(let targets) = setting.storage else { continue }
      for target in targets where !target.path.contains("CustomQuality") || target.path.count == 2 {
        #expect(
          !document.values(target).isEmpty,
          "\(setting.id) targets \(target.path.joined(separator: "/")) @\(target.attribute)")
      }
    }
  }

  @Test
  func `reading the game's own profile imports every value the catalog accepts`() throws {
    let settings = try FarCry2Settings(profile: real(), renderer: nil)
    #expect(settings.value("resolution") == "1280x800")
    #expect(settings.value("quality") == "optimal")
    #expect(settings.value("fire") == "Low" && settings.value("realTree") == "Low")
    #expect(settings.value("shading") == "medium")
    #expect(settings.value("sensitivity") == "0.9" && settings.value("volume") == "100")
    #expect(settings.value("difficulty") == "1" && settings.value("music") == "1")
  }

  @Test
  func `the profile after the game's own Video options reads back as chosen`() throws {
    let used = try GamerProfileDocument(Data(FarCry2Fixture.usedProfileXML.utf8))
    let settings = try FarCry2Settings(profile: used, renderer: nil)
    #expect(settings.value("resolution") == "1680x1050" && settings.value("refreshRate") == "60")
    #expect(settings.value("antialiasing") == "4" && settings.value("alphaToCoverage") == "1")
    #expect(settings.value("quality") == "high")
    #expect(
      settings.value("fire") == "High" && settings.value("realTree") == "High"
        && settings.value("physic") == "High")
  }

  @Test
  func `detail levels reach every custom quality entry and nothing else changes`() throws {
    var document = try real()
    var settings = FarCry2Settings()
    settings.values["shadow"] = "veryhigh"
    settings.values["quality"] = "custom"
    let report = try settings.applying(to: &document)
    #expect(report.applied.sorted() == ["quality", "shadow"])
    #expect(
      document.values(.init(["CustomQuality", "quality"], "ShadowQuality"))
        == ["veryhigh", "veryhigh"])
    #expect(document.values(.init(["RenderProfile"], "Quality")) == ["custom"])
    #expect(
      document.values(.init(["CustomQuality", "quality"], "TextureQuality")) == ["medium", "high"])
  }

  @Test
  func `gamma writes the ramp and its three channels together`() throws {
    var document = try real()
    var settings = FarCry2Settings()
    settings.values["gamma"] = "1.2"
    _ = try settings.applying(to: &document)
    for attribute in ["GammaRamp", "GammaRampR", "GammaRampG", "GammaRampB"] {
      #expect(document.values(.init(["RenderProfile"], attribute)) == ["1.2"])
    }
  }

  @Test
  func `nested game profile sections are addressed by their own path`() throws {
    var document = try real()
    var settings = FarCry2Settings()
    settings.values["fire"] = "VeryHigh"
    settings.values["physic"] = "VeryHigh"
    settings.values["music"] = "0"
    _ = try settings.applying(to: &document)
    #expect(
      document.values(.init(["GameProfile", "FireConfig"], "QualitySetting")) == ["VeryHigh"])
    #expect(
      document.values(.init(["EngineProfile", "PhysicConfig"], "QualitySetting")) == ["VeryHigh"])
    #expect(document.values(.init(["SoundProfile"], "MusicEnabled")) == ["0"])
  }

  @Test(arguments: [
    ("quality", "ultra"), ("shadow", "ultrahigh"), ("fire", "Ultra"), ("volume", "101"),
    ("volume", "1.5"), ("difficulty", "9"), ("brightness", "9"), ("brightness", "abc"),
    ("sensitivity", "0"), ("cheat.hour", "24"), ("cheat.diamonds", "-1"),
    ("memory.vramBudgetMB", "99999"), ("retina", "Y"), ("cursor.scale", "0"),
    ("borderless", "yes"), ("color.space", "srgb"),
  ])
  func `rejects values outside each option's domain`(id: String, value: String) {
    var settings = FarCry2Settings()
    settings.values[id] = value
    #expect(throws: LauncherError.self) { try settings.validate() }
  }

  @Test
  func `numbers are written in one canonical form`() {
    #expect(FarCry2Setting.canonical(-1) == "-1")
    #expect(FarCry2Setting.canonical(1.0) == "1")
    #expect(FarCry2Setting.canonical(0.95) == "0.95")
    #expect(FarCry2Setting.canonical(100) == "100")
    #expect(FarCry2Setting.canonical(-0.001) == "0")
    for setting in FarCry2Catalog.settings {
      if case .decimal = setting.kind {
        #expect(setting.accepts(FarCry2Setting.canonical(Double(setting.defaultValue) ?? 0)))
      }
    }
  }

  // MARK: Wine registry

  @Test
  func `registry options are read from the Mac driver section`() throws {
    let settings = try FarCry2Settings(
      profile: nil, renderer: nil,
      registry: FarCry2Fixture.registryText.replacingOccurrences(
        of: "\"RetinaMode\"=\"Y\"",
        with: "\"RetinaMode\"=\"N\"\n\"LeftCommandIsCtrl\"=\"y\"\n\"RightOptionIsAlt\"=\"n\""))
    #expect(settings.value("retina") == "0")
    #expect(settings.value("leftCommandCtrl") == "1")
    #expect(settings.value("rightOptionAlt") == "0")
    #expect(settings.values["rightCommandCtrl"] == nil)
  }

  @Test
  func `registry edits touch only the Mac driver keys and keep the rest`() throws {
    var settings = FarCry2Settings()
    settings.values["retina"] = "0"
    settings.values["leftCommandCtrl"] = "1"
    settings.values["rightOptionAlt"] = "1"
    let text = try #require(try settings.registryConfig(original: FarCry2Fixture.registryText))
    #expect(text.contains("\"RetinaMode\"=\"N\""))
    #expect(text.contains("\"LeftCommandIsCtrl\"=\"Y\""))
    #expect(text.contains("\"RightOptionIsAlt\"=\"Y\""))
    #expect(
      text.contains("\"RightCommandIsCtrl\"=\"N\"") && text.contains("\"LeftOptionIsAlt\"=\"N\""))
    #expect(text.contains("\"Version\"=\"win10\""), "other keys are kept")
    #expect(text.components(separatedBy: "[Software\\\\Wine\\\\Mac Driver]").count == 2)
    let again = try FarCry2Settings(profile: nil, renderer: nil, registry: text)
    #expect(again.value("leftCommandCtrl") == "1" && again.value("retina") == "0")
  }

  @Test
  func `a file that is not a Wine registry is left alone`() throws {
    #expect(try FarCry2Settings().registryConfig(original: "garbage") == nil)
  }

  // MARK: Launcher options and launch plan

  @Test
  func `launcher options persist and reload through their own file`() throws {
    var settings = FarCry2Settings()
    settings.values["hud"] = "1"
    settings.values["borderless"] = "1"
    settings.values["cheat.godMode"] = "1"
    settings.values["retina"] = "1"
    let data = try settings.launcherData()
    let loaded = try FarCry2Settings(profile: nil, renderer: nil, launcher: data)
    #expect(loaded.value("hud") == "1" && loaded.value("borderless") == "1")
    #expect(loaded.value("cheat.godMode") == "1")
    #expect(loaded.values["retina"] == nil, "only launcher options are stored in this file")
  }

  @Test
  func `unreadable or hostile launcher files are refused or ignored`() throws {
    #expect(throws: LauncherError.self) {
      try FarCry2Settings(profile: nil, renderer: nil, launcher: Data("not json".utf8))
    }
    let hostile = Data(#"{"hud":"1; rm","borderless":"1","unknown":"1","retina":"1"}"#.utf8)
    let loaded = try FarCry2Settings(profile: nil, renderer: nil, launcher: hostile)
    #expect(loaded.values == ["borderless": "1"])
  }

  @Test
  func `defaults produce a plan with no switches and no console lines`() {
    let plan = FarCry2Settings().launchPlan()
    #expect(plan.arguments.isEmpty && plan.console.isEmpty)
    #expect(plan.environment == ["MTL_HUD_ENABLED": "0"])
  }

  @Test
  func `chosen options become environment switches and console lines`() {
    var settings = FarCry2Settings()
    settings.values["hud"] = "1"
    settings.values["borderless"] = "1"
    settings.values["noSound"] = "1"
    settings.values["cheat.godMode"] = "1"
    settings.values["cheat.diamonds"] = "250"
    settings.values["cheat.hour"] = "6"
    settings.values["cheat.timeScale"] = "-1"
    settings.values["cheat.windForce"] = "-1"
    let plan = settings.launchPlan()
    #expect(plan.environment["MTL_HUD_ENABLED"] == "1")
    #expect(plan.arguments == ["-borderless", "-nosound"])
    #expect(
      plan.console == [
        "SetSetting cheat_GodMode 1", "Cheat_AddDiamonds 250", "SetSetting env_Hour 6",
      ])
  }

  @Test
  func `a numeric option left at its sentinel never reaches the console`() {
    var settings = FarCry2Settings()
    settings.values["cheat.timeScale"] = "-1.00"
    settings.values["cheat.diamonds"] = "0"
    #expect(FarCry2Settings().launchPlan().console.isEmpty)
    #expect(settings.launchPlan().console.isEmpty)
  }

  @Test
  func `the console script ends with a newline and sits in the player documents`() {
    #expect(FarCry2Console.script(["a", "b"]) == "a\nb\n")
    #expect(
      FarCry2Console.windowsPath(profile: "crossover")
        == "C:\\users\\crossover\\Documents\\My Games\\Far Cry 2\\starter-console.txt")
  }

  // MARK: Catalog

  @Test
  func `every option belongs to a displayed group and ids are unique`() {
    let groups = Set(
      FarCry2Catalog.graphicsGroups + FarCry2Catalog.macGroups + FarCry2Catalog.gameGroups
        + FarCry2Catalog.cheatGroups)
    for setting in FarCry2Catalog.settings {
      #expect(groups.contains(setting.group), "\(setting.id) is in \(setting.group)")
    }
    let ids = FarCry2Catalog.settings.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(FarCry2Catalog.settings.count > 80)
  }

  @Test
  func `console lines come only from launcher options and carry their value`() {
    for setting in FarCry2Catalog.settings {
      if case .console(let template) = setting.launch {
        #expect(setting.isLauncher && template.contains("{value}"), "\(setting.id)")
      }
      if setting.launch != .none { #expect(setting.isLauncher, "\(setting.id)") }
    }
  }

  @Test
  func `maximum quality also picks the top preset and Retina output`() throws {
    var settings = FarCry2Settings()
    settings.maximumQuality(width: 3024, height: 1964)
    try settings.validate()
    #expect(settings.value("quality") == "ultrahigh" && settings.value("retina") == "1")
  }

  // MARK: Store

  @Test
  func
    `the store applies the registry and launcher options in one transaction and reads them back`()
    throws
  {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    try fixture.user.install()
    try fixture.installGameFolder(renderer: "# keep\n")
    try fixture.write(FarCry2Fixture.realProfileXML, to: fixture.user.profileFile)
    let registry = fixture.paths.prefix.appendingPathComponent("user.reg")
    try fixture.write(FarCry2Fixture.registryText, to: registry)
    let store = FarCry2SettingsStore(paths: fixture.paths)
    var settings = try store.load().settings
    settings.values["retina"] = "0"
    settings.values["rightCommandCtrl"] = "1"
    settings.values["hud"] = "1"
    settings.values["shadow"] = "high"
    #expect(try store.apply(settings) == .ready)
    #expect(try fixture.read(registry).contains("\"RightCommandIsCtrl\"=\"Y\""))
    #expect(try fixture.read(store.optionsFile).contains("\"hud\":\"1\""))
    let again = try store.load().settings
    #expect(again.value("retina") == "0" && again.value("rightCommandCtrl") == "1")
    #expect(again.value("hud") == "1" && again.value("shadow") == "high")
  }

  @Test
  func `without a registry file the store skips it and still saves the launcher options`() throws {
    let fixture = try FarCry2Fixture()
    defer { fixture.remove() }
    try fixture.user.install()
    try fixture.installGameFolder()
    let store = FarCry2SettingsStore(paths: fixture.paths)
    var settings = FarCry2Settings()
    settings.values["borderless"] = "1"
    #expect(try store.apply(settings) == .missing)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.paths.prefix.appendingPathComponent("user.reg").path))
    #expect(try store.load().settings.value("borderless") == "1")
  }
}
