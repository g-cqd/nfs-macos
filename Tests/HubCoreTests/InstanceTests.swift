import Darwin
import Foundation
import HubCore
import LauncherCore
import Testing

// MARK: - Fixtures

/// A temporary folder with a `prefix` and an `instances` folder; `discard()` removes everything,
/// including folders the tests made unreadable.
private struct Sandbox {
  let root: URL
  let prefix: URL
  let instances: URL

  init() throws {
    root = URL(
      fileURLWithPath: NSTemporaryDirectory() + "hub-instance-test-" + UUID().uuidString,
      isDirectory: true)
    prefix = root.appendingPathComponent("prefix", isDirectory: true)
    instances = root.appendingPathComponent("instances", isDirectory: true)
    let files = FileManager.default
    try files.createDirectory(
      at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
    try files.createDirectory(at: instances, withIntermediateDirectories: true)
  }

  func discard() {
    var pending = [root.path]
    while let path = pending.popLast() {
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
        continue
      }
      chmod(path, 0o700)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
      pending.append(contentsOf: names.map { path + "/" + $0 })
    }
    try? FileManager.default.removeItem(at: root)
  }

  func path(_ relative: String) -> String { prefix.path + "/" + relative }
  func instancePath(_ id: String, _ relative: String = "") -> String {
    instances.path + "/" + id + (relative.isEmpty ? "" : "/" + relative)
  }

  /// Writes a source file, creating its folders, and optionally fixes its mode and time.
  @discardableResult
  func put(
    _ relative: String, _ text: String = "data", mode: mode_t? = nil,
    mtime: (seconds: Int, nanos: Int)? = nil
  ) throws -> String {
    let full = path(relative)
    try FileManager.default.createDirectory(
      atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: full, atomically: false, encoding: .utf8)
    if let mode { chmod(full, mode) }
    if let mtime { Fx.setTime(full, mtime.seconds, mtime.nanos) }
    return full
  }

  func folder(_ relative: String) throws {
    try FileManager.default.createDirectory(
      atPath: path(relative), withIntermediateDirectories: true)
  }

  func link(_ relative: String, to target: String) throws {
    try FileManager.default.createDirectory(
      atPath: (path(relative) as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: target)
  }

  /// `game.exe` (real), `other/data.bin` (placeholder), `target.txt` and an absolute link to it.
  func standardPlan() throws -> InstancePlan {
    try put(
      "drive_c/Program Files/game.exe", "game executable", mode: 0o640,
      mtime: (1_650_000_000, 500_000_000))
    try put(
      "drive_c/other/data.bin", "12345", mode: 0o604, mtime: (1_640_000_000, 250))
    try put("drive_c/target.txt", "target")
    try link("drive_c/links/link.txt", to: path("drive_c/target.txt"))
    return try InstancePlanner.plan(
      prefix: prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))
  }

  @discardableResult
  func build(
    _ plan: InstancePlan, id: String, now: Date = Fx.fixedDate
  ) throws -> InstanceManifest {
    try InstanceBuilder.build(
      plan: plan, prefix: prefix, instances: instances, instanceID: id, budget: Fx.budget, now: now)
  }
}

private enum Fx {
  static let budget = SpaceBudget(floor: 0, free: Int64.max)
  static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

  static func recipe(
    real: [String], boot: [String] = [], omit: [String] = []
  ) -> InstanceRecipe {
    InstanceRecipe(gameID: "test", realRoots: real, bootPaths: boot, omitRoots: omit)
  }

  static func setTime(_ path: String, _ seconds: Int, _ nanos: Int) {
    var times = [
      timespec(tv_sec: seconds, tv_nsec: nanos), timespec(tv_sec: seconds, tv_nsec: nanos),
    ]
    utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
  }

  static func info(_ path: String) -> stat? {
    var info = stat()
    return lstat(path, &info) == 0 ? info : nil
  }

  static func mode(_ path: String) -> UInt16? { info(path).map { $0.st_mode & 0o7777 } }

  static func exists(_ path: String) -> Bool { info(path) != nil }

  static func names(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
  }

  static func xattr(_ path: String) -> String? {
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = getxattr(path, "org.gamehub.placeholder", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
    return count >= 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : nil
  }

  static func entry(_ plan: InstancePlan, _ path: String) -> InstanceEntry? {
    plan.entries.first { $0.path == path }
  }

  static func isInvalid(_ error: any Error) -> Bool {
    if case HubError.invalid = error { return true }
    return false
  }
  /// Matches a `.io` error whose message contains `text`, so a test cannot pass on the wrong `.io`.
  static func io(containing text: String) -> (any Error) -> Bool {
    { error in
      guard case HubError.io(let message) = error else { return false }
      return message.contains(text)
    }
  }
  static func isUnsafe(_ error: any Error) -> Bool {
    if case HubError.unsafePath = error { return true }
    return false
  }
  static func isBelowFloor(_ error: any Error) -> Bool {
    if case HubError.belowFloor = error { return true }
    return false
  }

  /// Records an issue unless `body` throws an error accepted by `matches`.
  static func expectFailure(
    _ context: String, matching matches: (any Error) -> Bool, _ body: () throws -> Void
  ) {
    do {
      try body()
      Issue.record("Did not throw: \(context)")
    } catch {
      #expect(matches(error), "Wrong error \(error): \(context)")
    }
  }

  /// Ids that must never name a folder.
  static let badIDs = [
    ".", "..", "", "a\u{0}b", String(repeating: "a", count: 65), "\u{0663}", "\u{0661}\u{0662}3",
    "\u{00E9}", "\u{FF41}\u{FF42}", "a/b", "../x", "a b", "a.b", "ab\n",
  ]

  /// Mounts a case-sensitive APFS disk image at `mountpoint`, runs `body`, then ejects the image
  /// by device (the mount path may have moved by then). The test is cancelled, not failed, when
  /// the machine cannot create or attach an image.
  static func withVolume(in root: URL, at mountpoint: URL, _ body: () throws -> Void) throws {
    let image = root.appendingPathComponent("cs.sparseimage").path
    try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)
    let device: String
    do {
      _ = try hdiutil([
        "create", "-size", "16m", "-fs", "Case-sensitive APFS", "-volname", "CS", "-type",
        "SPARSE", image,
      ])
      let listing = try hdiutil([
        "attach", image, "-mountpoint", mountpoint.path, "-nobrowse", "-noverify",
      ])
      let first = listing.split(separator: "\n").first.map(String.init) ?? ""
      device = String(first.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "")
    } catch {
      try Test.cancel("hdiutil cannot create or attach a test volume: \(error)")
    }
    defer {
      // A volume that was just used can be briefly busy (indexing); each hdiutil call takes
      // long enough that a few tries are a sufficient pause.
      var failure: (any Error)?
      for _ in 0..<5 {
        do {
          _ = try hdiutil(["detach", device, "-force"])
          failure = nil
          break
        } catch {
          failure = error
        }
      }
      if let failure { Issue.record("Could not eject the test volume \(device): \(failure)") }
    }
    try body()
  }

