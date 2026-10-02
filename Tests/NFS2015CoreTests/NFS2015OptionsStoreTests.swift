import Foundation
import LauncherCore
import Synchronization
import Testing

@testable import NFS2015Core

/// Stands in for the process list: whether the game runs, and a hook for the moments the store asks.
final class GameFlag: Sendable {
  let running = Mutex<Bool?>(false)
  let asked = Mutex<Int>(0)
  let hook = Mutex<(@Sendable (Int) -> Void)?>(nil)

  var activity: NFS2015GameActivity {
    NFS2015GameActivity { [self] in
      let count = asked.withLock { value -> Int in
        value += 1
        return value
      }
      hook.withLock { $0 }?(count)
      return running.withLock { $0 }
    }
  }
}

/// A synthetic prefix with a synthetic options file, and a player folder for the backups.
struct StoreHarness {
  let prefix: SyntheticPrefix
  let support: URL
  let flag = GameFlag()
  let file: URL

  init(_ bytes: Data? = OptionsFixture.data()) throws {
    prefix = try SyntheticPrefix.complete()
    support = prefix.root.appendingPathComponent("Player")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    if let bytes {
      file = try prefix.options(bytes)
    } else {
      file = prefix.driveC.appendingPathComponent(
        "users/crossover/" + NFS2015SettingsStore.optionsPath)
    }
  }

  func remove() { prefix.remove() }

  func store(write: @escaping PlayerFileEdit.Writer = PlayerFileEdit.atomicWrite) throws
    -> NFS2015SettingsStore
  {
    let install = try #require(
      try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan).install)
    return NFS2015SettingsStore(
      support: support, install: install, activity: flag.activity, write: write)
  }

  var bytes: Data { get throws { try Data(contentsOf: file) } }
  var backups: URL { support.appendingPathComponent("Backups") }
  func backup(_ name: String) throws -> Data {
    try Data(contentsOf: backups.appendingPathComponent(name))
  }

  func save(_ changes: [String: String], digest: String? = nil, with store: NFS2015SettingsStore)
    throws -> NFS2015SettingsOutcome
  {
    let expected = try digest ?? #require(try store.inspect().digest)
    return try store.apply(
      NFS2015SettingsRequest(action: .save, changes: changes, expectedDigest: expected))
  }

  func restore(
    _ action: NFS2015SettingsRequest.Action, digest: String? = nil, with store: NFS2015SettingsStore
  ) throws -> NFS2015SettingsOutcome {
    let expected = try digest ?? #require(try store.inspect().digest)
    return try store.apply(NFS2015SettingsRequest(action: action, expectedDigest: expected))
  }
}

struct NFS2015OptionsStoreTests {
  // MARK: Reading

