import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015FirstRunOptionsTests {
  typealias Size = NFS2015DisplayFacts.Size
  private let size = Size(width: 2560, height: 1440)

  /// A Windows user profile with a `Documents` folder and an app support folder beside it.
  private func fixture(documents: Bool = true) throws -> (Scratch, profile: URL, support: URL) {
    let scratch = try Scratch()
    let profile = scratch.url("Prefix/drive_c/users/Player")
    try FileManager.default.createDirectory(
      at: profile.appendingPathComponent(documents ? "Documents" : "Desktop"),
      withIntermediateDirectories: true)
    let support = scratch.url("Support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    return (scratch, profile, support)
  }

  private func optionsFile(_ profile: URL) -> URL {
    profile.appendingPathComponent(NFS2015SettingsStore.optionsPath)
  }

  @Test
  func `writes exactly the two resolution lines, in the layout the settings page accepts`() throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    let outcome = NFS2015FirstRunOptions.seed(size, in: profile, support: support)
    #expect(outcome == .seeded(size))
    let text = String(decoding: try Data(contentsOf: optionsFile(profile)), as: UTF8.self)
    #expect(text == "GstRender.ResolutionHeight 1440\nGstRender.ResolutionWidth 2560\n")
    let document = try ProfileOptionsDocument(text: text)
    #expect(document.keys == ["GstRender.ResolutionHeight", "GstRender.ResolutionWidth"])
    let settings = NFS2015Settings(document: document)
    #expect(settings.values["render.resolution"] == "2560x1440")
    #expect(settings.values.count == 1)
  }

  @Test
  func `holds no name, id or key binding: only two numeric resolution lines`() throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    _ = NFS2015FirstRunOptions.seed(size, in: profile, support: support)
    let text = String(decoding: try Data(contentsOf: optionsFile(profile)), as: UTF8.self)
    #expect(text.wholeMatch(of: /(GstRender\.Resolution(Width|Height) [0-9]{3,5}\n){2}/) != nil)
    #expect(!text.contains("GstKeyBinding"))
  }

  @Test
  func `creates the folders below Documents and leaves no staging file behind`() throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    _ = NFS2015FirstRunOptions.seed(size, in: profile, support: support)
    let folder = optionsFile(profile).deletingLastPathComponent()
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["PROFILEOPTIONS_profile"]
    )
  }

  @Test
  func `uses the folders that exist, whatever their letter case`() throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    let existing = profile.appendingPathComponent("Documents/need for speed/Settings")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    #expect(NFS2015FirstRunOptions.seed(size, in: profile, support: support) == .seeded(size))
    #expect(
      FileManager.default.fileExists(
        atPath: existing.appendingPathComponent("PROFILEOPTIONS_profile").path))
    let documents = try FileManager.default.contentsOfDirectory(
      atPath: profile.appendingPathComponent("Documents").path)
    #expect(documents == ["need for speed"])
  }

  @Test
  func `never replaces or adds to a file the game wrote`() throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    let written =
      "GstRender.ResolutionHeight 1200\nGstRender.ResolutionWidth 1920\nGstRender.Brightness 0.5\n"
    let url = optionsFile(profile)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(written.utf8).write(to: url)
    let outcome = NFS2015FirstRunOptions.seed(size, in: profile, support: support)
    #expect(outcome == .skipped("the game's settings folder already holds files."))
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == written)
    #expect(
      !FileManager.default.fileExists(
        atPath: support.appendingPathComponent("first-run-seed.json").path))
  }

  @Test
  func
    `does not seed into a settings folder that already holds anything, such as the game's other file`()
    throws
  {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    let folder = optionsFile(profile).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([0x46, 0x42]).write(to: folder.appendingPathComponent("PROFILEOPTIONS"))
    let outcome = NFS2015FirstRunOptions.seed(size, in: profile, support: support)
    #expect(outcome == .skipped("the game's settings folder already holds files."))
    #expect(!FileManager.default.fileExists(atPath: optionsFile(profile).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["PROFILEOPTIONS"])
  }

  @Test
  func `does not invent a Documents folder`() throws {
    let (scratch, profile, support) = try fixture(documents: false)
    defer { scratch.remove() }
    let outcome = NFS2015FirstRunOptions.seed(size, in: profile, support: support)
    #expect(outcome == .skipped("the Windows profile has no Documents folder yet."))
    #expect(
      !FileManager.default.fileExists(atPath: profile.appendingPathComponent("Documents").path))
  }

  @Test
  func `follows a linked Documents folder the way the settings page does`() throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    let target = scratch.url("Elsewhere")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let documents = profile.appendingPathComponent("Documents")
    try FileManager.default.removeItem(at: documents)
    try FileManager.default.createSymbolicLink(at: documents, withDestinationURL: target)
    #expect(NFS2015FirstRunOptions.seed(size, in: profile, support: support) == .seeded(size))
    #expect(
      FileManager.default.fileExists(
        atPath: target.appendingPathComponent("Need For Speed/settings/PROFILEOPTIONS_profile").path
      ))
  }

  @Test(arguments: [(0, 0), (100, 100), (2560, 100), (20_000, 1440), (-5, 1440)])
  func `refuses a resolution the game would not be asked for`(width: Int, height: Int) throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    let outcome = NFS2015FirstRunOptions.seed(
      Size(width: width, height: height), in: profile, support: support)
    guard case .skipped = outcome else {
      Issue.record("seeded \(width)x\(height)")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: optionsFile(profile).path))
  }

  @Test
  func `records that the file began as a seed, in the app's own folder`() throws {
    let (scratch, profile, support) = try fixture()
    defer { scratch.remove() }
    _ = NFS2015FirstRunOptions.seed(size, in: profile, support: support)
    let note = try JSONDecoder().decode(
      [String: String].self,
      from: Data(contentsOf: support.appendingPathComponent(NFS2015FirstRunOptions.markerName)))
    #expect(note["resolution"] == "2560x1440" && note["seededAt"] != nil)
  }

  @Test
  func `says in words what it did`() {
    #expect(NFS2015FirstRunOptions.Outcome.seeded(size).sentence.contains("2560x1440"))
    #expect(
      NFS2015FirstRunOptions.Outcome.skipped("x").sentence.contains("No first-run resolution"))
  }
}