  private static func hdiutil(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HubError.io("hdiutil \(arguments.first ?? "") failed with \(process.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self)
  }
}

/// A listening socket where Wine's server for `prefix` would be, so `PrefixActivity` sees a
/// running server. `stop()` is idempotent and also runs when the value is released.
private final class FakeWineServer {
  private let listener: Int32
  private let socketPath: String
  private let folder: URL
  private let parent: URL
  private let parentExisted: Bool
  private var stopped = false

  init(prefix: URL) throws {
    guard let socketURL = PrefixActivity.serverSocket(prefix: prefix) else {
      throw HubError.io("No server socket for \(prefix.path)")
    }
    socketPath = socketURL.path
    folder = socketURL.deletingLastPathComponent()
    parent = folder.deletingLastPathComponent()
    parentExisted = Fx.exists(parent.path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw HubError.io("socket() failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw HubError.io("Socket path too long: \(socketPath)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
      buffer[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(listener, 4) == 0 else {
      close(listener)
      throw HubError.io("Could not listen at \(socketPath)")
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    unlink(socketPath)
    close(listener)
    do { try FileManager.default.removeItem(at: folder) } catch {
      Issue.record("Could not remove the fake wineserver folder: \(error)")
    }
    if !parentExisted { rmdir(parent.path) }
  }

  deinit { stop() }
}

@Suite struct InstanceTests {
  // MARK: - InstanceID

  @Test func instanceIDAcceptsLettersDigitsAndHyphens() throws {
    for good in ["a", "A-z-0-9", String(repeating: "x", count: 64), "cod4-20231114"] {
      #expect(try InstanceID(good).rawValue == good)
    }
  }

  @Test(arguments: Fx.badIDs) func instanceIDRejectsBadIdentifiers(_ id: String) {
    Fx.expectFailure(id.debugDescription, matching: Fx.isInvalid) { _ = try InstanceID(id) }
  }

  // MARK: - SpaceProbe

  @Test func spaceProbeReturnsFreeBytes() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let freeBytes = SpaceProbe.freeBytes(at: box.root)
    #expect(freeBytes != nil)
    #expect(freeBytes ?? 0 > 0)
  }

  @Test func spaceProbeAsksTheNearestExistingAncestorOfAMissingPath() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let known = try #require(SpaceProbe.freeBytes(at: box.root))
    let nested = box.root.appendingPathComponent("GameHub/Instances/deeper", isDirectory: true)
    #expect(!Fx.exists(nested.path))
    let probed = try #require(SpaceProbe.freeBytes(at: nested))
    #expect(abs(probed - known) < 256 * 1024 * 1024)  // same volume; free space may drift a little
  }

  @Test func spaceProbeReturnsNilWhenTheVolumeCannotBeRead() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/locked/inner.txt")
    chmod(box.path("drive_c/locked"), 0)
    #expect(
      SpaceProbe.freeBytes(at: box.prefix.appendingPathComponent("drive_c/locked/x/y")) == nil)
  }

  // MARK: - Recipes

  @Test func recipesKeepOnlyFoldersThatExist() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.folder("drive_c/Program Files (x86)")
    try box.folder("drive_c/users")
    try box.folder("drive_c/ProgramData/EA Desktop")

    let cod4 = try #require(InstanceRecipes.recipe(for: .cod4, prefix: box.prefix))
    #expect(cod4.gameID == "cod4")
    #expect(cod4.realRoots == ["drive_c/Program Files (x86)", "drive_c/users", "drive_c/windows"])
    #expect(cod4.bootPaths.contains(".update-timestamp"))

