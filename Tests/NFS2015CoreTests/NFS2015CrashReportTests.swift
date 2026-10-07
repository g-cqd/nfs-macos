import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015CrashReportTests {
  private func report(
    log: String = CrashFixtures.log, context: NFS2015CrashContext = CrashFixtures.context()
  ) throws -> NFS2015CrashReport {
    try #require(
      NFS2015CrashReport(
        digest: NFS2015LogDigest(log: log), context: context, load: CrashFixtures.load,
        now: CrashFixtures.now))
  }

  @Test
  func `has nothing to report for a log without a fault`() {
    let clean = "compatdb: NFS16.exe [x86_64]\ninfo:  Setting display mode: 1920x1200@60\n"
    #expect(
      NFS2015CrashReport(
        digest: NFS2015LogDigest(log: clean), context: CrashFixtures.context(),
        load: CrashFixtures.load, now: CrashFixtures.now) == nil)
  }

  @Test
  func `says what happened, where, and how many times`() throws {
    let report = try report()
    #expect(report.faultCount == 3)
    #expect(report.headline == "3 faults in 2 game launches; first at nfs16+0x341FB95")
    let text = report.text
    #expect(
      text.hasPrefix("Need for Speed (2015) on macOS: crash report\nwritten: 2026-10-03T04:00:00Z"))
    for part in [
      "== What happened ==",
      "wineserver reported a crash 1 time(s); game launches in this session: 2",
      "fault 1: thread 0fb0 at nfs16+0x341FB95",
      "read access to 0x73656C6369686556 (instruction pointer 0x14341FB95)",
      "the pointer's bytes spell the ASCII text \"Vehicles\"",
      "fault 2: thread 0688 at nfs16+0x47D1383",
      "null pointer read", "the same place, nfs16+0x341FB95, faulted 2 times in this session",
    ] { #expect(text.contains(part), "missing: \(part)") }
  }

  @Test
  func `names the display facts, the modes the game set and what the display rule decided`() throws
  {
    let text = try report().text
    for part in [
      "== Display ==",
      "main display: 1680x1050 points, 3360x2100 pixels (scale 2.00), native 2560x1600",
      "built-in", "display modes the game set: 3360x2100@60 x2, 1920x1200@60 x2",
      "display safety: limit retina desktop on, safe first resolution on",
      "RetinaMode recorded for this launch: Y", "desktop Wine advertises: 3360x2100",
      "first-run seed: No first-run resolution was seeded: the game's settings folder already holds files.",
    ] { #expect(text.contains(part), "missing: \(part)") }
  }

  @Test
  func `shows the failing 4K screen's facts and the decision made for it`() throws {
    let display = NFS2015DisplaySafetyTests.external4K
    let text = try report(context: CrashFixtures.context(display: display)).text
    #expect(
      text.contains(
        "main display: 3840x2160 points, 3840x2160 pixels (scale 1.00), native 3840x2160, external")
    )
    #expect(text.contains("Wine retina desktop would be 7680x4320"))
    #expect(text.contains("RetinaMode recorded for this launch: N"))
    #expect(
      try report(context: CrashFixtures.context(display: nil)).text.contains(
        "main display: could not be read"))
  }

  @Test
  func `names the renderer and runtime settings in force, and any experiment`() throws {
    var experiment = NFS2015ExperimentOverrides()
    experiment.sidecarOff = true
    experiment.tuning = ["WINE_TF_MAX_STEPS": "250000"]
    let text = try report(context: CrashFixtures.context(experiment: experiment, logging: true))
      .text
    for part in [
      "MetalFX: on, 1.5x for NFS16.exe",
      "diagnostic Wine log for this launch: err+all,fixme-all,+seh",
      "x87 sidecar: OFF (experiment)",
      "runtime switches in force: WINE_TF_EMULATION=1 WINE_TF_MAX_NS=0 WINE_TF_MAX_STEPS=0",
      "experiment overrides: x87 sidecar off, WINE_TF_MAX_STEPS=250000",
    ] { #expect(text.contains(part), "missing: \(part)") }
    let plain = try report().text
    #expect(plain.contains("diagnostic Wine log for this launch: off"))
    #expect(
      plain.contains("x87 sidecar: on (as shipped)") && plain.contains("experiment overrides: none")
    )
  }

  @Test
  func `names the build, the Mac, the game options and the load`() throws {
    let text = try report().text
    for part in [
      "app build: 20261003, game manifest 1-synthetic", "runtime profile: nfs2015-tf-cx11",
      "sources: mtld3d=7d108a4 x87sidecar=c396937",
      "x87 sidecar sha256: \(String(repeating: "ab12", count: 16))",
      "client layer sha256: \(String(repeating: "ef56", count: 16))",
      "runtime file bin/wine sha256 \(String(repeating: "cd34", count: 16))",
      "MacBookAir10,1, Apple M1, 16 GB, Version 27.2 (Build 99X1), 8 CPUs",
      "load average 3.50 2.25 1.00, swap 2.0 GB of 4.0 GB", "render.fullscreen 1",
      "render.resolution 1920x1200",
    ] { #expect(text.contains(part), "missing: \(part)") }
  }

  @Test
  func `says when the game had not written its options file`() throws {
    var context = CrashFixtures.context()
    context.settings = NFS2015Settings()
    #expect(
      try report(context: context).text.contains("none: the game had not written its options file"))
  }

  @Test
  func `carries no credential, identity or EA message into the report`() throws {
    let text = try report().text
    for secret in CrashFixtures.secrets { #expect(!text.contains(secret), "leaked \(secret)") }
    #expect(!text.contains("FIDO") && !text.contains("webauthn") && !text.contains("compatdb"))
    #expect(!text.contains("EALauncher") && !text.contains("EADesktop"))
  }

  @Test
  func
    `a credential word in any part of the report removes that line, and the user's name is masked`()
    throws
  {
    var context = CrashFixtures.context()
    context.pins.bundleVersion = "token-1"
    context.pins.runtimeProfile = "/Users/someone/profile"
    let text = try report(context: context).text
    #expect(!text.contains("token-1") && !text.contains("someone"))
    #expect(text.contains("<line removed: it mentions a credential-related word>"))
    #expect(text.contains("/Users/<user>/profile"))
  }

  @Test
  func `the trace of a diagnostic launch is added after the log lines`() throws {
    var digest = NFS2015LogDigest(log: CrashFixtures.log)
    digest.setTrace(
      fromText:
        "0001:trace:seh:dispatch_exception code=c0000005 addr=000000014341FB95\n0001:trace:seh:  rax=0000000000000001\n"
    )
    let text = try #require(
      NFS2015CrashReport(
        digest: digest, context: CrashFixtures.context(logging: true), load: CrashFixtures.load,
        now: CrashFixtures.now)
    ).text
    let log = try #require(text.range(of: "== Last diagnostic lines of the log =="))
    let trace = try #require(text.range(of: "== Last exception trace lines"))
    #expect(log.lowerBound < trace.lowerBound)
    #expect(
      text.contains("dispatch_exception code=c0000005") && text.contains("rax=0000000000000001"))
  }

  @Test
  func `is cut at its size limit`() throws {
    var context = CrashFixtures.context()
    context.pins.runtimeHashes = Dictionary(
      uniqueKeysWithValues: (0..<2_000).map { ("file-\($0)", String(repeating: "a1", count: 32)) })
    let text = try report(context: context).text
    #expect(text.utf8.count <= NFS2015CrashReport.sizeLimit + 8 && text.hasSuffix("[cut]\n"))
  }
}

