import Darwin
import Foundation
import Synchronization
import Testing

@testable import HubCore

/// Records how it was asked to run Wine. Like Wine, it sets up `WINEPREFIX/drive_c/windows`
/// unless told not to; it can also run a hook meanwhile, or fail.
private final class RecordingRunner: RuntimeProcessRunner {
  struct Call: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
  }

  let calls = Mutex<[Call]>([])
  let failure: HubError?
  let setsUpPrefix: Bool
  let onRun: (@Sendable () -> Void)?

  init(failure: HubError? = nil, setsUpPrefix: Bool = true, onRun: (@Sendable () -> Void)? = nil) {
    self.failure = failure
    self.setsUpPrefix = setsUpPrefix
    self.onRun = onRun
  }

  func run(
    executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval
  ) throws(HubError) -> RuntimeProcessResult {
    calls.withLock {
      $0.append(
        Call(
          executable: executable.path, arguments: arguments, environment: environment,
          timeout: timeout))
    }
    onRun?()
    if let failure { throw failure }
    if setsUpPrefix, let prefix = environment["WINEPREFIX"] {
      try? FileManager.default.createDirectory(
        atPath: prefix + "/drive_c/windows", withIntermediateDirectories: true)
    }
    return RuntimeProcessResult(exitCode: 1, output: "wine: chdir failed\n")
  }

  var count: Int { calls.withLock { $0.count } }
}

/// A Wine tree with a few Mach-O files, a live prefix with the EA app, and a scratch folder.
private struct WarmupFixture {
  let root: URL
  var wine: URL { root.appendingPathComponent("Wine") }
  var live: URL { root.appendingPathComponent("Prefix") }
  var scratch: URL { root.appendingPathComponent("Scratch/aot-prefix") }
  var stampFile: URL { root.appendingPathComponent("State/eagep-warmup.json") }
  var eagep: URL {
    live.appendingPathComponent(
      "drive_c/Program Files/Electronic Arts/EA Desktop/13.805.11.6320-1791598480/EA Desktop/EAGEP.exe")
  }

  static let machO: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1]

  init() throws {
    let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(resolved) }
    root = URL(fileURLWithPath: String(cString: resolved) + "/gepwarm-\(UUID().uuidString)")
    try write("Wine/bin/wine", Self.machO)
    try write("Wine/bin/wineserver", Self.machO)
    try write("Wine/lib/wine/x86_64-unix/ntdll.so", Self.machO)
    try write("Wine/lib/wine/x86_64-unix/win32u.so", Self.machO)
    try write("Wine/lib/wine/x86_64-windows/ntdll.dll", Array("MZ not mach-o".utf8))
    try write("Wine/share/wine/wine.inf", Array("text".utf8))
    try FileManager.default.createSymbolicLink(
      atPath: wine.path + "/lib/wine/x86_64-unix/link.so", withDestinationPath: "ntdll.so")
    let ea = "Prefix/drive_c/Program Files/Electronic Arts/EA Desktop"
    try write(ea + "/13.805.11.6320-1791598480/EA Desktop/EAGEP.exe", Array("MZ".utf8))
    try FileManager.default.createSymbolicLink(
      atPath: root.path + "/" + ea + "/13.805.99.0", withDestinationPath: "13.805.11.6320-1791598480")
  }

  func write(_ path: String, _ bytes: [UInt8]) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
  }

  func warmup(_ runner: RecordingRunner, scratch: URL? = nil) -> EAGEPWarmup {
    EAGEPWarmup(
      wine: wine, scratchPrefix: scratch ?? self.scratch, stampFile: stampFile, runner: runner,
      timeout: 77)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The `.unsafePath` message of the refusal, or nil when `body` did not throw that case.
private func unsafePathMessage(_ body: () throws(HubError) -> Void) -> String? {
  do throws(HubError) {
    try body()
  } catch {
    if case .unsafePath(let message) = error { return message }
  }
  return nil
}

@Suite struct RuntimeTranslationStampTests {
  @Test func coversTheMachOFilesOnly() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let stamp = try RuntimeTranslationStamp.of(wine: fixture.wine)
    // bin/wine, bin/wineserver, ntdll.so, win32u.so; not the PE file, the text or the link.
    #expect(stamp.files == 4)
    #expect(stamp.digest.count == 64)
    #expect(try RuntimeTranslationStamp.of(wine: fixture.wine) == stamp)
  }

  @Test func changesWhenALibraryIsReplacedEvenWithTheSameContent() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let before = try RuntimeTranslationStamp.of(wine: fixture.wine)
    // A replaced file is a new file to Rosetta: same bytes, new inode.
    let library = fixture.wine.appendingPathComponent("lib/wine/x86_64-unix/win32u.so")
    try FileManager.default.removeItem(at: library)
    try fixture.write("Wine/lib/wine/x86_64-unix/win32u.so", WarmupFixture.machO)
    #expect(try RuntimeTranslationStamp.of(wine: fixture.wine) != before)
  }

  @Test func changesWhenTheTreeMoves() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let before = try RuntimeTranslationStamp.of(wine: fixture.wine)
    let moved = fixture.root.appendingPathComponent("Wine-moved")
    try FileManager.default.moveItem(at: fixture.wine, to: moved)
    #expect(try RuntimeTranslationStamp.of(wine: moved) != before)
  }

  @Test func refusesATreeWithoutMachOFiles() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("Empty/bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("Empty/lib"), withIntermediateDirectories: true)
    #expect(throws: HubError.invalid("\(fixture.root.path)/Empty holds no Mach-O file.")) {
      try RuntimeTranslationStamp.of(wine: fixture.root.appendingPathComponent("Empty"))
    }
  }
}