  @Test
  func `reads the game's file, its fingerprint and the saved copies`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let state = try harness.store().inspect()
    #expect(state.settings.value("render.resolution") == "2560x1600")
    #expect(state.settings.value("quality.texture") == "3")
    #expect(state.digest == NFS2015OptionsState.digest(of: OptionsFixture.data()))
    #expect(state.problem == nil && state.backups == NFS2015BackupState())
  }

  @Test
  func `follows the game's file as the only record`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    try Data(OptionsFixture.replacing("GstRender.VSyncEnabled", with: "1").utf8).write(
      to: harness.file)
    #expect(try store.inspect().settings.value("render.vsync") == "1")
    #expect(
      !FileManager.default.fileExists(
        atPath: harness.support.appendingPathComponent("settings.json").path))
  }

  @Test
  func `reports no options file before the game has written one, and offers nothing to write`()
    throws
  {
    let harness = try StoreHarness(nil)
    defer { harness.remove() }
    let store = try harness.store()
    #expect(try store.optionsFile() == nil)
    let state = try store.inspect()
    #expect(state.digest == nil && state.settings == NFS2015Settings() && state.problem == nil)
    let error = #expect(throws: LauncherError.self) {
      try store.apply(
        NFS2015SettingsRequest(
          action: .save, changes: ["render.vsync": "1"],
          expectedDigest: String(repeating: "0", count: 64)))
    }
    #expect(error?.localizedDescription.contains("writes its own options file") == true)
    #expect(!FileManager.default.fileExists(atPath: harness.backups.path))
  }

  @Test(arguments: NFS2015OptionsDocumentTests.refused)
  func `shows a layout it has not validated and will not write it`(variant: TextVariant) throws {
    let original = Data(variant.text.utf8)
    let harness = try StoreHarness(original)
    defer { harness.remove() }
    let store = try harness.store()
    let state = try store.inspect()
    #expect(state.problem?.contains("Nothing was changed") == true)
    #expect(state.settings == NFS2015Settings())
    let digest = NFS2015OptionsState.digest(of: original)
    #expect(throws: LauncherError.self) {
      try harness.save(["render.vsync": "1"], digest: digest, with: store)
    }
    #expect(try harness.bytes == original)
    #expect(!FileManager.default.fileExists(atPath: harness.backups.path))
  }

  // MARK: Saving

  @Test(arguments: NFS2015OptionsDocumentTests.endings)
  func `changes only the chosen lines and keeps every other byte and line ending`(
    variant: TextVariant
  ) throws {
    let harness = try StoreHarness(Data(variant.text.utf8))
    defer { harness.remove() }
    let outcome = try harness.save(
      ["render.vsync": "1", "render.brightness": "0.25", "render.resolution": "1920x1080"],
      with: try harness.store())
    var expected = OptionsFixture.replacing("GstRender.VSyncEnabled", with: "1", in: variant.text)
    expected = OptionsFixture.replacing("GstRender.Brightness", with: "0.250000", in: expected)
    expected = OptionsFixture.replacing("GstRender.ResolutionWidth", with: "1920", in: expected)
    expected = OptionsFixture.replacing("GstRender.ResolutionHeight", with: "1080", in: expected)
    #expect(try harness.bytes == Data(expected.utf8))
    guard case .saved(let lines) = outcome else {
      Issue.record("Expected a save, got \(outcome)")
      return
    }
    #expect(
      Set(lines.map(\.key)) == [
        "GstRender.VSyncEnabled", "GstRender.Brightness", "GstRender.ResolutionWidth",
        "GstRender.ResolutionHeight",
      ])
    #expect(
      lines.first { $0.key == "GstRender.ResolutionWidth" }
        == NFS2015OptionLine(key: "GstRender.ResolutionWidth", before: "2560", now: "1920"))
  }

  @Test
  func `reports what the file now holds, read back from disk`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    _ = try harness.save(["quality.shadow": "3"], with: store)
    #expect(try store.inspect().settings.value("quality.shadow") == "3")
    #expect(
      try Data(contentsOf: harness.file)
        == Data(OptionsFixture.replacing("GstRender.ShadowQuality", with: "3").utf8))
  }

  @Test
  func `applies the maximum quality preset to six levels and two effects only`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    _ = try harness.save(NFS2015Preset.maximumQuality, with: try harness.store())
    var expected = OptionsFixture.text()
    for key in [
      "EffectsQuality", "MeshQuality", "ShadowQuality", "TerrainQuality", "TextureQuality",
      "UndergrowthQuality",
    ] {
      expected = OptionsFixture.replacing("GstRender.\(key)", with: "3", in: expected)
    }
    expected = OptionsFixture.replacing("GstRender.MotionBlurEnabled", with: "0", in: expected)
    expected = OptionsFixture.replacing("GstRender.FilmGrain", with: "0", in: expected)
    #expect(try harness.bytes == Data(expected.utf8))
    #expect(try harness.store().inspect().settings.value("render.resolution") == "2560x1600")
  }

  @Test
  func `writes nothing when the file already holds what was asked for`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    // 60 is the refresh rate the file holds as 60.000000: the same value, so its digits stay.
    let outcome = try harness.save(
      ["render.refreshRate": "60", "render.fullscreen": "1"], with: store)
    #expect(outcome == .unchanged)
    #expect(try harness.bytes == OptionsFixture.data())
    #expect(!FileManager.default.fileExists(atPath: harness.backups.path))
  }

  @Test
  func `leaves no temporary file beside the options file`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    _ = try harness.save(["render.vsync": "1"], with: try harness.store())
    let names = try FileManager.default.contentsOfDirectory(
      atPath: harness.file.deletingLastPathComponent().path)
    #expect(names == ["PROFILEOPTIONS_profile"])
    #expect(
      !FileManager.default.fileExists(
        atPath: harness.support.appendingPathComponent("player-file-edit.json").path))
  }

  @Test(arguments: [
    ["quality.texture": "9"], ["render.brightness": "2"], ["render.antiAliasing": "1"],
    ["render.nothing": "1"], ["render.resolution": "10x10"],
  ])
  func `refuses a value outside its domain or a setting it does not change, writing nothing`(
    changes: [String: String]
  ) throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    #expect(throws: LauncherError.self) { try harness.save(changes, with: try harness.store()) }
    #expect(try harness.bytes == OptionsFixture.data())
    #expect(!FileManager.default.fileExists(atPath: harness.backups.path))
  }

  @Test
  func `refuses to change a key the game has not written`() throws {
    let lines = OptionsFixture.lines.filter { !$0.hasPrefix("GstRender.PresentInterval") }
    let original = Data(OptionsFixture.text(lines: lines).utf8)
    let harness = try StoreHarness(original)
    defer { harness.remove() }
    let error = #expect(throws: LauncherError.self) {
      try harness.save(["render.presentInterval": "0"], with: try harness.store())
    }
    #expect(error?.localizedDescription.contains("GstRender.PresentInterval") == true)
    #expect(try harness.bytes == original)
  }

  // MARK: The game running

  @Test
  func `refuses to save while the game is running`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    harness.flag.running.withLock { $0 = true }
    let error = #expect(throws: LauncherError.self) {
      try harness.save(
        ["render.vsync": "1"], digest: NFS2015OptionsState.digest(of: OptionsFixture.data()),
        with: store)
    }
    #expect(error?.localizedDescription.contains("running") == true)
    #expect(try harness.bytes == OptionsFixture.data())
    #expect(!FileManager.default.fileExists(atPath: harness.backups.path))
  }

  @Test
  func `refuses when it cannot tell whether the game is running`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    harness.flag.running.withLock { $0 = nil }
    #expect(throws: LauncherError.self) {
      try harness.save(
        ["render.vsync": "1"], digest: NFS2015OptionsState.digest(of: OptionsFixture.data()),
        with: store)
    }
    #expect(try harness.bytes == OptionsFixture.data())
  }

  @Test
  func `refuses a restore while the game is running`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    _ = try harness.save(["render.vsync": "1"], with: store)
    let saved = try harness.bytes
    harness.flag.running.withLock { $0 = true }
    #expect(throws: LauncherError.self) {
      try harness.restore(
        .restoreOriginal, digest: NFS2015OptionsState.digest(of: saved), with: store)
    }
    #expect(try harness.bytes == saved)
  }

  // MARK: The game changing the file behind the app's back

  @Test
  func `refuses when the game starts between the first check and the write`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    let flag = harness.flag
    flag.hook.withLock {
      $0 = { count in
        if count == 2 { flag.running.withLock { $0 = true } }
      }
    }
    #expect(throws: LauncherError.self) { try harness.save(["render.vsync": "1"], with: store) }
    #expect(try harness.bytes == OptionsFixture.data())
  }

  @Test
  func `refuses a save when the game changed the file after it was loaded`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    let loaded = try #require(try store.inspect().digest)
    let gameWrote = Data(OptionsFixture.replacing("GstRender.FilmGrain", with: "0").utf8)
    try gameWrote.write(to: harness.file)
    let error = #expect(throws: LauncherError.self) {
      try harness.save(["render.vsync": "1"], digest: loaded, with: store)
    }
    #expect(error?.localizedDescription.contains("changed after this page loaded it") == true)
    #expect(try harness.bytes == gameWrote)
    #expect(!FileManager.default.fileExists(atPath: harness.backups.path))
  }

  @Test
  func `refuses when the game changes the file between the checks and the write`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    let loaded = try #require(try store.inspect().digest)
    let gameWrote = Data(OptionsFixture.replacing("GstRender.FilmGrain", with: "0").utf8)
    let file = harness.file
    // The store asks whether the game runs before reading and again just before writing; the game
    // writes its file in between.
    harness.flag.hook.withLock {
      $0 = { count in
        if count == 2 { try? gameWrote.write(to: file) }
      }
    }
    #expect(throws: LauncherError.self) {
      try harness.save(["render.vsync": "1"], digest: loaded, with: store)
    }
    #expect(try harness.bytes == gameWrote)
  }

  @Test
  func `refuses a restore that was made for an older view of the file`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    _ = try harness.save(["render.vsync": "1"], with: store)
    let stale = NFS2015OptionsState.digest(of: OptionsFixture.data())
    let current = try harness.bytes
    #expect(throws: LauncherError.self) {
      try harness.restore(.restoreOriginal, digest: stale, with: store)
    }
    #expect(try harness.bytes == current)
  }

  // MARK: Backups and restore

  @Test
  func `keeps the first untouched copy once and the copy before the latest save`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    #expect(try store.inspect().backups == NFS2015BackupState())
    _ = try harness.save(["render.vsync": "1"], with: store)
    let afterFirst = try harness.bytes
    #expect(try harness.backup("PROFILEOPTIONS_profile.original") == OptionsFixture.data())
    #expect(try harness.backup("PROFILEOPTIONS_profile.previous") == OptionsFixture.data())
    _ = try harness.save(["quality.mesh": "0"], with: store)
    #expect(try harness.backup("PROFILEOPTIONS_profile.original") == OptionsFixture.data())
    #expect(try harness.backup("PROFILEOPTIONS_profile.previous") == afterFirst)
    #expect(try store.inspect().backups == NFS2015BackupState(original: true, previous: true))
  }

  @Test
  func `restore game defaults puts back the first copy, byte for byte`() throws {
    let harness = try StoreHarness(OptionsFixture.data(lineEnding: "\r\n"))
    defer { harness.remove() }
    let store = try harness.store()
    let original = try harness.bytes
    _ = try harness.save(["render.vsync": "1"], with: store)
    _ = try harness.save(["quality.mesh": "0"], with: store)
    let outcome = try harness.restore(.restoreOriginal, with: store)
    #expect(try harness.bytes == original)
    guard case .restored(.original, let lines) = outcome else {
      Issue.record("Expected a restore, got \(outcome)")
      return
    }
    #expect(Set(lines.map(\.key)) == ["GstRender.VSyncEnabled", "GstRender.MeshQuality"])
    #expect(lines.allSatisfy { $0.now != $0.before })
  }

  @Test
  func `undo puts back the file as it was before the latest save, and can be undone again`() throws
  {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    _ = try harness.save(["render.vsync": "1"], with: store)
    let afterFirst = try harness.bytes
    _ = try harness.save(["quality.mesh": "0"], with: store)
    let afterSecond = try harness.bytes
    _ = try harness.restore(.restorePrevious, with: store)
    #expect(try harness.bytes == afterFirst)
    _ = try harness.restore(.restorePrevious, with: store)
    #expect(try harness.bytes == afterSecond)
  }

  @Test
  func `a restore of an identical file writes nothing`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    _ = try harness.save(["render.vsync": "1"], with: store)
    _ = try harness.restore(.restoreOriginal, with: store)
    #expect(try harness.restore(.restoreOriginal, with: store) == .unchanged)
  }

  @Test(arguments: [NFS2015SettingsRequest.Action.restoreOriginal, .restorePrevious])
  func `refuses to restore a copy that does not exist`(action: NFS2015SettingsRequest.Action) throws
  {
    let harness = try StoreHarness()
    defer { harness.remove() }
    #expect(throws: LauncherError.self) { try harness.restore(action, with: try harness.store()) }
    #expect(try harness.bytes == OptionsFixture.data())
  }

  @Test
  func `refuses to restore a saved copy whose layout is no longer valid`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    _ = try harness.save(["render.vsync": "1"], with: store)
    let saved = try harness.bytes
    try Data("not an options file\n".utf8).write(
      to: harness.backups.appendingPathComponent("PROFILEOPTIONS_profile.original"))
    #expect(throws: LauncherError.self) { try harness.restore(.restoreOriginal, with: store) }
    #expect(try harness.bytes == saved)
  }

  @Test
  func `refuses to restore over a file whose layout it has not validated`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let store = try harness.store()
    _ = try harness.save(["render.vsync": "1"], with: store)
    let strange = Data("GstRender.A 1\n\nGstRender.B 2\n".utf8)
    try strange.write(to: harness.file)
    #expect(throws: LauncherError.self) { try harness.restore(.restoreOriginal, with: store) }
    #expect(try harness.bytes == strange)
  }

  // MARK: The write going wrong

  @Test
  func `puts the earlier bytes back when what was written is not what was planned`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let truncating: PlayerFileEdit.Writer = { bytes, url in
      try Data(bytes.dropLast(5)).write(to: url, options: .atomic)
    }
    let error = #expect(throws: LauncherError.self) {
      try harness.save(["render.vsync": "1"], with: try harness.store(write: truncating))
    }
    #expect(error?.localizedDescription.contains("put back") == true)
    #expect(try harness.bytes == OptionsFixture.data())
    #expect(try harness.backup("PROFILEOPTIONS_profile.original") == OptionsFixture.data())
  }

  @Test
  func `puts the earlier bytes back when a different value was written`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let wrong: PlayerFileEdit.Writer = { bytes, url in
      let text = String(decoding: bytes, as: UTF8.self)
      try Data(OptionsFixture.replacing("GstRender.VSyncEnabled", with: "0", in: text).utf8)
        .write(to: url, options: .atomic)
    }
    #expect(throws: LauncherError.self) {
      try harness.save(
        ["render.vsync": "1", "quality.mesh": "0"], with: try harness.store(write: wrong))
    }
    #expect(try harness.bytes == OptionsFixture.data())
  }

  @Test
  func `puts the earlier bytes back when a line that was not chosen was altered`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let meddling: PlayerFileEdit.Writer = { bytes, url in
      let text = String(decoding: bytes, as: UTF8.self)
      try Data(OptionsFixture.replacing("GstAudio.DynamicsEnum", with: "3", in: text).utf8)
        .write(to: url, options: .atomic)
    }
    let error = #expect(throws: LauncherError.self) {
      try harness.save(["render.vsync": "1"], with: try harness.store(write: meddling))
    }
    #expect(error?.localizedDescription.contains("put back") == true)
    #expect(try harness.bytes == OptionsFixture.data())
  }

  @Test
  func `rolls the file back when the write itself fails`() throws {
    struct Refused: Error {}
    let harness = try StoreHarness()
    defer { harness.remove() }
    let failing: PlayerFileEdit.Writer = { bytes, url in
      try Data(bytes.prefix(10)).write(to: url, options: .atomic)
      throw Refused()
    }
    let error = #expect(throws: LauncherError.self) {
      try harness.save(["render.vsync": "1"], with: try harness.store(write: failing))
    }
    #expect(error?.localizedDescription.contains("rolled back") == true)
    #expect(try harness.bytes == OptionsFixture.data())
  }

  // MARK: Interrupted edits

  @Test
  func `restores the player's file when an interrupted edit is replayed`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let original = try harness.bytes
    let edit = PlayerFileEdit(support: harness.support)
    try edit.replace(harness.file, with: Data(OptionsFixture.text(lines: ["GstRender.A 1"]).utf8))
    #expect(try harness.bytes != original)
    // Leave the journal behind the way an interrupted write would, then replay it.
    let journal = harness.support.appendingPathComponent("player-file-edit.json")
    try JSONEncoder().encode(["path": harness.file.path, "bytes": original.base64EncodedString()])
      .write(to: journal)
    try edit.recover()
    #expect(try harness.bytes == original)
    #expect(!FileManager.default.fileExists(atPath: journal.path))
  }

  @Test
  func `replays an interrupted edit before it reads the file`() throws {
    let harness = try StoreHarness()
    defer { harness.remove() }
    let original = try harness.bytes
    try Data("GstRender.A 1\n".utf8).write(to: harness.file)
    let journal = harness.support.appendingPathComponent("player-file-edit.json")
    try JSONEncoder().encode(["path": harness.file.path, "bytes": original.base64EncodedString()])
      .write(to: journal)
    let store = try harness.store()
    _ = try harness.save(
      ["render.vsync": "1"], digest: NFS2015OptionsState.digest(of: original), with: store)
    #expect(
      try harness.bytes == Data(OptionsFixture.replacing("GstRender.VSyncEnabled", with: "1").utf8))
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