    let nfs = try #require(InstanceRecipes.recipe(for: .nfs2015, prefix: box.prefix))
    #expect(
      nfs.realRoots == [
        "drive_c/Program Files (x86)", "drive_c/ProgramData/EA Desktop", "drive_c/users",
        "drive_c/windows",
      ])
    let bf3 = try #require(InstanceRecipes.recipe(for: .bf3, prefix: box.prefix))
    #expect(
      bf3.realRoots == ["drive_c/ProgramData/EA Desktop", "drive_c/users", "drive_c/windows"])
  }

  @Test func recipesAreNilForUnknownGamesAndPrefixesWithoutDriveC() throws {
    let box = try Sandbox()
    defer { box.discard() }
    #expect(InstanceRecipes.recipe(for: .nfsmw, prefix: box.prefix) == nil)
    try FileManager.default.removeItem(at: box.prefix.appendingPathComponent("drive_c"))
    #expect(InstanceRecipes.recipe(for: .cod4, prefix: box.prefix) == nil)
  }

  // MARK: - Planner: classification

  @Test func plannerClassifiesRealFilesWithModeAndTime() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()

    let entry = try #require(Fx.entry(plan, "drive_c/Program Files/game.exe"))
    #expect(entry.kind == .real)
    #expect(entry.size == 15)
    #expect(entry.mode == 0o640)
    #expect(entry.mtimeSeconds == 1_650_000_000)
    #expect(entry.mtimeNanos == 500_000_000)
    #expect(plan.realBytes == 15)
  }

  @Test func plannerClassifiesPlaceholdersWithModeAndTime() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()

    let entry = try #require(Fx.entry(plan, "drive_c/other/data.bin"))
    #expect(entry.kind == .placeholder)
    #expect(entry.size == 5)
    #expect(entry.mode == 0o604)
    #expect(entry.mtimeSeconds == 1_640_000_000)
    #expect(entry.mtimeNanos == 250)
    #expect(plan.placeholderCount == 2)  // data.bin and target.txt
  }

  @Test func plannerClassifiesDirectories() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    #expect(Fx.entry(plan, "drive_c/other")?.kind == .directory)
    let paths = plan.entries.map(\.path)
    for (index, path) in paths.enumerated() where path.contains("/") {
      let parent = (path as NSString).deletingLastPathComponent
      let parentIndex = try #require(paths.firstIndex(of: parent))
      #expect(parentIndex < index, "\(parent) must precede \(path)")
    }
  }

  @Test func plannerEmitsOmittedEntriesAndDoesNotWalkThem() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/game.exe")
    try box.put("drive_c/ProgramData/Origin/config.xml")
    try box.put("drive_c/ProgramData/Origin/deep/more.xml")
    let plan = try InstancePlanner.plan(
      prefix: box.prefix,
      recipe: Fx.recipe(real: ["drive_c/Program Files"], omit: ["drive_c/ProgramData/Origin"]))

    #expect(Fx.entry(plan, "drive_c/ProgramData/Origin")?.kind == .omitted)
    #expect(plan.entries.filter { $0.path.hasPrefix("drive_c/ProgramData/Origin/") }.isEmpty)
    #expect(plan.omittedCount == 1)
    #expect(Fx.entry(plan, "drive_c/ProgramData")?.kind == .directory)
  }

  @Test func plannerKeepsDotfilesAndSkipsOnlyDSStore() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put(".update-timestamp", "#timestamp")
    try box.put("drive_c/Program Files/.hidden", "h")
    try box.put("drive_c/Program Files/.DS_Store", "junk")
    try box.put("drive_c/other/.dotplaceholder", "p")
    let plan = try InstancePlanner.plan(
      prefix: box.prefix,
      recipe: Fx.recipe(real: ["drive_c/Program Files"], boot: [".update-timestamp"]))

    #expect(Fx.entry(plan, ".update-timestamp")?.kind == .real)
    #expect(Fx.entry(plan, "drive_c/Program Files/.hidden")?.kind == .real)
    #expect(Fx.entry(plan, "drive_c/other/.dotplaceholder")?.kind == .placeholder)
    #expect(Fx.entry(plan, "drive_c/Program Files/.DS_Store") == nil)

    try box.build(plan, id: "dots")
    #expect(Fx.exists(box.instancePath("dots", "Prefix/.update-timestamp")))
    #expect(Fx.exists(box.instancePath("dots", "Prefix/drive_c/Program Files/.hidden")))
  }

  @Test func plannerCountsEveryHardLink() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let first = try box.put("drive_c/Program Files/a.bin", String(repeating: "z", count: 100))
    let second = box.path("drive_c/Program Files/b.bin")
    #expect(link(first, second) == 0)
    let plan = try InstancePlanner.plan(
      prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))

    #expect(plan.entries.filter { $0.kind == .real }.count == 2)
    #expect(plan.realBytes == 200)
    #expect(plan.allocatedBytes >= 200)

    try box.build(plan, id: "links")
    #expect(Fx.info(box.instancePath("links", "Prefix/drive_c/Program Files/a.bin"))?.st_nlink == 1)
  }

  @Test func plannerSkipsAndCountsSpecialFiles() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/game.exe")
    try box.folder("drive_c/Program Files/run")
    #expect(mkfifo(box.path("drive_c/Program Files/run/pipe"), 0o644) == 0)
    let plan = try InstancePlanner.plan(
      prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))

    #expect(plan.skippedSpecialCount == 1)
    #expect(Fx.entry(plan, "drive_c/Program Files/run/pipe") == nil)
    try box.build(plan, id: "special")
    #expect(!Fx.exists(box.instancePath("special", "Prefix/drive_c/Program Files/run/pipe")))
  }

  @Test func plannerThrowsWhenNoRealRootMatches() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/other/data.bin")
    #expect {
      _ = try InstancePlanner.plan(prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/missing"]))
    } throws: { Fx.isInvalid($0) }
    #expect {
      _ = try InstancePlanner.plan(prefix: box.prefix, recipe: Fx.recipe(real: []))
    } throws: { Fx.isInvalid($0) }
  }

  @Test func plannerThrowsWhenAFolderCannotBeListed() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/game.exe")
    try box.put("drive_c/locked/file.txt")
    chmod(box.path("drive_c/locked"), 0)
    #expect {
      _ = try InstancePlanner.plan(
        prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))
    } throws: { Fx.io(containing: "Could not list")($0) }
  }

  // MARK: - Planner: recipe paths

  @Test func plannerRejectsAbsoluteAndParentRecipePaths() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/game.exe")
    for bad in [
      "/absolute/path", "drive_c/foo/../bar", "../x", "./x", ".", "..", "", "a/./b", "a\u{0}b",
    ] {
      for slot in 0..<3 {
        var recipe = Fx.recipe(real: ["drive_c/Program Files"])
        switch slot {
        case 0: recipe.realRoots.append(bad)
        case 1: recipe.bootPaths.append(bad)
        default: recipe.omitRoots.append(bad)
        }
        Fx.expectFailure("slot \(slot) path \(bad.debugDescription)", matching: Fx.isInvalid) {
          _ = try InstancePlanner.plan(prefix: box.prefix, recipe: recipe)
        }
      }
    }
  }

  @Test func plannerNormalizesRecipePathsByComponents() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/a/b/file.txt")
    try box.put("drive_c/a/..foo/file.txt")
    try box.put("drive_c/a/bc/file.txt")
    try box.put("drive_c/abc/file.txt")
    let plan = try InstancePlanner.plan(
      prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c//a/b/", "drive_c/a/..foo"]))

    #expect(Fx.entry(plan, "drive_c/a/b/file.txt")?.kind == .real)
    #expect(Fx.entry(plan, "drive_c/a/..foo/file.txt")?.kind == .real)
    #expect(Fx.entry(plan, "drive_c/a/bc/file.txt")?.kind == .placeholder)
    #expect(Fx.entry(plan, "drive_c/abc/file.txt")?.kind == .placeholder)
  }

  // MARK: - Planner: symlinks

  @Test func plannerRewritesLinksIntoThePrefixAsRelative() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()

    let entry = try #require(Fx.entry(plan, "drive_c/links/link.txt"))
    #expect(entry.kind == .symlink)
    #expect(entry.linkTarget == "../target.txt")
    #expect(plan.externalLinks.isEmpty)
  }

  @Test func plannerKeepsExternalLinksAndListsThem() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/game.exe")
    let outside = box.root.appendingPathComponent("outside.txt").path
    try box.link("drive_c/ext", to: outside)
    try box.link("dosdevices/z:", to: "/")
    try box.link("dosdevices/c:", to: "../drive_c")
    try box.link("drive_c/links/up", to: "../../../outside")
    try box.link("drive_c/links/top", to: "../..")
    try box.link("drive_c/links/sibling", to: "../Program Files/game.exe")
    let plan = try InstancePlanner.plan(
      prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))

    #expect(Fx.entry(plan, "drive_c/ext")?.linkTarget == outside)
    #expect(Fx.entry(plan, "dosdevices/z:")?.linkTarget == "/")
    #expect(Fx.entry(plan, "dosdevices/c:")?.linkTarget == "../drive_c")
    #expect(Fx.entry(plan, "drive_c/links/up")?.linkTarget == "../../../outside")
    #expect(Fx.entry(plan, "drive_c/links/top")?.linkTarget == "../..")
    #expect(
      Set(plan.externalLinks) == ["drive_c/ext", "dosdevices/z:", "drive_c/links/up"])
  }

  // MARK: - Builder

  @Test func builderCreatesZeroLengthPlaceholdersWithModeTimeAndMarker() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    try box.build(plan, id: "test-instance-1")

    let placeholders = plan.entries.filter { $0.kind == .placeholder }
    #expect(placeholders.count == 2)
    for entry in placeholders {
      let path = box.instancePath("test-instance-1", "Prefix/" + entry.path)
      let info = try #require(Fx.info(path))
      #expect(info.st_size == 0)
      #expect(info.st_mode & 0o7777 == entry.mode)
      #expect(Int64(info.st_mtimespec.tv_sec) == entry.mtimeSeconds)
      #expect(Int32(info.st_mtimespec.tv_nsec) == entry.mtimeNanos)
      #expect(Fx.xattr(path) != nil)
    }
    let data = box.instancePath("test-instance-1", "Prefix/drive_c/other/data.bin")
    #expect(Fx.xattr(data) == "5:1640000000.000000250")
    #expect(Fx.mode(data) == 0o604)
  }

  @Test func builderCopiesRealFilesWithModeAndTime() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    try box.build(plan, id: "test-instance-2")

    let copy = box.instancePath("test-instance-2", "Prefix/drive_c/Program Files/game.exe")
    #expect(try String(contentsOfFile: copy, encoding: .utf8) == "game executable")
    let info = try #require(Fx.info(copy))
    #expect(info.st_mode & 0o7777 == 0o640)
    #expect(info.st_mtimespec.tv_sec == 1_650_000_000)
    #expect(info.st_mtimespec.tv_nsec == 500_000_000)
  }

  @Test func builderRecreatesLinksRelatively() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    try box.build(plan, id: "test-instance-3")

    let link = box.instancePath("test-instance-3", "Prefix/drive_c/links/link.txt")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "../target.txt")
    #expect(try String(contentsOfFile: link, encoding: .utf8).isEmpty)  // target is a placeholder
  }

  @Test func writingThroughAnInstanceLinkLeavesTheSourceUntouched() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let original = try box.put("drive_c/Program Files/data.txt", "original")
    try box.link("drive_c/Program Files/alias", to: original)
    let plan = try InstancePlanner.plan(
      prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))
    try box.build(plan, id: "through")

    let alias = box.instancePath("through", "Prefix/drive_c/Program Files/alias")
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: alias)
    #expect(!target.hasPrefix("/"))
    #expect(!target.contains(box.prefix.path))
    try "changed".write(toFile: alias, atomically: false, encoding: .utf8)

    #expect(try String(contentsOfFile: original, encoding: .utf8) == "original")
    let copy = box.instancePath("through", "Prefix/drive_c/Program Files/data.txt")
    #expect(try String(contentsOfFile: copy, encoding: .utf8) == "changed")
  }

  @Test func builderRefusesALinkThatResolvesIntoTheSource() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/data.txt", "original")
    let plan = InstancePlan(
      recipe: Fx.recipe(real: ["drive_c"]),
      entries: [
        InstanceEntry(path: "drive_c", kind: .directory, mode: 0o755),
        InstanceEntry(path: "drive_c/evil", kind: .symlink, linkTarget: box.path("drive_c")),
        InstanceEntry(
          path: "drive_c/dangling", kind: .symlink, linkTarget: box.path("drive_c/gone")),
      ], realBytes: 0, placeholderCount: 0, omittedCount: 0)

    #expect { try box.build(plan, id: "evil") } throws: { Fx.isUnsafe($0) }
    #expect(Fx.names(box.instances.path).filter { $0 != ".lock" }.isEmpty)
  }

  @Test func builderRejectsHostilePlanPaths() throws {
    let box = try Sandbox()
    defer { box.discard() }
    for bad in ["../evil", "/abs", "a//b", "a/./b", "a/../b", "", "x/", "n\u{0}ul", "."] {
      let plan = InstancePlan(
        recipe: Fx.recipe(real: ["x"]),
        entries: [InstanceEntry(path: bad, kind: .placeholder)], realBytes: 0, placeholderCount: 1,
        omittedCount: 0)
      Fx.expectFailure("path \(bad.debugDescription)", matching: Fx.isUnsafe) {
        try box.build(plan, id: "hostile")
      }
    }
    #expect(Fx.names(box.instances.path).isEmpty)
    #expect(!Fx.exists(box.root.path + "/evil"))
  }

  @Test func builderNeverWritesThroughAnEarlierLinkOrWithoutAParentEntry() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let outside = box.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let throughLink = InstancePlan(
      recipe: Fx.recipe(real: ["d"]),
      entries: [
        InstanceEntry(path: "d", kind: .directory, mode: 0o755),
        InstanceEntry(path: "d/l", kind: .symlink, linkTarget: outside.path),
        InstanceEntry(path: "d/l/f", kind: .placeholder),
      ], realBytes: 0, placeholderCount: 1, omittedCount: 0)
    #expect { try box.build(throughLink, id: "through-link") } throws: { Fx.isUnsafe($0) }
    #expect(Fx.names(outside.path).isEmpty)

    let orphan = InstancePlan(
      recipe: Fx.recipe(real: ["d"]),
      entries: [InstanceEntry(path: "d/f", kind: .placeholder)], realBytes: 0, placeholderCount: 1,
      omittedCount: 0)
    #expect { try box.build(orphan, id: "orphan") } throws: { Fx.isUnsafe($0) }
  }

  @Test func builderOmitsOmittedEntries() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/game.exe")
    try box.put("drive_c/ProgramData/Origin/config.xml")
    let plan = try InstancePlanner.plan(
      prefix: box.prefix,
      recipe: Fx.recipe(real: ["drive_c/Program Files"], omit: ["drive_c/ProgramData/Origin"]))
    let omitted = plan.entries.filter { $0.kind == .omitted }
    #expect(omitted.count == 1)
    try box.build(plan, id: "omit")

    for entry in omitted {
      #expect(!Fx.exists(box.instancePath("omit", "Prefix/" + entry.path)))
    }
    #expect(Fx.exists(box.instancePath("omit", "Prefix/drive_c/ProgramData")))
  }

  @Test func builderLeavesNoStagingFolderBehind() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "test-instance-5")
    let names = Fx.names(box.instances.path)
    #expect(names.contains("test-instance-5"))
    #expect(names.filter { $0.hasPrefix(".staging-") || $0.hasPrefix(".trash-") }.isEmpty)
  }

  @Test func builderWritesManifest() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let manifest = try box.build(plan, id: "test-instance-6")

    #expect(manifest.instanceID == "test-instance-6")
    #expect(manifest.gameID == "test")
    #expect(manifest.realBytes == plan.realBytes)
    #expect(manifest.entries == plan.entries)
    let data = try Data(
      contentsOf: URL(fileURLWithPath: box.instancePath("test-instance-6", "instance.json")))
    #expect(try InstanceManifest.decoder().decode(InstanceManifest.self, from: data) == manifest)
  }

  @Test func builderPreservesReadOnlyDirectoryTimeAndKeepsOwnerAccess() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/ro/child.txt", "child")
    try box.put("drive_c/Program Files/ro/sub/deep.txt", "deep")
    Fx.setTime(box.path("drive_c/Program Files/ro/sub"), 1_500_000_000, 111)
    chmod(box.path("drive_c/Program Files/ro/sub"), 0o555)
    Fx.setTime(box.path("drive_c/Program Files/ro"), 1_600_000_000, 123_456_789)
    chmod(box.path("drive_c/Program Files/ro"), 0o555)
    let plan = try InstancePlanner.plan(
      prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))
    try box.build(plan, id: "readonly")

    let folder = box.instancePath("readonly", "Prefix/drive_c/Program Files/ro")
    #expect(try String(contentsOfFile: folder + "/child.txt", encoding: .utf8) == "child")
    #expect(try String(contentsOfFile: folder + "/sub/deep.txt", encoding: .utf8) == "deep")
    let info = try #require(Fx.info(folder))
    #expect(info.st_mtimespec.tv_sec == 1_600_000_000)
    #expect(info.st_mtimespec.tv_nsec == 123_456_789)
    #expect(info.st_mode & 0o7777 == 0o755)
    let sub = try #require(Fx.info(folder + "/sub"))
    #expect(sub.st_mtimespec.tv_sec == 1_500_000_000)
    #expect(sub.st_mtimespec.tv_nsec == 111)
    // The source was not changed.
    #expect(Fx.mode(box.path("drive_c/Program Files/ro")) == 0o555)
  }

  @Test func builderThrowsBelowFloorBeforeWritingAnything() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    chmod(box.instances.path, 0o500)  // any write into it would fail with .io
    defer { chmod(box.instances.path, 0o700) }

    #expect {
      try InstanceBuilder.build(
        plan: plan, prefix: box.prefix, instances: box.instances, instanceID: "floor",
        budget: SpaceBudget(floor: 1_000_000_000_000, free: 1_000), now: Fx.fixedDate)
    } throws: { Fx.isBelowFloor($0) }
    #expect(Fx.names(box.instances.path).isEmpty)
  }

  @Test func builderBudgetCoversAllocatedBytesAndAMargin() throws {
    let box = try Sandbox()
    defer { box.discard() }
    var plan = try box.standardPlan()
    plan.allocatedBytes = 10_000_000_000
    let budget = SpaceBudget(floor: 0, free: 5_000_000_000)
    #expect(budget.allows(adding: plan.realBytes))

    #expect {
      try InstanceBuilder.build(
        plan: plan, prefix: box.prefix, instances: box.instances, instanceID: "alloc",
        budget: budget, now: Fx.fixedDate)
    } throws: { error in
      guard case HubError.belowFloor(let needed, _, _) = error else { return false }
      return needed > 10_000_000_000
    }
    #expect(Fx.names(box.instances.path).isEmpty)

    var exact = plan
    exact.allocatedBytes = exact.realBytes
    let tight = SpaceBudget(floor: 0, free: exact.allocatedBytes)
    #expect {
      try InstanceBuilder.build(
        plan: exact, prefix: box.prefix, instances: box.instances, instanceID: "margin",
        budget: tight, now: Fx.fixedDate)
    } throws: { Fx.isBelowFloor($0) }
  }

  @Test func builderRefusesDuplicateInstanceID() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    try box.build(plan, id: "duplicate-test")
    #expect { try box.build(plan, id: "duplicate-test") } throws: {
      Fx.io(containing: "already exists")($0)
    }
    #expect(Fx.exists(box.instancePath("duplicate-test", "instance.json")))
    #expect(Fx.names(box.instances.path).filter { $0.hasPrefix(".staging-") }.isEmpty)
  }

  @Test(arguments: Fx.badIDs) func builderRefusesBadInstanceIDs(_ id: String) throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    #expect { try box.build(plan, id: id) } throws: { Fx.isInvalid($0) }
    #expect(Fx.names(box.instances.path).isEmpty)
  }

  @Test func builderSweepsLeftoversOfCrashedBuildsUnderTheLock() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let files = FileManager.default
    let staging = box.instancePath(".staging-old-aaaaaaaa", "Prefix/ro")
    try files.createDirectory(atPath: staging, withIntermediateDirectories: true)
    try "x".write(toFile: staging + "/file", atomically: false, encoding: .utf8)
    chmod(staging, 0o500)
    try files.createDirectory(
      atPath: box.instancePath(".trash-old"), withIntermediateDirectories: true)
    try "y".write(
      toFile: box.instancePath(".trash-old", "file"), atomically: false, encoding: .utf8)
    try "keep".write(toFile: box.instancePath("notes.txt"), atomically: false, encoding: .utf8)
    try box.build(plan, id: "first")

    #expect(Fx.names(box.instances.path) == [".lock", "first", "notes.txt"])
  }

  @Test func aSecondBuildIsRefusedAndALiveStagingFolderSurvives() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let live = box.instancePath(".staging-live-12345678")
    try FileManager.default.createDirectory(
      atPath: live + "/Prefix", withIntermediateDirectories: true)
    try "in progress".write(toFile: live + "/Prefix/file", atomically: false, encoding: .utf8)

    let holder = open(box.instancePath(".lock"), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    try #require(holder >= 0)
    defer { close(holder) }
    try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)

    #expect { try box.build(plan, id: "second") } throws: { Fx.io(containing: "being built")($0) }
    #expect { try InstanceRemover.remove(instanceID: "second", instances: box.instances) } throws: {
      Fx.io(containing: "being built")($0)
    }
    #expect(try String(contentsOfFile: live + "/Prefix/file", encoding: .utf8) == "in progress")
    #expect(!Fx.exists(box.instancePath("second")))
  }

  @Test func aFailedBuildDeletesOnlyItsOwnStagingFolder() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let good = try box.standardPlan()
    try box.build(good, id: "survivor")
    let broken = InstancePlan(
      recipe: Fx.recipe(real: ["missing.bin"]),
      entries: [InstanceEntry(path: "missing.bin", kind: .real, size: 1)], realBytes: 1,
      placeholderCount: 0, omittedCount: 0)

    #expect { try box.build(broken, id: "broken") } throws: {
      Fx.io(containing: "Copying failed")($0)
    }
    #expect(Fx.names(box.instances.path) == [".lock", "survivor"])
    #expect(Fx.exists(box.instancePath("survivor", "instance.json")))
  }

  // MARK: - Round trip and store

  @Test func buildListRemoveRoundTrip() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let manifest = try box.build(plan, id: "round-trip")

    let listed = InstanceStore.list(instances: box.instances)
    #expect(listed.count == 1)
    #expect(listed.first?.id == "round-trip")
    #expect(listed.first?.createdAt == Fx.fixedDate)
    #expect(listed.first?.realBytes == plan.realBytes)
    let data = try Data(
      contentsOf: URL(fileURLWithPath: box.instancePath("round-trip", "instance.json")))
    #expect(try InstanceManifest.decoder().decode(InstanceManifest.self, from: data) == manifest)

    try InstanceRemover.remove(instanceID: "round-trip", instances: box.instances)
    #expect(InstanceStore.list(instances: box.instances).isEmpty)
    #expect(Fx.names(box.instances.path) == [".lock"])
  }

  @Test func storeListsInstancesNewestFirst() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    try box.build(plan, id: "instance-1", now: Fx.fixedDate.addingTimeInterval(-100))
    try box.build(plan, id: "instance-2", now: Fx.fixedDate.addingTimeInterval(-50))
    try box.build(plan, id: "instance-3", now: Fx.fixedDate)

    #expect(
      InstanceStore.list(instances: box.instances).map(\.id) == [
        "instance-3", "instance-2", "instance-1",
      ])
  }

  @Test func storeSkipsUnreadableMismatchedAndForeignFolders() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let files = FileManager.default
    func manifest(_ id: String) throws -> Data {
      try InstanceManifest.encoder().encode(
        InstanceManifest(
          instanceID: id, gameID: "test", createdAt: Fx.fixedDate, sourcePrefix: "/path",
          realBytes: 100, entries: []))
    }
    try files.createDirectory(atPath: box.instancePath("valid"), withIntermediateDirectories: true)
    try manifest("valid").write(
      to: URL(fileURLWithPath: box.instancePath("valid", "instance.json")))
    try files.createDirectory(
      atPath: box.instancePath("invalid"), withIntermediateDirectories: true)
    try Data("invalid json".utf8).write(
      to: URL(fileURLWithPath: box.instancePath("invalid", "instance.json")))
    try files.createDirectory(
      atPath: box.instancePath("no-manifest"), withIntermediateDirectories: true)
    try files.createDirectory(
      atPath: box.instancePath("renamed"), withIntermediateDirectories: true)
    try manifest("other").write(
      to: URL(fileURLWithPath: box.instancePath("renamed", "instance.json")))
    try files.createDirectory(
      atPath: box.instancePath(".hidden"), withIntermediateDirectories: true)
    try manifest(".hidden").write(
      to: URL(fileURLWithPath: box.instancePath(".hidden", "instance.json")))
    try "plain".write(toFile: box.instancePath("a-file"), atomically: false, encoding: .utf8)

    let listed = InstanceStore.list(instances: box.instances)
    #expect(listed.map(\.id) == ["valid"])
    #expect(listed.first?.url.lastPathComponent == "valid")
  }

  @Test func storeSkipsAFinderCopyOfAnInstance() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "alpha")
    try FileManager.default.copyItem(
      atPath: box.instancePath("alpha"), toPath: box.instancePath("alpha copy"))
    try FileManager.default.copyItem(
      atPath: box.instancePath("alpha"), toPath: box.instancePath("alpha-copy"))

    #expect(InstanceStore.list(instances: box.instances).map(\.id) == ["alpha"])
  }

  @Test func storeSkipsLinkedFoldersAndOversizedManifests() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "real")
    try FileManager.default.createSymbolicLink(
      atPath: box.instancePath("linked"), withDestinationPath: box.instancePath("real"))
    let big = box.instancePath("big")
    try FileManager.default.createDirectory(atPath: big, withIntermediateDirectories: true)
    #expect(FileManager.default.createFile(atPath: big + "/instance.json", contents: nil))
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big + "/instance.json"))
    try handle.truncate(atOffset: UInt64(InstanceManifest.maxFileBytes) + 1)
    try handle.close()

    #expect(InstanceStore.list(instances: box.instances).map(\.id) == ["real"])
  }

  // MARK: - Remover

  @Test func removerRemovesValidInstance() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "remove-test")
    try InstanceRemover.remove(instanceID: "remove-test", instances: box.instances)
    #expect(!Fx.exists(box.instancePath("remove-test")))
    #expect(!Fx.exists(box.instancePath(".trash-remove-test")))
  }

  @Test func removerRefusesSymlinkTarget() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let target = box.instancePath("real-target")
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    _ = FileManager.default.createFile(atPath: target + "/instance.json", contents: Data())
    try FileManager.default.createSymbolicLink(
      atPath: box.instancePath("symlink-instance"), withDestinationPath: target)

    #expect {
      try InstanceRemover.remove(instanceID: "symlink-instance", instances: box.instances)
    } throws: {
      Fx.isUnsafe($0)
    }
    #expect(Fx.exists(target + "/instance.json"))
  }

  @Test func removerRefusesIDMismatch() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try FileManager.default.createDirectory(
      atPath: box.instancePath("mismatch-instance"), withIntermediateDirectories: true)
    let manifest = InstanceManifest(
      instanceID: "different-id", gameID: "test", createdAt: Fx.fixedDate,
      sourcePrefix: "/some/path",
      realBytes: 100, entries: [])
    try InstanceManifest.encoder().encode(manifest).write(
      to: URL(fileURLWithPath: box.instancePath("mismatch-instance", "instance.json")))

    #expect {
      try InstanceRemover.remove(instanceID: "mismatch-instance", instances: box.instances)
    } throws: {
      Fx.isUnsafe($0)
    }
    #expect(Fx.exists(box.instancePath("mismatch-instance", "instance.json")))
  }

  @Test(arguments: Fx.badIDs) func removerRefusesBadIDsAndTouchesNothing(_ id: String) throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "decoy")
    try "precious".write(toFile: box.root.path + "/victim.txt", atomically: false, encoding: .utf8)

    #expect { try InstanceRemover.remove(instanceID: id, instances: box.instances) } throws: {
      Fx.isInvalid($0)
    }
    #expect(Fx.exists(box.instancePath("decoy", "instance.json")))
    #expect(Fx.exists(box.root.path + "/victim.txt"))
    #expect(Fx.exists(box.prefix.path))
  }

  @Test func removerDeletesReadOnlyAndUnreadableDirectoriesInsideAnInstance() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.put("drive_c/Program Files/ro/child.txt")
    chmod(box.path("drive_c/Program Files/ro"), 0o555)
    try box.build(
      try InstancePlanner.plan(
        prefix: box.prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"])),
      id: "locked")
    let nested = box.instancePath("locked", "Prefix/drive_c/Program Files/ro/nested")
    try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
    try "x".write(toFile: nested + "/file", atomically: false, encoding: .utf8)
    chmod(nested, 0)
    chmod(box.instancePath("locked", "Prefix/drive_c/Program Files/ro"), 0o500)

    try InstanceRemover.remove(instanceID: "locked", instances: box.instances)
    #expect(!Fx.exists(box.instancePath("locked")))
    #expect(!Fx.exists(box.instancePath(".trash-locked")))
  }

  @Test func removerNeverFollowsLinksOutOfTheInstance() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let outside = box.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let canary = outside.appendingPathComponent("canary.txt")
    try "canary".write(to: canary, atomically: false, encoding: .utf8)
    try box.build(try box.standardPlan(), id: "symlink-test")
    try FileManager.default.createSymbolicLink(
      atPath: box.instancePath("symlink-test", "Prefix/external-file"),
      withDestinationPath: canary.path)
    try FileManager.default.createSymbolicLink(
      atPath: box.instancePath("symlink-test", "Prefix/external-dir"),
      withDestinationPath: outside.path)

    try InstanceRemover.remove(instanceID: "symlink-test", instances: box.instances)

    #expect(try String(contentsOf: canary, encoding: .utf8) == "canary")
    #expect(!Fx.exists(box.instancePath("symlink-test")))
  }

  @Test func removerNamesTheLeftoverTrashFolderWhenDeletionFails() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "stuck")
    let pinned = box.instancePath("stuck", "Prefix/drive_c/other/data.bin")
    try #require(chflags(pinned, UInt32(UF_IMMUTABLE)) == 0)
    defer {
      // Clear the flag wherever the file ended up, or the sandbox could not be deleted.
      chflags(pinned, 0)
      chflags(box.instancePath(".trash-stuck", "Prefix/drive_c/other/data.bin"), 0)
    }

    #expect {
      try InstanceRemover.remove(instanceID: "stuck", instances: box.instances)
    } throws: { error in
      guard case HubError.io(let message) = error else { return false }
      return message.contains(".trash-stuck")
    }
    #expect(!Fx.exists(box.instancePath("stuck")))
    #expect(Fx.exists(box.instancePath(".trash-stuck", "instance.json")))
    #expect(InstanceStore.list(instances: box.instances).isEmpty)
  }

  @Test func removerRefusesWhileTheInstancesWineServerRuns() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "busy")
    let prefix = URL(fileURLWithPath: box.instancePath("busy", "Prefix"))
    let server = try FakeWineServer(prefix: prefix)
    defer { server.stop() }
    try #require(PrefixActivity.serverIsRunning(prefix: prefix))

    #expect { try InstanceRemover.remove(instanceID: "busy", instances: box.instances) } throws: {
      Fx.io(containing: "Wine server is running")($0)
    }
    #expect(Fx.exists(box.instancePath("busy", "instance.json")))

    server.stop()
    try #require(!PrefixActivity.serverIsRunning(prefix: prefix))
    try InstanceRemover.remove(instanceID: "busy", instances: box.instances)
    #expect(!Fx.exists(box.instancePath("busy")))
  }

  @Test func builderRefusesWhileTheSourceWineServerRuns() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let server = try FakeWineServer(prefix: box.prefix)
    defer { server.stop() }
    try #require(PrefixActivity.serverIsRunning(prefix: box.prefix))

    #expect { try box.build(plan, id: "torn") } throws: {
      Fx.io(containing: "Quit the game before creating an instance.")($0)
    }
    #expect(Fx.names(box.instances.path).isEmpty)

    server.stop()
    try box.build(plan, id: "torn")
    #expect(Fx.exists(box.instancePath("torn", "instance.json")))
  }

  // MARK: - Builder: required bytes, sweep, time validation

  @Test func requiredBytesIsExactlyWhatTheBuilderChecks() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let needed = InstanceBuilder.requiredBytes(plan)
    #expect(needed == plan.allocatedBytes + 1_048_576 + Int64(plan.entries.count) * 1024)

    let exactly = SpaceBudget(floor: 0, free: needed)
    try InstanceBuilder.build(
      plan: plan, prefix: box.prefix, instances: box.instances, instanceID: "exact",
      budget: exactly, now: Fx.fixedDate)
    let oneShort = SpaceBudget(floor: 0, free: needed - 1)
    #expect {
      try InstanceBuilder.build(
        plan: plan, prefix: box.prefix, instances: box.instances, instanceID: "short",
        budget: oneShort, now: Fx.fixedDate)
    } throws: { error in
      guard case HubError.belowFloor(let reported, _, _) = error else { return false }
      return reported == needed
    }
    var huge = plan
    huge.allocatedBytes = Int64.max
    #expect(InstanceBuilder.requiredBytes(huge) == Int64.max)
  }

  @Test func aStuckTrashFolderDoesNotBlockLaterBuilds() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    try box.build(plan, id: "stuck")
    let pinned = box.instancePath(".trash-stuck", "Prefix/drive_c/other/data.bin")
    try #require(
      chflags(box.instancePath("stuck", "Prefix/drive_c/other/data.bin"), UInt32(UF_IMMUTABLE)) == 0
    )
    defer { chflags(pinned, 0) }
    #expect(throws: HubError.self) {
      try InstanceRemover.remove(instanceID: "stuck", instances: box.instances)
    }
    try #require(Fx.exists(pinned))

    try box.build(plan, id: "fresh")

    #expect(Fx.exists(box.instancePath("fresh", "instance.json")))
    #expect(Fx.exists(pinned))  // still there for the user to deal with
  }

  @Test func sweepOnlyTouchesStagingAndTrashFoldersWithADash() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let keepers = [
      "foreign", ".staging", ".stagingx", ".trash", ".trashcan", "staging-x", "x.trash-y",
    ]
    for name in keepers {
      try FileManager.default.createDirectory(
        atPath: box.instancePath(name), withIntermediateDirectories: true)
      try "keep".write(toFile: box.instancePath(name, "file"), atomically: false, encoding: .utf8)
    }
    try FileManager.default.createDirectory(
      atPath: box.instancePath(".staging-gone-00000000"), withIntermediateDirectories: true)
    try box.build(plan, id: "sweeper")

    for name in keepers {
      #expect(Fx.exists(box.instancePath(name, "file")), "\(name) must survive the sweep")
    }
    #expect(!Fx.exists(box.instancePath(".staging-gone-00000000")))
  }

  @Test func builderRejectsModificationTimesOutsideASecond() throws {
    let box = try Sandbox()
    defer { box.discard() }
    // 1_000_000_000 is a whole second; the next two are UTIME_NOW and UTIME_OMIT, which mean
    // "now" and "leave alone" to utimensat; -1 and Int32.max are simply wrong.
    for nanos: Int32 in [1_000_000_000, 1_073_741_823, 1_073_741_822, -1, Int32.max] {
      for kind in [EntryKind.placeholder, .directory, .real] {
        let plan = InstancePlan(
          recipe: Fx.recipe(real: ["x"]),
          entries: [InstanceEntry(path: "x", kind: kind, mtimeNanos: nanos)], realBytes: 0,
          placeholderCount: 0, omittedCount: 0)
        Fx.expectFailure("\(kind) with \(nanos) ns", matching: Fx.isInvalid) {
          try box.build(plan, id: "time")
        }
      }
    }
    #expect(Fx.names(box.instances.path).isEmpty)
  }

  @Test func placeholderMarkerKeepsNanosecondDigits() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = InstancePlan(
      recipe: Fx.recipe(real: ["x"]),
      entries: [
        InstanceEntry(path: "a", kind: .placeholder, size: 3, mtimeSeconds: 7, mtimeNanos: 0),
        InstanceEntry(
          path: "b", kind: .placeholder, size: 3, mtimeSeconds: 7, mtimeNanos: 999_999_999),
      ], realBytes: 0, placeholderCount: 2, omittedCount: 0)
    try box.build(plan, id: "digits")
    #expect(Fx.xattr(box.instancePath("digits", "Prefix/a")) == "3:7.000000000")
    #expect(Fx.xattr(box.instancePath("digits", "Prefix/b")) == "3:7.999999999")
  }

  // MARK: - Builder and remover: mutation guards

  @Test func builderNeverCopiesThroughALinkThatBecameTheSource() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let secret = box.root.appendingPathComponent("secret.txt").path
    try "secret".write(toFile: secret, atomically: false, encoding: .utf8)
    try box.link("drive_c/Program Files/data.txt", to: secret)
    let plan = InstancePlan(
      recipe: Fx.recipe(real: ["drive_c"]),
      entries: [
        InstanceEntry(path: "drive_c", kind: .directory, mode: 0o755),
        InstanceEntry(path: "drive_c/Program Files", kind: .directory, mode: 0o755),
        InstanceEntry(path: "drive_c/Program Files/data.txt", kind: .real, size: 6),
      ], realBytes: 6, placeholderCount: 0, omittedCount: 0)

    #expect { try box.build(plan, id: "followed") } throws: {
      Fx.io(containing: "not a regular file")($0)
    }
    #expect(Fx.names(box.instances.path) == [".lock"])
  }

  @Test func builderRefusesToReuseAPlaceholderPath() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = InstancePlan(
      recipe: Fx.recipe(real: ["d"]),
      entries: [
        InstanceEntry(path: "d", kind: .directory, mode: 0o755),
        InstanceEntry(path: "d/f", kind: .placeholder, size: 1),
        InstanceEntry(path: "d/f", kind: .placeholder, size: 2),
      ], realBytes: 0, placeholderCount: 2, omittedCount: 0)
    #expect { try box.build(plan, id: "twice") } throws: {
      Fx.io(containing: "Creating the placeholder")($0)
    }
    #expect(Fx.names(box.instances.path) == [".lock"])
  }

  @Test func buildNeverReplacesAFolderThatAppearsBeforeTheFinalRename() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    let target = box.instancePath("racy")

    #expect {
      try InstanceBuilder.build(
        plan: plan, prefix: box.prefix, instances: box.instances, instanceID: "racy",
        budget: Fx.budget, now: Fx.fixedDate, beforePublish: { mkdir(target, 0o700) })
    } throws: { Fx.io(containing: "Moving the finished instance into place")($0) }
    #expect(Fx.names(target).isEmpty)  // the intruder is untouched, and it is not an instance
    #expect(Fx.names(box.instances.path) == [".lock", "racy"])
  }

  @Test func removeNeverReplacesATrashFolderThatAppearsBeforeTheRename() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "raced")
    let trash = box.instancePath(".trash-raced")

    #expect {
      try InstanceRemover.remove(
        instanceID: "raced", instances: box.instances, beforeMove: { mkdir(trash, 0o700) })
    } throws: { Fx.io(containing: "Moving the instance to the trash")($0) }
    #expect(Fx.exists(box.instancePath("raced", "instance.json")))
    #expect(Fx.names(trash).isEmpty)
  }

  @Test func removerWorksThroughASymlinkedInstancesFolderAndLeavesTheLinkAlone() throws {
    let box = try Sandbox()
    defer { box.discard() }
    try box.build(try box.standardPlan(), id: "behind-a-link")
    let alias = box.root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      atPath: alias.path, withDestinationPath: box.instances.path)

    try InstanceRemover.remove(instanceID: "behind-a-link", instances: alias)

    #expect(!Fx.exists(box.instancePath("behind-a-link")))
    #expect(Fx.names(box.instances.path) == [".lock"])
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == box.instances.path)
    #expect {
      try InstanceRemover.remove(
        instanceID: "x", instances: box.root.appendingPathComponent("no-such-folder"))
    } throws: { Fx.isUnsafe($0) }
  }

  // MARK: - Lock

  @Test func theLockIsRefusedThroughASymlinkAndClosesOnExec() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let outside = box.root.appendingPathComponent("outside.lock").path
    try "untouched".write(toFile: outside, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: box.instancePath(".lock"), withDestinationPath: outside)
    #expect {
      try box.build(try box.standardPlan(), id: "linked-lock")
    } throws: { Fx.io(containing: "Opening the instance lock")($0) }
    #expect(try String(contentsOfFile: outside, encoding: .utf8) == "untouched")
    try FileManager.default.removeItem(atPath: box.instancePath(".lock"))

    let lock = try InstanceLock.acquire(instancesPath: box.instances.path)
    let closesOnExec = lock.closesOnExec  // a noncopyable value cannot go into #expect
    #expect(closesOnExec)
    #expect {
      let second = try InstanceLock.acquire(instancesPath: box.instances.path)
      second.release()
    } throws: { Fx.io(containing: "being built")($0) }
    lock.release()
    let again = try InstanceLock.acquire(instancesPath: box.instances.path)
    again.release()
  }

  // MARK: - Store header

  @Test func storeListsFromTheHeaderAndDoesNotDecodeEntries() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let plan = try box.standardPlan()
    try box.build(plan, id: "header-only")
    let path = box.instancePath("header-only", "instance.json")
    let text = try String(contentsOfFile: path, encoding: .utf8)
    try #require(text.contains("\"kind\" : \"real\""))
    try text.replacingOccurrences(of: "\"kind\" : \"real\"", with: "\"kind\" : \"bogus\"")
      .write(toFile: path, atomically: false, encoding: .utf8)

    let listed = InstanceStore.list(instances: box.instances)
    #expect(listed.map(\.id) == ["header-only"])
    #expect(listed.first?.realBytes == plan.realBytes)
    // The remover still decodes the whole manifest, so it refuses a damaged one.
    #expect {
      try InstanceRemover.remove(instanceID: "header-only", instances: box.instances)
    } throws: { Fx.isUnsafe($0) }
  }

  // MARK: - Real prefix (read only)

  /// Plans, without writing, the prefix whose absolute path is in `HUB_LIVE_TEST`.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["HUB_LIVE_TEST"] != nil))
  func plannerHandlesARealPrefix() throws {
    let path = ProcessInfo.processInfo.environment["HUB_LIVE_TEST"] ?? ""
    guard path.hasPrefix("/") else {
      Issue.record("HUB_LIVE_TEST must be the absolute path of a Wine prefix.")
      return
    }
    let plan = try InstancePlanner.plan(
      prefix: URL(fileURLWithPath: path, isDirectory: true),
      recipe: Fx.recipe(
        real: ["drive_c/users", "drive_c/windows"],
        boot: ["system.reg", "user.reg", "userdef.reg", ".update-timestamp", "dosdevices"]))
    #expect(!plan.entries.isEmpty)
    #expect(plan.realBytes > 0)
    #expect(plan.allocatedBytes >= 0)
  }
}