@Suite struct EAGEPWarmupTests {
  @Test func locatesEAGEPThroughTheVersionFolders() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let found = try #require(EAGEPWarmup.locateEAGEP(inPrefix: fixture.live))
    #expect(found.path == EAGEPWarmup.canonical(fixture.eagep))
    #expect(EAGEPWarmup.locateEAGEP(inPrefix: fixture.scratch) == nil)
  }

  @Test func runsEAGEPInTheScratchPrefixAndRecordsTheStamp() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let runner = RecordingRunner()
    let warmup = fixture.warmup(runner)
    #expect(try warmup.isNeeded())

    let result = try warmup.run(
      eagep: fixture.eagep, livePrefix: fixture.live,
      home: URL(fileURLWithPath: "/Users/x/RuntimeHome"))

    #expect(result.exitCode == 1)  // EAGEP's own status is not a failure of the warm-up
    let call = try #require(runner.calls.withLock { $0.first })
    #expect(call.executable == fixture.wine.path + "/bin/wine")
    #expect(call.arguments == [fixture.eagep.path])
    #expect(call.timeout == 77)
    #expect(call.environment["WINEPREFIX"] == fixture.scratch.path)
    #expect(call.environment["ROSETTA_X87_PATH"] == "")
    #expect(call.environment["HOME"] == "/Users/x/RuntimeHome")
    #expect(call.environment["WINEDLLOVERRIDES"]?.contains("mscoree,mshtml=") == true)
    #expect(call.environment["ROSETTA_DISABLE_AOT"] == nil)
    #expect(try warmup.recordedStamp() == RuntimeTranslationStamp.of(wine: fixture.wine))
    #expect(try !warmup.isNeeded())
  }

  @Test func isNeededAgainAfterTheRuntimeChanges() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let warmup = fixture.warmup(RecordingRunner())
    try warmup.run(eagep: fixture.eagep, livePrefix: fixture.live)
    #expect(try !warmup.isNeeded())

    try fixture.write("Wine/lib/wine/x86_64-unix/winemac.so", WarmupFixture.machO)
    #expect(try warmup.isNeeded())
  }

  @Test func aRuntimeChangedDuringTheRunIsWarmedAgainNextTime() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let library = fixture.root.path + "/Wine/lib/wine/x86_64-unix/winemac.so"
    let runner = RecordingRunner(onRun: {
      FileManager.default.createFile(atPath: library, contents: Data(WarmupFixture.machO))
    })
    let warmup = fixture.warmup(runner)
    try warmup.run(eagep: fixture.eagep, livePrefix: fixture.live)
    #expect(try warmup.isNeeded())
  }

  @Test func anUnreadableStampMeansNeeded() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    try fixture.write("State/eagep-warmup.json", Array("{not json".utf8))
    #expect(try fixture.warmup(RecordingRunner()).isNeeded())
  }

  @Test func aFailedRunRecordsNothing() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let warmup = fixture.warmup(RecordingRunner(failure: .io("did not finish")))
    #expect(throws: HubError.io("did not finish")) {
      try warmup.run(eagep: fixture.eagep, livePrefix: fixture.live)
    }
    #expect(warmup.recordedStamp() == nil)
    #expect(try warmup.isNeeded())
  }

  @Test func aWineThatNeverSetUpThePrefixRecordsNothing() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let warmup = fixture.warmup(RecordingRunner(setsUpPrefix: false))
    do throws(HubError) {
      try warmup.run(eagep: fixture.eagep, livePrefix: fixture.live)
      Issue.record("expected a failure")
    } catch {
      guard case .io(let message) = error else {
        Issue.record("unexpected \(error)")
        return
      }
      #expect(message.contains("EAGEP never ran (exit 1)"))
      #expect(message.contains("chdir failed"))
    }
    #expect(warmup.recordedStamp() == nil)
  }

  @Test func createsTheScratchPrefixFolders() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let deep = fixture.root.appendingPathComponent("a/b/c/prefix")
    try fixture.warmup(RecordingRunner(), scratch: deep).run(
      eagep: fixture.eagep, livePrefix: fixture.live)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: deep.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  @Test(arguments: ["Prefix", "Prefix/drive_c/scratch", ""])
  func refusesAScratchPrefixThatOverlapsTheEAPrefix(_ relative: String) throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let runner = RecordingRunner()
    // "" is the parent of the EA prefix.
    let scratch = relative.isEmpty ? fixture.root : fixture.root.appendingPathComponent(relative)
    let warmup = fixture.warmup(runner, scratch: scratch)
    let message = unsafePathMessage { () throws(HubError) in
      try warmup.run(eagep: fixture.eagep, livePrefix: fixture.live)
    }
    #expect(message?.contains("overlaps") == true)
    #expect(runner.count == 0)
    #expect(warmup.recordedStamp() == nil)
  }

  @Test func refusesAScratchPrefixReachedThroughALinkIntoTheEAPrefix() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    // A link into the EA prefix's drive_c: only the resolved-path overlap check can catch it.
    let link = fixture.root.appendingPathComponent("prefix-link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Prefix/drive_c")
    let runner = RecordingRunner()
    let message = unsafePathMessage { () throws(HubError) in
      try fixture.warmup(runner, scratch: link.appendingPathComponent("aot"))
        .run(eagep: fixture.eagep, livePrefix: fixture.live)
    }
    #expect(message?.contains("overlaps") == true)
    #expect(runner.count == 0)
  }

  @Test func refusesDotDotComponents() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let link = fixture.root.appendingPathComponent("l")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Prefix/drive_c")
    let runner = RecordingRunner()
    // To the system, l/../aot is Prefix/aot, inside the EA prefix.
    let scratch = URL(fileURLWithPath: link.path + "/../aot")
    let message = unsafePathMessage { () throws(HubError) in
      try fixture.warmup(runner, scratch: scratch).run(eagep: fixture.eagep, livePrefix: fixture.live)
    }
    #expect(message?.contains("'..'") == true)
    #expect(runner.count == 0)
  }

  @Test func refusesAScratchPrefixThatHoldsAnEAApp() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    try fixture.write("Scratch/aot-prefix/drive_c/ProgramData/EA Desktop/machine.ini", [])
    let runner = RecordingRunner()
    let message = unsafePathMessage { () throws(HubError) in
      try fixture.warmup(runner).run(eagep: fixture.eagep, livePrefix: fixture.live)
    }
    #expect(message?.contains("holds an EA app") == true)
    #expect(runner.count == 0)
  }

  @Test func refusesAMissingEAGEP() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let runner = RecordingRunner()
    let missing = fixture.root.appendingPathComponent("nope.exe")
    #expect(throws: HubError.invalid("\(missing.path) is not a file.")) {
      try fixture.warmup(runner).run(eagep: missing, livePrefix: fixture.live)
    }
    #expect(runner.count == 0)
  }
}

