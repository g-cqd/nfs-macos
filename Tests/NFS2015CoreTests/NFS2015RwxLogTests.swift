import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015RwxLogTests {
  /// Captured from the real runtime (`runtime/wine-0008`, 2026-10-08) running the probe
  /// `exec-page-stale.exe` with `WINE_RWX_WX_EMULATION=1`. A test program, not the game.
  static let realLines = [
    "wine-rwx: active pid=80026 first page 0x50000000",
    "wine-rwx: pid=80026 stores=750 released(host=0 carrier=0 hot=0)",
  ]

  private func read(_ lines: [String]) -> NFS2015RwxLog {
    var log = NFS2015RwxLog()
    for line in lines { log.read(line) }
    return log
  }

  @Test
  func `reads the two lines the real runtime printed`() {
    let log = read(Self.realLines)
    #expect(log.activations == [.init(process: 80026, firstPage: 0x5000_0000)])
    #expect(
      log.counters == [
        .init(process: 80026, stores: 750, releasedHost: 0, releasedCarrier: 0, releasedHot: 0)
      ])
    #expect(log.lines == 2 && log.totalStores == 750 && log.totalReleased == 0)
    #expect(
      log.summary
        == "RWX W^X emulation: 1 process reported active, 1 reported counters: 750 stores through, 0 pages released."
    )
  }

  @Test
  func
    `reads lines Wine's own processes printed in a first start of the -0008 app with the switch saved`()
  {
    // Captured 2026-10-08 from the Bundled app's own session helper (first start, private folder,
    // WINE_RWX_WX_EMULATION=1 saved): eight processes became active, one printed its exit counters.
    let log = read([
      "wine-rwx: active pid=85250 first page 0x800000",
      "wine-rwx: active pid=86726 first page 0x800000",
      "wine-rwx: pid=86726 stores=300 released(host=0 carrier=0 hot=1)",
      "wine-rwx: active pid=86768 first page 0x800000",
      "wine-rwx: active pid=86889 first page 0x800000",
      "wine-rwx: active pid=87117 first page 0x800000",
      "wine-rwx: active pid=87212 first page 0x800000",
      "wine-rwx: active pid=87576 first page 0x800000",
      "wine-rwx: active pid=87684 first page 0x800000",
    ])
    #expect(log.activations.count == 8 && log.counters.count == 1)
    #expect(log.activations.allSatisfy { $0.firstPage == 0x80_0000 })
    #expect(
      log.counters == [
        .init(process: 86726, stores: 300, releasedHost: 0, releasedCarrier: 0, releasedHot: 1)
      ])
    #expect(log.hotReleasedProcesses == 1 && log.totalStores == 300 && log.totalReleased == 1)
    #expect(
      log.summary
        == "RWX W^X emulation: 8 processes reported active, 1 reported counters: 300 stores through, 1 pages released (1 because they were written too often)."
    )
  }

  @Test
  func `reads the address with or without the 0x the runtime prints`() {
    #expect(
      read(["wine-rwx: active pid=1 first page 1b30000"]).activations
        == [.init(process: 1, firstPage: 0x1B3_0000)])
    #expect(
      read(["wine-rwx: active pid=1 first page 0x1B30000"]).activations
        == [.init(process: 1, firstPage: 0x1B3_0000)])
  }

  @Test
  func `adds up the counters of several processes and names pages released for being hot`() {
    let log = read([
      "wine-rwx: pid=10 stores=300 released(host=2 carrier=1 hot=1)",
      "wine-rwx: pid=11 stores=5 released(host=0 carrier=0 hot=0)",
      "wine-rwx: pid=11 stores=5 released(host=0 carrier=0 hot=0)",
    ])
    #expect(log.counters.count == 2)
    #expect(log.totalStores == 305 && log.totalReleased == 4)
    #expect(log.hotReleasedProcesses == 1)
    #expect(log.summary?.contains("(1 because they were written too often)") == true)
  }

  @Test(arguments: [
    "", "wine-rwx: ", "wine-rwx: active", "wine-rwx: active pid=1 first page",
    "wine-rwx: active pid=x first page 0x1", "wine-rwx: active pid=1 first page 0xZZ",
    "wine-rwx: active pid=99999999999 first page 0x1", "wine-rwx: active pid=1 page 0x1 first",
    "wine-rwx: active pid=1 first page 0x1 note=/Users/someone",
    "wine-rwx: pid=1 stores=1 released(host=0 carrier=0)",
    "wine-rwx: pid=1 stores=1 released(host=0 carrier=0 hot=0",
    "wine-rwx: pid=1 stores=x released(host=0 carrier=0 hot=0)",
    "wine-rwx: pid=1 stores=1 released(host=-1 carrier=0 hot=0)",
    "wine-rwx: pid=1 stores=12345678901 released(host=0 carrier=0 hot=0)",
    "wine-rwx: pid=1 stores=1 released(host=0 carrier=0 hot=0) extra=1",
    "xwine-rwx: pid=1 stores=1 released(host=0 carrier=0 hot=0)",
    "wine-rwx: pid=1 stores=١ released(host=0 carrier=0 hot=0)",
  ])
  func `drops a line that is not whole, so text cannot get through`(line: String) {
    let log = read([line])
    #expect(log.isEmpty && log.summary == nil)
  }

  @Test
  func `bounds the lists and keeps counting`() {
    var lines: [String] = []
    for pid in 0..<40 {
      lines.append("wine-rwx: active pid=\(pid) first page 0x1000")
      lines.append("wine-rwx: pid=\(pid) stores=2 released(host=0 carrier=0 hot=0)")
    }
    let log = read(lines)
    #expect(log.activations.count == NFS2015RwxLog.listLimit)
    #expect(log.counters.count == NFS2015RwxLog.listLimit)
    #expect(log.lines == 80 && log.totalStores == 80)
  }

  @Test
  func `the digest collects the lines as the log grows, in pieces or whole`() {
    let text =
      "compatdb: NFS16.exe [x86_64]\n" + Self.realLines.joined(separator: "\n") + "\ninfo:  tail\n"
    var chunked = NFS2015LogDigest()
    var index = text.startIndex
    while index < text.endIndex {
      let end = text.index(index, offsetBy: 13, limitedBy: text.endIndex) ?? text.endIndex
      chunked.feed(String(text[index..<end]))
      index = end
    }
    chunked.finish()
    #expect(chunked == NFS2015LogDigest(log: text))
    #expect(chunked.rwx.lines == 2 && chunked.rwx.totalStores == 750)
    #expect(chunked.context.allSatisfy { !$0.contains("wine-rwx") })
    #expect(NFS2015LogDigest(log: CrashFixtures.log).rwx.isEmpty)
  }
}

