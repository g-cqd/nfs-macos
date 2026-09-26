import Testing

@testable import LauncherCore
@testable import NFSMWLauncher

@MainActor
struct MaximumQualityTests {
  @Test(arguments: [(5120, 2880), (6016, 3384), (3024, 1964)])
  func `maximum quality includes display sizes outside the built in presets`(size: (Int, Int))
    throws
  {
    let display = try #require(ResolutionPreset(width: size.0, height: size.1))
    let sut = LauncherModel(maximumDisplayPreset: { display })
    sut.maximumGraphics()
    #expect(sut.selectedResolution == display.id)
    #expect(sut.resolutionPresets.contains { $0.id == display.id })
    #expect(sut.aspectRatios.contains(display.ratio))
    try sut.settings.validate()
  }

  @Test func `maximum quality selects the detected screen and restores full resolution rendering`()
    throws
  {
    let display = try #require(ResolutionPreset.all.first { $0.id == "2560x1600" })
    let sut = LauncherModel(maximumDisplayPreset: { display })
    sut.settings.values["scale"] = "0.5"
    sut.settings.values["msaa"] = "0"
    sut.settings.values["smaa"] = "1"
    sut.settings.values["retina"] = "0"
    sut.settings.values["fps"] = "120"
    sut.settings.values["leftDeadzone"] = "0.2"
    sut.maximumGraphics()
    #expect(sut.selectedResolution == "2560x1600")
    #expect(sut.settings.value("scale") == "1")
    #expect(sut.settings.value("retina") == "1")
    #expect(sut.settings.value("window") == "4")
    #expect(sut.settings.value("msaa") == "2")
    #expect(sut.settings.value("smaa") == "0")
    #expect(sut.settings.value("shadowResolution") == "8192")
    #expect(sut.settings.value("world") == "3")
    #expect(sut.settings.value("fps") == "120")
    #expect(sut.settings.value("leftDeadzone") == "0.2")
    try sut.settings.validate()
  }

  @Test func `display detection failure leaves settings intact`() {
    let sut = LauncherModel(maximumDisplayPreset: { nil })
    let before = sut.settings
    sut.maximumGraphics()
    #expect(sut.settings == before)
  }
}
