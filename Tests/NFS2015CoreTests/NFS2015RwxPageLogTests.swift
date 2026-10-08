import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015RwxPageLogTests {
  /// Captured from the real runtime (`runtime/wine-0010`, 2026-10-08) running the probe
  /// `exec-page-stale.exe` with `WINE_RWX_WX_EMULATION=1 WINE_RWX_WX_LOG=50000000-50010000`.
  /// A test program, not the game.
  static let realLines = [
    "wine-rwx: page 0x50000000 protect(reason=protect) vprot=0x27",
    "wine-rwx: active pid=12670 first page 0x50000000",
    "wine-rwx: page 0x50000000 store #1 rip=0x1400016f3 tid=0x164",
    "wine-rwx: page 0x50000000 store #2 rip=0x1400016f9 tid=0x164",
    "wine-rwx: page 0x50000000 store #3 rip=0x1400016ff tid=0x164",
    "wine-rwx: page 0x50000000 store #4 rip=0x1400016f3 tid=0x164",
    "wine-rwx: page 0x50000000 store #5 rip=0x1400016f9 tid=0x164",
    "wine-rwx: pid=12670 stores=450 released(host=0 carrier=0 hot=0)",
  ]

  /// Shapes the real capture does not show, written from the patch's format strings: no runtime
  /// printed these.
  static let extraLines = [
    "wine-rwx: page 0x1b30000 skipped(reason=notvalloc) vprot=0x40 via=alloc",
    "wine-rwx: page 0x1b30000 protect(reason=alloc) vprot=0x40",
    "wine-rwx: page 0x1b30000 store #1 rip=0x1b30146 tid=0x4c",
    "wine-rwx: page 0x1b30000 release(reason=hot-smc) stores=4096",
    "wine-rwx: page 0x1b30000 released state dropped after a protection change",
    "wine-rwx: page 0x1b30000 release(reason=tf) stores=7",
  ]

  private func read(_ lines: [String]) -> NFS2015RwxLog {
    var log = NFS2015RwxLog()
    for line in lines { log.read(line) }
    return log
  }

  @Test
  func `reads the page lines the real runtime printed, beside the process lines`() throws {
    let log = read(Self.realLines)
    #expect(log.activations.count == 1 && log.counters.count == 1)
    #expect(log.lines == 8 && log.pageLog.total == 6)
    #expect(
      log.pageLog.head.first
        == .protected(page: 0x5000_0000, reason: .protect, protection: 0x27))
    #expect(
      log.pageLog.head[1]
        == .store(page: 0x5000_0000, number: 1, instruction: 0x1_4000_16F3, thread: 0x164))
    let page = try #require(log.pageLog.pages.first)
    #expect(log.pageLog.pages.count == 1 && page.page == 0x5000_0000)
    #expect(page.protections == [.protect: 1] && page.releases.isEmpty)
    #expect(page.firstStores.map(\.number) == [1, 2, 3, 4, 5] && page.lastStoreNumber == 5)
    #expect(page.firstStores[2].instruction == 0x1_4000_16FF)
    #expect(log.totalStores == 450)
  }

  @Test
  func `reads every kind of line, with the reasons the runtime names`() throws {
    let log = read(Self.extraLines)
    #expect(
      log.pageLog.head == [
        .skipped(page: 0x1B3_0000, reason: .notVirtualAlloc, protection: 0x40, via: .allocation),
        .protected(page: 0x1B3_0000, reason: .allocation, protection: 0x40),
        .store(page: 0x1B3_0000, number: 1, instruction: 0x1B3_0146, thread: 0x4C),
        .released(page: 0x1B3_0000, reason: .hotSelfModifying, stores: 4096),
        .stateDropped(page: 0x1B3_0000),
        .released(page: 0x1B3_0000, reason: .trapFlag, stores: 7),
      ])
    let page = try #require(log.pageLog.pages.first)
    #expect(page.skips == [.notVirtualAlloc: 1] && page.protections == [.allocation: 1])
    #expect(page.releases == [.hotSelfModifying: 1, .trapFlag: 1] && page.droppedStates == 1)
    #expect(page.storesAtRelease == 7)
    for reason in NFS2015RwxPageLog.ReleaseReason.allCases {
      let line = "wine-rwx: page 0x1000 release(reason=\(reason.rawValue)) stores=1"
      #expect(read([line]).pageLog.total == 1, "\(reason)")
    }
    for reason in NFS2015RwxPageLog.SkipReason.allCases {
      let line = "wine-rwx: page 0x1000 skipped(reason=\(reason.rawValue)) vprot=0x4 via=other"
      #expect(read([line]).pageLog.total == 1, "\(reason)")
    }
    for reason in NFS2015RwxPageLog.ProtectReason.allCases {
      let line = "wine-rwx: page 0x1000 protect(reason=\(reason.rawValue)) vprot=0x0"
      #expect(read([line]).pageLog.total == 1, "\(reason)")
    }
  }

  @Test(arguments: [
    "wine-rwx: page", "wine-rwx: page ", "wine-rwx: page zz protect(reason=alloc) vprot=0x40",
    "wine-rwx: page 0x1000 protect(reason=password) vprot=0x40",
    "wine-rwx: page 0x1000 protect(reason=alloc) vprot=0xZZ",
    "wine-rwx: page 0x1000 protect(reason=alloc)",
    "wine-rwx: page 0x1000 protect(reason=alloc) vprot=0x40 note=/Users/someone",
    "wine-rwx: page 0x1000 skipped(reason=flags) vprot=0x40 via=/Users/someone",
    "wine-rwx: page 0x1000 skipped(reason=flags) vprot=0x40",
    "wine-rwx: page 0x1000 store #x rip=0x1 tid=0x1",
    "wine-rwx: page 0x1000 store #1 rip=0x1",
    "wine-rwx: page 0x1000 store #12345678901 rip=0x1 tid=0x1",
    "wine-rwx: page 0x1000 release(reason=hot) stores=-1",
    "wine-rwx: page 0x1000 release(reason=hot) stores=99999999999",
    "wine-rwx: page 0x1000 release(reason=hot",
    "wine-rwx: page 0x1000 released state dropped after a protection change and more",
    "wine-rwx: page 0x1000 released state dropped",
    "wine-rwx: page 0x1000 something someone@example.com",
    "xwine-rwx: page 0x1000 protect(reason=alloc) vprot=0x40",
    "wine-rwx: page 0x1000 store #١ rip=0x1 tid=0x1",
  ])
  func `drops a line that is not whole, so text cannot get through`(line: String) {
    let log = read([line])
    #expect(log.isEmpty && log.pageLog.isEmpty)
  }

  @Test
  func `bounds what it keeps and keeps counting`() {
    var lines: [String] = []
    for index in 0..<300 {
      lines.append(
        "wine-rwx: page 0x1b30000 store #\(index + 1) rip=0x1b30146 tid=0x4c")
    }
    for page in 0..<40 {
      lines.append(
        "wine-rwx: page 0x\(String(0x1000 + page * 0x1000, radix: 16)) protect(reason=alloc) vprot=0x40"
      )
    }
    let log = read(lines).pageLog
    #expect(log.total == 340)
    #expect(log.head.count == NFS2015RwxPageLog.headLimit)
    #expect(log.newest.count == NFS2015RwxPageLog.tailLimit)
    #expect(log.dropped == 340 - NFS2015RwxPageLog.headLimit - NFS2015RwxPageLog.tailLimit)
    #expect(log.pages.count == NFS2015RwxPageLog.pageLimit)
    #expect(log.pages[0].lastStoreNumber == 300 && log.pages[0].firstStores.count == 5)
  }

  @Test
  func `a store line read twice is listed once among the first stores`() throws {
    let line = "wine-rwx: page 0x1b30000 store #1 rip=0x1b30146 tid=0x4c"
    let page = try #require(read([line, line]).pageLog.pages.first)
    #expect(page.firstStores.count == 1)
  }

  @Test
  func `the session summary adds the page log only when there is one`() {
    let process = read(NFS2015RwxLogTests.realLines.filter { !$0.contains(" page ") })
    #expect(process.summary?.contains("Page log") == false)
    let with = read(Self.realLines + Self.extraLines)
    #expect(
      with.summary?.hasSuffix(
        " Page log: 12 lines about 2 pages, 2 protected, 2 released.")
        == true)
    #expect(
      read(["wine-rwx: page 0x1000 protect(reason=other) vprot=0x40"]).summary
        == "RWX W^X emulation: 0 processes reported active, 0 reported counters. Page log: 1 line about 1 page, 1 protected, 0 released."
    )
  }
}

