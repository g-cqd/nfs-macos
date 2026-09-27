import CoD4Core
import LauncherCore
import Testing

struct CoD4SettingsTests {
  @Test func `maximum quality changes graphics without changing sound or bindings`() throws {
    var sut = CoD4Settings()
    sut.values["snd_volume"] = "0.4"
    sut.bindings["W"] = "+back"
    sut.maximumQuality(width: 2560, height: 1600)
    try sut.validate()
    #expect(sut.value("r_mode") == "2560x1600")
    #expect(sut.value("r_aaSamples") == "4")
    #expect(sut.value("r_picmip") == "0")
    #expect(sut.value("render.scale") == "1")
    #expect(sut.value("shader.asyncCompile") == "false")
    #expect(sut.value("snd_volume") == "0.4")
    #expect(sut.bindings["W"] == "+back")
  }

  @Test
  func `config editing removes duplicate owned assignments and retains progress and custom binds`()
    throws
  {
    let source =
      "// player\r\nseta r_aaSamples \"1\"\r\nseta R_AASAMPLES \"2\"\r\nseta mis_01 \"1\"\r\nbind F9 \"screenshotJPEG\"\r\n"
    let sut = CoD4Settings()
    let output = try sut.applying(to: source, mode: .singlePlayer)
    #expect(output.components(separatedBy: "seta r_aaSamples").count == 2)
    #expect(!output.contains("R_AASAMPLES"))
    #expect(output.contains("seta mis_01 \"1\""))
    #expect(output.contains("bind F9 \"screenshotJPEG\""))
    #expect(try sut.applying(to: output, mode: .singlePlayer) == output)
  }

  @Test(arguments: ["1\nquit", "4\";quit", "NaN", "infinity", "-1", "10001"])
  func `untrusted numeric settings are rejected`(value: String) {
    var sut = CoD4Settings()
    sut.values["sensitivity"] = value
    #expect(throws: LauncherError.self) { try sut.validate() }
    #expect(throws: LauncherError.self) { try sut.applying(to: "", mode: .singlePlayer) }
  }

  @Test func `unknown settings and executable binding commands cannot be imported`() {
    var sut = CoD4Settings()
    sut.values["exec"] = "outside.cfg"
    #expect(throws: LauncherError.self) { try sut.validate() }
    sut.values.removeValue(forKey: "exec")
    sut.bindings["W"] = "exec outside.cfg"
    #expect(throws: LauncherError.self) { try sut.validate() }
    sut.bindings = ["W\nquit": "+forward"]
    #expect(throws: LauncherError.self) { try sut.validate() }
  }

  @Test func `imports only managed config fields without copying private or mission data`() throws {
    let sut = try CoD4Settings(
      config:
        "seta sensitivity \"2.5\"\nseta r_cdKey \"private\"\nseta mis_01 \"1\"\nbind W \"+back\"\n")
    #expect(sut.value("sensitivity") == "2.5")
    #expect(sut.values["r_cdKey"] == nil)
    #expect(sut.values["mis_01"] == nil)
    #expect(sut.bindings["W"] == "+back")
  }

  @Test func `renderer settings are separate from game dvars and preserve other renderer options`()
    throws
  {
    let sut = CoD4Settings()
    let game = try sut.applying(to: "", mode: .singlePlayer)
    #expect(!game.contains("render.scale"))
    let renderer = try sut.rendererConfig(
      original: "# keep\ncustom.flag = true\nrender.scale = 0.5\n")
    #expect(renderer.contains("render.scale = 1"))
    #expect(renderer.contains("custom.flag = true"))
    #expect(!renderer.contains("r_aaSamples"))
  }

  @Test func `multiplayer leaves campaign-only settings unchanged`() throws {
    let sut = CoD4Settings()
    let output = try sut.applying(to: "seta cg_subtitles \"0\"\n", mode: .multiplayer)
    #expect(output.contains("seta cg_subtitles \"0\""))
    #expect(!output.contains("seta cg_subtitles \"1\""))
  }

  @Test func `anisotropic filtering minimum cannot exceed its maximum`() {
    var sut = CoD4Settings()
    sut.values["r_texFilterAnisoMin"] = "16"
    sut.values["r_texFilterAnisoMax"] = "4"
    #expect(throws: LauncherError.self) { try sut.validate() }
  }

  @Test func `oversized config and invalid resolutions fail before editing`() {
    #expect(throws: LauncherError.self) {
      try CoD4Settings(config: String(repeating: "x", count: 1_048_577))
    }
    var sut = CoD4Settings()
    sut.maximumQuality(width: 0, height: 1600)
    #expect(throws: LauncherError.self) { try sut.validate() }
  }
}
