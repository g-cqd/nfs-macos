import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015MetalFXTests {
  private let renderers = [
    RendererSelection(api: "dxgi", backend: "dxmt", executable: "NFS16.exe"),
    RendererSelection(api: "dxgi", backend: "dxmt", executable: "EADesktop.exe"),
    RendererSelection(api: "dxgi", backend: "dxmt", executable: "EACefSubProcess.exe"),
  ]

  private static func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, in support: URL) throws {
    try Data(text.utf8).write(to: NFS2015MetalFXStore(support: support).location)
  }

  // MARK: Defaults and the offered values

  @Test
  func `is off by default and gives the game no environment`() {
    #expect(!NFS2015MetalFXPreference.off.spatialUpscaling)
    #expect(NFS2015MetalFX.environment(for: .off) == nil)
    #expect(NFS2015MetalFXState().preference == .off)
    #expect(NFS2015MetalFXState().notice == nil)
  }

  /// DXMT's reader accepts digits, one point and digits, and its swap chain keeps no value below
  /// 1.0; its documentation allows up to 2.0. Every offered factor must be one of those.
  @Test(arguments: NFS2015UpscaleFactor.allCases)
  func `offers only factors DXMT documents and can parse`(factor: NFS2015UpscaleFactor) throws {
    let text = factor.rawValue
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    let value = try #require(Double(text))
    #expect(value > 1.0 && value <= 2.0)
    #expect(factor.title.hasSuffix("x") || factor.title.contains("("))
  }

  @Test
  func `offers exactly five steps, with DXMT's own default last`() {
    #expect(
      NFS2015UpscaleFactor.allCases.map(\.rawValue) == ["1.25", "1.33", "1.5", "1.75", "2.0"])
    #expect(NFS2015UpscaleFactor.default == .x150)
  }

  // MARK: Configuration generation

  @Test(arguments: NFS2015UpscaleFactor.allCases)
  func `generates exactly the documented variable and option for the game`(
    factor: NFS2015UpscaleFactor
  ) throws {
    let environment = try #require(
      NFS2015MetalFX.environment(
        for: NFS2015MetalFXPreference(spatialUpscaling: true, factor: factor)))
    #expect(environment.executable == "NFS16.exe")
    #expect(
      environment.entries == [
        .init(name: "DXMT_METALFX_SPATIAL_SWAPCHAIN", value: "1"),
        .init(name: "DXMT_CONFIG", value: "d3d11.metalSpatialUpscaleFactor=\(factor.rawValue)"),
      ])
    try environment.validate()
  }

  @Test
  func `puts the choice on the game's rule only and leaves the EA app and its helpers alone`()
    throws
  {
    let environment = try #require(
      NFS2015MetalFX.environment(
        for: NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x200)))
    let rules = try RendererSelection.compatibilityDatabase(
      renderers, kind: .nfs2015, environments: [environment])
    let lines = rules.split(separator: "\n").map(String.init)
    #expect(
      lines == [
        "v=3",
        "name=nfs2015-0;exe=NFS16.exe;dxgi=dxmt;env=DXMT_METALFX_SPATIAL_SWAPCHAIN=1"
          + ";env=DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2.0",
        "name=nfs2015-1;exe=EADesktop.exe;dxgi=dxmt",
        "name=nfs2015-2;exe=EACefSubProcess.exe;dxgi=dxmt",
      ])
    #expect(rules.components(separatedBy: "DXMT_METALFX").count == 2)
  }

  @Test
  func `changes nothing in the rules while it is off`() throws {
    let plain = try RendererSelection.compatibilityDatabase(renderers, kind: .nfs2015)
    let environments = NFS2015MetalFX.environment(for: .off).map { [$0] } ?? []
    let off = try RendererSelection.compatibilityDatabase(
      renderers, kind: .nfs2015, environments: environments)
    #expect(off == plain)
  }

  @Test
  func `remembers a factor while the switch is off, and still emits nothing`() {
    let remembered = NFS2015MetalFXPreference(spatialUpscaling: false, factor: .x175)
    #expect(NFS2015MetalFX.environment(for: remembered) == nil)
  }

  // MARK: The size DXMT presents

  @Test(arguments: [
    (1920, 1200, NFS2015UpscaleFactor.x133, 2553, 1596),
    (1280, 800, NFS2015UpscaleFactor.x200, 2560, 1600),
    (2560, 1600, NFS2015UpscaleFactor.x150, 3840, 2400),
    (1920, 1080, NFS2015UpscaleFactor.x125, 2400, 1350),
    (2048, 1280, NFS2015UpscaleFactor.x125, 2560, 1600),
    (1920, 1080, NFS2015UpscaleFactor.x175, 3360, 1890),
  ])
  func `multiplies each side by the factor and drops the fraction`(
    width: Int, height: Int, factor: NFS2015UpscaleFactor, outWidth: Int, outHeight: Int
  ) {
    let size = NFS2015MetalFX.outputSize(width: width, height: height, factor: factor)
    #expect(size.width == outWidth && size.height == outHeight)
  }

  @Test
  func `says when the presented size is larger than the display`() {
    let text = NFS2015MetalFX.summary(
      game: (2560, 1600), factor: .x150, display: (2560, 1600))
    #expect(text.hasPrefix("The game draws 2560x1600 and DXMT presents 3840x2400."))
    #expect(text.contains("larger than this display's 2560x1600"))
  }

  @Test
  func `states the sizes without a warning when the display can show them`() {
    let text = NFS2015MetalFX.summary(game: (1280, 800), factor: .x200, display: (2560, 1600))
    #expect(
      text
        == "The game draws 1280x800 and DXMT presents 2560x1600. This display shows 2560x1600 pixels."
    )
  }

  @Test
  func `still states the arithmetic when the display is unknown, and says when the game is`() {
    #expect(
      NFS2015MetalFX.summary(game: (1280, 800), factor: .x200, display: nil)
        == "The game draws 1280x800 and DXMT presents 2560x1600.")
    #expect(
      NFS2015MetalFX.summary(game: nil, factor: .x200, display: (2560, 1600))
        .contains("not known until it has written its options file"))
  }

  // MARK: The saved choice

  @Test
  func `reads a missing file as off, without a notice`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let loaded = NFS2015MetalFXStore(support: support).load()
    #expect(loaded == .init(preference: .off, notice: nil))
  }

  @Test(arguments: NFS2015UpscaleFactor.allCases)
  func `keeps a choice and reads it back unchanged`(factor: NFS2015UpscaleFactor) throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = NFS2015MetalFXStore(support: support)
    let choice = NFS2015MetalFXPreference(spatialUpscaling: true, factor: factor)
    #expect(try store.save(choice))
    #expect(store.load() == .init(preference: choice, notice: nil))
    #expect(try !store.save(choice))
  }

  @Test
  func `writes the documented file contents`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = NFS2015MetalFXStore(support: support)
    _ = try store.save(NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x133))
    let text = try String(contentsOf: store.location, encoding: .utf8)
    #expect(
      text == """
        {
          "factor" : "1.33",
          "spatialUpscaling" : true,
          "version" : 1
        }
        """)
    #expect(store.location.lastPathComponent == "metalfx.json")
  }

  @Test
  func `leaves no temporary file behind and replaces the old one whole`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = NFS2015MetalFXStore(support: support)
    _ = try store.save(NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x200))
    _ = try store.save(NFS2015MetalFXPreference(spatialUpscaling: false, factor: .x125))
    #expect(try FileManager.default.contentsOfDirectory(atPath: support.path) == ["metalfx.json"])
    #expect(
      store.load().preference == NFS2015MetalFXPreference(spatialUpscaling: false, factor: .x125))
  }

  @Test
  func `resets to off by removing the file, and again is a no-op`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = NFS2015MetalFXStore(support: support)
    _ = try store.save(NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x200))
    #expect(try store.reset())
    #expect(!FileManager.default.fileExists(atPath: store.location.path))
    #expect(store.load() == .init(preference: .off, notice: nil))
    #expect(try !store.reset())
  }

  @Test
  func `reset clears a file that could not be used`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    try write("not json", in: support)
    let store = NFS2015MetalFXStore(support: support)
    #expect(store.load().notice != nil)
    #expect(try store.reset())
    #expect(store.load() == .init(preference: .off, notice: nil))
  }

  // MARK: Invalid values never reach DXMT

  @Test(arguments: [
    "",
    "not json",
    "[]",
    "{}",
    #"{"version":1,"spatialUpscaling":true}"#,
    #"{"version":1,"factor":"1.5"}"#,
    #"{"spatialUpscaling":true,"factor":"1.5"}"#,
    #"{"version":2,"spatialUpscaling":true,"factor":"1.5"}"#,
    #"{"version":0,"spatialUpscaling":true,"factor":"1.5"}"#,
    #"{"version":"1","spatialUpscaling":true,"factor":"1.5"}"#,
    #"{"version":1,"spatialUpscaling":"yes","factor":"1.5"}"#,
    #"{"version":1,"spatialUpscaling":1,"factor":"1.5"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":"1.0"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":"0"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":"2.5"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":"3"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":"-1.5"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":"1.5;d3d11.preferredMaxFrameRate=1"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":1.5}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":"nan"}"#,
    #"{"version":1,"spatialUpscaling":true,"factor":null}"#,
  ])
  func `falls back to off with a notice for a file it cannot use`(content: String) throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    try write(content, in: support)
    let loaded = NFS2015MetalFXStore(support: support).load()
    #expect(loaded.preference == .off)
    #expect(NFS2015MetalFX.environment(for: loaded.preference) == nil)
    #expect(loaded.notice?.contains("MetalFX is off") == true)
  }

  @Test
  func `falls back to off for an oversized file and for a folder in its place`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = NFS2015MetalFXStore(support: support)
    try write(String(repeating: " ", count: 5000) + #"{"version":1}"#, in: support)
    #expect(store.load().preference == .off && store.load().notice != nil)
    try FileManager.default.removeItem(at: store.location)
    try FileManager.default.createDirectory(at: store.location, withIntermediateDirectories: false)
    #expect(store.load().preference == .off && store.load().notice != nil)
  }

  @Test
  func `reads a valid choice that has an unknown extra key`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = NFS2015MetalFXStore(support: support)
    try write(#"{"version":1,"spatialUpscaling":true,"factor":"1.75","extra":1}"#, in: support)
    #expect(
      store.load().preference == NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x175))
  }

  // MARK: Requests

  @Test
  func `validates a request carries a choice exactly when it saves`() throws {
    try NFS2015MetalFXRequest(action: .save, preference: .off).validate()
    try NFS2015MetalFXRequest(action: .reset).validate()
    #expect(throws: LauncherError.self) { try NFS2015MetalFXRequest(action: .save).validate() }
    #expect(throws: LauncherError.self) {
      try NFS2015MetalFXRequest(action: .reset, preference: .off).validate()
    }
  }

  @Test
  func `reports what a request did`() throws {
    let support = try Self.folder()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = NFS2015MetalFXStore(support: support)
    let on = NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x150)
    #expect(store.apply(.init(action: .save, preference: on)) == .saved)
    #expect(store.apply(.init(action: .save, preference: on)) == .unchanged)
    #expect(store.apply(.init(action: .reset)) == .reset)
    #expect(store.apply(.init(action: .reset)) == .unchanged)
    #expect(
      store.apply(.init(action: .save))
        == .refused("A MetalFX save needs the choice to keep."))
  }

  @Test
  func `refuses, rather than failing, when the file cannot be written`() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("nowhere")
    let outcome = NFS2015MetalFXStore(support: missing).apply(
      .init(
        action: .save, preference: NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x200)))
    #expect(outcome.refusal?.contains("Could not save the MetalFX choice") == true)
  }

  @Test
  func `round trips through the launcher state, and an older state file reads as off`() throws {
    let state = NFS2015MetalFXState(
      preference: NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x133),
      notice: "n", outcome: .refused("why"))
    let snapshot = NFS2015Snapshot(metalFX: state)
    let decoded = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded.metalFX == state)
    let older = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: Data(#"{"hasOptionsFile":false,"settings":{"values":{}}}"#.utf8))
    #expect(older.metalFX == nil)
  }
}
