import Foundation
import Testing

@testable import FarCry2Core
@testable import LauncherCore

struct FarCry2SettingsTests {
  private let render = ["RenderProfile"]
  private func profile() throws -> GamerProfileDocument {
    try GamerProfileDocument(Data(FarCry2Fixture.profileXML.utf8))
  }

  @Test
  func `reads the managed options a profile contains and defaults the rest`() throws {
    let settings = try FarCry2Settings(
      profile: profile(), renderer: "render.scale = 0.75\npresent.maxFps = 60\n")
    #expect(settings.value("resolution") == "1440x900")
    #expect(settings.value("fullscreen") == "0")
    #expect(settings.value("vsync") == "1")
    #expect(settings.value("antialiasing") == "0")
    #expect(settings.value("skipTopMip") == "1")
    #expect(settings.value("render.scale") == "0.75")
    #expect(settings.value("present.maxFps") == "60")
    #expect(
      settings.value("shader.asyncCompile") == "false", "absent renderer keys use their default")
    #expect(settings.values["shader.asyncCompile"] == nil)
  }

  @Test
  func `values outside the starter's choices are left in the file rather than imported`() throws {
    let text = FarCry2Fixture.profileXML.replacingOccurrences(
      of: "MultiSampleMode=\"0\"", with: "MultiSampleMode=\"3\"")
    let settings = try FarCry2Settings(
      profile: GamerProfileDocument(Data(text.utf8)), renderer: nil)
    #expect(settings.values["antialiasing"] == nil)
  }

  @Test
  func `applying forces Direct3D 9 and normalises a Direct3D 10 quality id`() throws {
    var document = try profile()
    var settings = FarCry2Settings()
    settings.values["fullscreen"] = "1"
    let report = try settings.applying(to: &document)
    #expect(document.values(.init(render, "Platform")) == ["d3d9"])
    #expect(document.values(.init(render, "Quality")) == ["custom"])
    #expect(document.values(.init(render, "Fullscreen")) == ["1"])
    #expect(report.platformSet && report.qualityNormalised)
    #expect(report.applied == ["fullscreen"])
  }

  @Test
  func `a Direct3D 9 profile keeps its quality id and unchosen options`() throws {
    let text = FarCry2Fixture.profileXML
      .replacingOccurrences(of: "Platform=\"d3d10a\"", with: "Platform=\"d3d9\"")
      .replacingOccurrences(of: "Quality=\"customd3d10\"", with: "Quality=\"optimal\"")
    var document = try GamerProfileDocument(Data(text.utf8))
    let report = try FarCry2Settings().applying(to: &document)
    #expect(document.data == Data(text.utf8), "nothing to change means no byte changes")
    #expect(report.applied.isEmpty && !report.qualityNormalised)
  }

  @Test
  func `resolution is written to the render profile and every quality entry`() throws {
    var document = try profile()
    var settings = FarCry2Settings()
    settings.values["resolution"] = "3024x1964"
    _ = try settings.applying(to: &document)
    #expect(document.values(.init(render, "ResolutionX")) == ["3024"])
    #expect(document.values(.init(render, "ResolutionY")) == ["1964"])
    #expect(
      document.values(.init(["CustomQuality", "quality"], "ResolutionX")) == ["3024", "3024"])
    #expect(
      document.values(.init(["CustomQuality", "quality"], "ResolutionY")) == ["1964", "1964"])
  }

  @Test
  func `options with no matching attribute are reported and not invented`() throws {
    let text = FarCry2Fixture.profileXML.replacingOccurrences(of: " ShowFPS=\"0\"", with: "")
    var document = try GamerProfileDocument(Data(text.utf8))
    var settings = FarCry2Settings()
    settings.values["showFPS"] = "1"
    let report = try settings.applying(to: &document)
    #expect(report.absent == ["showFPS"])
    #expect(!String(decoding: document.data, as: UTF8.self).contains("ShowFPS"))
  }

  @Test
  func `a profile without a render section is refused untouched`() throws {
    var document = try GamerProfileDocument(Data("<GamerProfile><Audio/></GamerProfile>".utf8))
    #expect(throws: LauncherError.self) { try FarCry2Settings().applying(to: &document) }
  }

  @Test(arguments: [
    ("resolution", "huge"), ("resolution", "100x100"), ("resolution", "0x0"),
    ("resolution", "1920x1080x2"),
    ("antialiasing", "3"), ("antialiasing", "8"), ("fullscreen", "2"), ("render.scale", "2"),
    ("render.scale", "1.0"), ("shader.asyncCompile", "yes"), ("present.maxFps", "-1"),
    ("antialiasing", "4\" Platform=\"d3d10"), ("fullscreen", "1;"),
  ])
  func `rejects unsupported values before anything is written`(id: String, value: String) {
    var settings = FarCry2Settings()
    settings.values[id] = value
    #expect(throws: LauncherError.self) { try settings.validate() }
    var document = try? profile()
    #expect(throws: LauncherError.self) {
      guard var document else { throw LauncherError.operation("fixture") }
      _ = try settings.applying(to: &document)
    }
    document = nil
  }

  @Test
  func `rejects unknown option ids`() {
    var settings = FarCry2Settings()
    settings.values["Platform"] = "d3d10"
    #expect(throws: LauncherError.self) { try settings.validate() }
  }

  @Test
  func `renderer settings change only their keys and keep every other line`() throws {
    var settings = FarCry2Settings()
    settings.values["render.scale"] = "0.75"
    settings.values["present.maxFps"] = "30"
    let original =
      "# note\nquery.flushImmediate = true\nshader.asyncCompile = true\nrender.scale = 1\n"
    let text = try settings.rendererConfig(original: original)
    #expect(text.contains("# note"))
    #expect(text.contains("query.flushImmediate = true"))
    #expect(text.contains("render.scale = 0.75"))
    #expect(text.contains("present.maxFps = 30"))
    #expect(
      text.contains("shader.asyncCompile = false"),
      "the starter owns this key and writes its default")
    #expect(text.components(separatedBy: "render.scale").count == 2)
  }

  @Test
  func `maximum quality uses native pixels and leaves unrelated options alone`() throws {
    var settings = FarCry2Settings()
    settings.values["showFPS"] = "1"
    settings.values["asyncShaders"] = "0"
    settings.values["present.maxFps"] = "60"
    settings.maximumQuality(width: 3456, height: 2234)
    try settings.validate()
    #expect(settings.value("resolution") == "3456x2234")
    #expect(settings.value("antialiasing") == "4" && settings.value("alphaToCoverage") == "0")
    #expect(
      settings.value("render.scale") == "1" && settings.value("shader.asyncCompile") == "false")
    #expect(settings.value("fullscreen") == "1" && settings.value("skipTopMip") == "0")
    #expect(settings.value("showFPS") == "1" && settings.value("asyncShaders") == "0")
    #expect(settings.value("present.maxFps") == "60")
  }

  @Test
  func `no preset combines alpha to coverage with multisampling`() {
    var settings = FarCry2Settings()
    settings.maximumQuality(width: 3024, height: 1964)
    #expect(settings.value("alphaToCoverage") == "0")
    #expect(FarCry2Settings().value("alphaToCoverage") == "0", "the default is also safe")
  }

  @Test
  func `settings survive a coding round trip and the catalog has no duplicate ids`() throws {
    var settings = FarCry2Settings()
    settings.maximumQuality(width: 1920, height: 1080)
    let decoded = try JSONDecoder().decode(
      FarCry2Settings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    let ids = FarCry2Catalog.settings.map(\.id)
    #expect(Set(ids).count == ids.count)
    for setting in FarCry2Catalog.settings {
      #expect(setting.accepts(setting.defaultValue), "\(setting.id) default must be valid")
    }
  }
}