struct NFS2015CrashReportStoreTests {
  private func sample() throws -> NFS2015CrashReport {
    try #require(
      NFS2015CrashReport(
        digest: NFS2015LogDigest(log: CrashFixtures.log), context: CrashFixtures.context(),
        load: CrashFixtures.load, now: CrashFixtures.now))
  }

  @Test
  func `writes crash-report files named by time, next to the logs`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015CrashReportStore(folder: scratch.url("Logs"))
    let url = try store.write(try sample(), stamp: "20261003T040000Z")
    #expect(url.lastPathComponent == "crash-report-20261003T040000Z.txt")
    #expect(try String(contentsOf: url, encoding: .utf8) == (try sample()).text)
    #expect(store.reports() == [url])
  }

  @Test
  func `never overwrites a report written in the same second, and keeps their order`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015CrashReportStore(folder: scratch.root)
    let first = try store.write(try sample(), stamp: "20261003T040000Z")
    let second = try store.write(try sample(), stamp: "20261003T040000Z")
    let third = try store.write(try sample(), stamp: "20261003T040000Z")
    #expect(second.lastPathComponent == "crash-report-20261003T040000Z-2.txt")
    #expect(store.reports() == [first, second, third])
  }

  @Test
  func `keeps only the newest reports`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015CrashReportStore(folder: scratch.root)
    for number in 0..<(NFS2015CrashReportStore.keep + 5) {
      _ = try store.write(try sample(), stamp: String(format: "20261003T0400%02dZ", number))
    }
    let names = store.reports().map(\.lastPathComponent)
    #expect(names.count == NFS2015CrashReportStore.keep)
    #expect(names.first == "crash-report-20261003T040005Z.txt")
    #expect(names.last == "crash-report-20261003T040024Z.txt")
  }

  @Test
  func `finds the newest report written since a time, with its headline`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015CrashReportStore(folder: scratch.root)
    #expect(store.latest(since: .distantPast) == nil)
    let url = try store.write(try sample(), stamp: "20261003T040000Z")
    let found = try #require(store.latest(since: Date(timeIntervalSinceNow: -60)))
    #expect(found.path == url.path)
    #expect(found.headline == "3 faults in 2 game launches; first at nfs16+0x341FB95")
    #expect(found.sentence.contains(url.path))
    #expect(store.latest(since: Date(timeIntervalSinceNow: 60)) == nil)
  }

  @Test
  func `reads the headline of any report, and has a fallback`() {
    #expect(
      NFS2015CrashReportStore.headline(of: "x\n== What happened ==\nline one\nline two")
        == "line one")
    #expect(NFS2015CrashReportStore.headline(of: "nothing") == "see the report")
  }

  @Test
  func `reports a folder it cannot write as an error`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    chmod(scratch.root.path, 0o500)
    defer { chmod(scratch.root.path, 0o755) }
    #expect(throws: (any Error).self) {
      try NFS2015CrashReportStore(folder: scratch.root).write(
        try sample(), stamp: "20261003T040000Z")
    }
  }
}