struct NFS2015RwxInReportTests {
  private let fault = PageFixtures.realLines[0]

  private func report(_ log: String, switches: NFS2015WineExperimentsChoice = .standard) throws
    -> String
  {
    var context = CrashFixtures.context()
    context.wineSwitches = switches
    return try #require(
      NFS2015CrashReport(
        digest: NFS2015LogDigest(log: log), context: context, load: CrashFixtures.load,
        now: CrashFixtures.now)
    ).text
  }

  private var rwxOn: NFS2015WineExperimentsChoice {
    NFS2015WineExperimentsChoice(
      preference: .init(rwxWxEmulation: true), experiment: NFS2015ExperimentOverrides())
  }

  @Test
  func `puts the lines in a section of numbers, before the page trace`() throws {
    let log =
      "compatdb: NFS16.exe [x86_64]\n" + NFS2015RwxLogTests.realLines.joined(separator: "\n") + "\n"
      + fault + "\nwine-trace: op=free tid=3 addr=1b30000 size=0 prot=0 old=8000 status=0 ret=1\n"
    let text = try report(log, switches: rwxOn)
    #expect(text.contains("== RWX W^X emulation (wine-rwx lines) =="))
    #expect(text.contains("process 80026 had its first page under the emulation at 0x50000000"))
    #expect(
      text.contains(
        "process 80026 at exit: 750 stores let through; pages released: 0 after host-code faults, 0 for kernel writes, 0 for being written too often"
      ))
    let sections = text.components(separatedBy: "\n").filter { $0.hasPrefix("== ") }
    #expect(sections.last == "== Page trace (wine-trace lines) ==")
    #expect(sections.dropLast().last == "== RWX W^X emulation (wine-rwx lines) ==")
    #expect(!text.contains("<line removed"))
  }

  @Test
  func `says when a process was active and printed no exit line`() throws {
    let text = try report(
      "wine-rwx: active pid=7 first page 0x1B30000\n" + fault + "\n", switches: rwxOn)
    #expect(
      text.contains(
        "1 active and 0 exit lines are listed; a process that died does not print an exit line"))
  }

  @Test
  func `a log with no lines gives no section, unless the switch was set`() throws {
    let plain = try report(CrashFixtures.log)
    #expect(!plain.contains("RWX W^X") && !plain.contains("wine-rwx"))
    let set = try report(CrashFixtures.log, switches: rwxOn)
    #expect(
      set.contains(
        "WINE_RWX_WX_EMULATION was set for this launch, and the log holds no wine-rwx line"))
    func headings(_ text: String) -> [String] {
      text.components(separatedBy: "\n").filter { $0.hasPrefix("== ") }
    }
    #expect(headings(set).count == headings(plain).count + 1)
  }

  @Test
  func `text that is not numbers never reaches the report through a wine-rwx line`() throws {
    let hostile = [
      "wine-rwx: active pid=1 first page 0x1000 note=someone@example.com",
      "wine-rwx: pid=1 stores=1 released(host=0 carrier=0 hot=0) token=abc",
    ].joined(separator: "\n")
    let text = try report(hostile + "\n" + fault + "\n")
    #expect(!text.contains("someone") && !text.contains("token=abc") && !text.contains("wine-rwx"))
  }
}