struct NFS2015RwxPageLogReportTests {
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

  @Test
  func `puts a summary per page and the events in the order read into the section`() throws {
    let log =
      "compatdb: NFS16.exe [x86_64]\n"
      + (NFS2015RwxPageLogTests.extraLines + NFS2015RwxPageLogTests.realLines).joined(
        separator: "\n")
      + "\n" + fault + "\n"
    let text = try report(log)
    #expect(text.contains("== RWX W^X emulation (wine-rwx lines) =="))
    #expect(text.contains("page history, 12 lines"))
    #expect(
      text.contains(
        "  page 0x1b30000: protected alloc 1; left alone: notvalloc 1; released: hot-smc 1, tf 1; released state dropped 1 time"
      ))
    #expect(text.contains("    first stores (of 1 printed): #1 from 0x1b30146"))
    #expect(text.contains("    stores counted at the last release: 7"))
    #expect(text.contains("    left alone 0x1b30000: notvalloc, protection 0x40, found via alloc"))
    #expect(text.contains("    released 0x1b30000: hot-smc after 4096 stores"))
    #expect(text.contains("    store #1 into 0x1b30000 by the instruction at 0x1b30146, thread 4c"))
    #expect(text.contains("    0x1b30000: released state dropped after a protection change"))
    #expect(text.contains("process 12670 at exit: 450 stores let through"))
    #expect(!text.contains("<line removed"))
    let rows = text.components(separatedBy: "\n").filter { $0.hasPrefix("    ") }
    #expect(!rows.isEmpty)
  }

  @Test
  func `says how many events are not shown when there are many`() throws {
    var lines: [String] = ["compatdb: NFS16.exe [x86_64]"]
    for index in 0..<100 {
      lines.append("wine-rwx: page 0x1b30000 store #\(index + 1) rip=0x1b30146 tid=0x4c")
    }
    lines.append(fault)
    let text = try report(lines.joined(separator: "\n") + "\n")
    #expect(text.contains("… 52 events not shown …"))
    #expect(text.contains("    store #100 into 0x1b30000"))
    #expect(text.contains("    store #1 into 0x1b30000"))
    #expect(!text.contains("    store #40 into 0x1b30000"))
  }

  @Test
  func `the default window with no page line says that no page of it was touched`() throws {
    let text = try report(
      NFS2015RwxLogTests.realLines.filter { !$0.contains(" page ") }.joined(separator: "\n") + "\n"
        + fault + "\n")
    #expect(
      text.contains(
        "WINE_RWX_WX_LOG was set to 1B30000-1B31000 and the log holds no page line: no page of that window was taken over, left alone or released in a process whose lines reached this log"
      ))
    let off = try report(
      NFS2015RwxLogTests.realLines.filter { !$0.contains(" page ") }.joined(separator: "\n") + "\n"
        + fault + "\n", switches: .allOff)
    #expect(!off.contains("WINE_RWX_WX_LOG was set to"))
  }

  @Test
  func `a log without page lines adds nothing to the section`() throws {
    let process = NFS2015RwxLogTests.realLines.filter { !$0.contains(" page ") }
    let text = try report(process.joined(separator: "\n") + "\n" + fault + "\n", switches: .allOff)
    #expect(!text.contains("page history"))
    #expect(text.contains("process 80026 at exit") || text.contains("process 12670"))
  }

  @Test
  func `text that is not numbers never reaches the report through a page line`() throws {
    let hostile = [
      "wine-rwx: page 0x1000 protect(reason=alloc) vprot=0x40 token=abc",
      "wine-rwx: page 0x1000 skipped(reason=flags) vprot=0x40 via=/Users/someone/secret",
      "wine-rwx: page 0x1000 store #1 rip=0x1 tid=0x1 someone@example.com",
    ].joined(separator: "\n")
    let text = try report(hostile + "\n" + fault + "\n")
    #expect(!text.contains("someone") && !text.contains("token=abc") && !text.contains("secret"))
    #expect(!text.contains("page history"))
  }

  @Test
  func
    `the digest reads page lines in pieces as it does whole, and keeps them out of the context lines`()
  {
    let text =
      "compatdb: NFS16.exe [x86_64]\n" + NFS2015RwxPageLogTests.extraLines.joined(separator: "\n")
      + "\ninfo:  tail\n"
    var chunked = NFS2015LogDigest()
    var index = text.startIndex
    while index < text.endIndex {
      let end = text.index(index, offsetBy: 17, limitedBy: text.endIndex) ?? text.endIndex
      chunked.feed(String(text[index..<end]))
      index = end
    }
    chunked.finish()
    #expect(chunked == NFS2015LogDigest(log: text))
    #expect(chunked.rwx.pageLog.total == 6)
    #expect(chunked.context.allSatisfy { !$0.contains("wine-rwx") })
  }
}