/// The tests that mount a disk image. `hdiutil` spawns a child process, so they run one at a
/// time. They are cancelled, not failed, where an image cannot be attached.
@Suite(.serialized) struct InstanceVolumeTests {
  @Test func plannerRejectsNamesThatDifferOnlyByCase() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let mount = box.root.appendingPathComponent("cs-mount", isDirectory: true)
    try Fx.withVolume(in: box.root, at: mount) {
      let prefix = mount.appendingPathComponent("prefix", isDirectory: true)
      let folder = prefix.appendingPathComponent("drive_c/Program Files")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try "1".write(
        to: folder.appendingPathComponent("Readme.txt"), atomically: false, encoding: .utf8)
      try "2".write(
        to: folder.appendingPathComponent("README.TXT"), atomically: false, encoding: .utf8)
      #expect {
        _ = try InstancePlanner.plan(
          prefix: prefix, recipe: Fx.recipe(real: ["drive_c/Program Files"]))
      } throws: { error in
        guard case HubError.invalid(let message) = error else { return false }
        return message.contains("Readme.txt") && message.contains("README.TXT")
      }
    }
  }

  @Test func theDeleterStaysOnOneVolume() throws {
    let box = try Sandbox()
    defer { box.discard() }
    let tree = box.root.appendingPathComponent("tree", isDirectory: true)
    let mount = tree.appendingPathComponent("mnt", isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try "own".write(
      to: tree.appendingPathComponent("own.txt"), atomically: false, encoding: .utf8)
    // The tree is deleted in place, not renamed: a volume mounted under a renamed folder
    // stays busy for minutes and could not be ejected afterwards.
    try Fx.withVolume(in: box.root, at: mount) {
      try "canary".write(
        to: mount.appendingPathComponent("canary.txt"), atomically: false, encoding: .utf8)

      // The mount point itself cannot be removed, so the deletion reports it.
      #expect {
        try TreeDeleter.remove(path: tree.path)
      } throws: { Fx.io(containing: "mnt")($0) }

      #expect(
        try String(contentsOf: mount.appendingPathComponent("canary.txt"), encoding: .utf8)
          == "canary")
      #expect(!Fx.exists(tree.appendingPathComponent("own.txt").path))
    }
  }
}
