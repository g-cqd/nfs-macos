import LauncherCore
import Testing

@testable import NFSMWLauncher

@MainActor
struct LauncherModelTests {
  @Test func `aspect ratio changes update width and height together`() {
    let sut = LauncherModel()
    sut.aspectRatio = .wide16to9
    #expect(sut.selectedResolution == "1920x1080")
    #expect(sut.resolutionPresets.allSatisfy { $0.ratio == .wide16to9 })
    sut.selectedResolution = "2560x1440"
    #expect(sut.settings.value("width") == "2560")
    #expect(sut.settings.value("height") == "1440")
    #expect(
      !sut.graphics(in: "Display & MetalFX").contains { $0.id == "width" || $0.id == "height" })
  }

  @Test func `controller bindings retain changes when switching profiles`() throws {
    let sut = LauncherModel()
    sut.commandBinding("GAMEACTION_GAS").wrappedValue = "XINPUT_GAMEPAD_LT"
    sut.selectedMappingProfile = "Player Two"
    #expect(sut.settings.mappingEdits[""]?.value(for: "GAMEACTION_GAS") == "XINPUT_GAMEPAD_LT")
    sut.commandBinding("GAMEACTION_BRAKE").wrappedValue = "XINPUT_GAMEPAD_RT"
    sut.selectedMappingProfile = ""
    #expect(sut.settings.mappings.value(for: "GAMEACTION_GAS") == "XINPUT_GAMEPAD_LT")
    #expect(
      sut.settings.mappingEdits["Player Two"]?.value(for: "GAMEACTION_BRAKE") == "XINPUT_GAMEPAD_RT"
    )
    try sut.settings.validate()
  }
  @Test func `overview starts ready to play and describes rendering honestly`() {
    let sut = LauncherModel()
    #expect(sut.tab == "Play")
    #expect(sut.renderingSummary.contains("Native"))
    sut.settings.values["scale"] = "0.75"
    #expect(sut.renderingSummary.contains("MetalFX spatial"))
    sut.settings.values["scale"] = "1"
    sut.settings.values["retina"] = "1"
    #expect(sut.renderingSummary.contains("MetalFX"))
  }

  @Test func `common and advanced graphics expose each editable option once`() {
    let sut = LauncherModel()
    let common = sut.commonGraphics.map(\.id)
    let advanced = GraphicsCatalog.groups.flatMap { sut.advancedGraphics(in: $0).map(\.id) }
    let expected = GraphicsCatalog.settings.filter { $0.id != "width" && $0.id != "height" }.map(
      \.id)
    #expect(Set(common).isDisjoint(with: Set(advanced)))
    #expect(Set(common + advanced) == Set(expected))
  }

  @Test func `quality presets preserve display preferences`() {
    let sut = LauncherModel()
    sut.selectedResolution = "2560x1440"
    sut.settings.values["window"] = "2"
    sut.settings.values["fps"] = "60"
    sut.lighterGraphics()
    #expect(sut.selectedResolution == "2560x1440")
    #expect(sut.settings.value("window") == "2")
    #expect(sut.settings.value("fps") == "60")
    #expect(sut.settings.value("scale") == "0.75")
  }

}