@Suite struct WarmEAGEPCommandTests {
  private func run(_ arguments: [String], runner: RecordingRunner) -> (
    status: Int32, out: String, err: String
  ) {
    let out = Mutex("")
    let err = Mutex("")
    let status = RuntimeCommand.run(
      ["warm-eagep"] + arguments, runner: runner, output: { text in out.withLock { $0 += text } },
      diagnostics: { text in err.withLock { $0 += text } })
    return (status, out.withLock { $0 }, err.withLock { $0 })
  }

  private func arguments(_ fixture: WarmupFixture, prefix: URL? = nil) -> [String] {
    [
      "--wine", fixture.wine.path, "--prefix", (prefix ?? fixture.live).path, "--scratch",
      fixture.scratch.path, "--stamp", fixture.stampFile.path,
    ]
  }

  @Test func usageErrorsExitOne() throws {
    let runner = RecordingRunner()
    #expect(run([], runner: runner).status == 1)
    #expect(run(["--wine"], runner: runner).status == 1)
    #expect(run(["--wine", "/a", "--wine", "/b"], runner: runner).status == 1)
    #expect(run(["--bogus", "x"], runner: runner).status == 1)
    #expect(runner.count == 0)
  }

  @Test func warmsOnceThenReportsNothingToDo() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let runner = RecordingRunner()
    let first = run(arguments(fixture), runner: runner)
    #expect(first.status == 0)
    #expect(first.out.contains("OK: warmed"))
    #expect(first.out.contains("EAGEP exit 1"))
    let second = run(arguments(fixture), runner: runner)
    #expect(second.status == 0)
    #expect(second.out.contains("nothing to do"))
    #expect(runner.count == 1)
    #expect(run(arguments(fixture) + ["--force"], runner: runner).status == 0)
    #expect(runner.count == 2)
  }

  @Test func noEAAppExitsTwo() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let runner = RecordingRunner()
    let result = run(arguments(fixture, prefix: fixture.scratch), runner: runner)
    #expect(result.status == 2)
    #expect(runner.count == 0)
  }

  @Test func anOverlappingScratchPrefixExitsTwo() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let runner = RecordingRunner()
    var args = arguments(fixture)
    args += ["--force"]
    args[5] = fixture.live.appendingPathComponent("aot").path  // the value of --scratch
    #expect(args[4] == "--scratch")
    let result = run(args, runner: runner)
    #expect(result.status == 2)
    #expect(result.err.contains("refused"))
    #expect(runner.count == 0)
  }

  @Test func aFailedRunExitsThree() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let result = run(arguments(fixture), runner: RecordingRunner(failure: .io("timed out")))
    #expect(result.status == 3)
    #expect(result.err.contains("timed out"))
  }

  @Test func aWineThatNeverStartedExitsThree() throws {
    let fixture = try WarmupFixture()
    defer { fixture.remove() }
    let result = run(arguments(fixture), runner: RecordingRunner(setsUpPrefix: false))
    #expect(result.status == 3)
    #expect(FileManager.default.fileExists(atPath: fixture.stampFile.path) == false)
  }
}
