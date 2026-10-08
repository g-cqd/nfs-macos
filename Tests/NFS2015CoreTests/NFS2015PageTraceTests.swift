import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015PageTraceTests {
  @Test
  func `reads every trace line the real runtime printed`() throws {
    let window = try #require(NFS2015PageTraceWindow.parse(PageFixtures.traceLines[0]))
    #expect(window == .init(start: 0x5000_0000, end: 0x5001_0000, process: "128"))
    let events = PageFixtures.traceLines.dropFirst().compactMap(NFS2015PageTraceEvent.parse)
    #expect(events.count == 8)
    #expect(
      events.map(\.operation) == [
        .allocate, .write, .flush, .protect, .flush, .free, .map, .unmap,
      ])
    let first = events[0]
    #expect(first.thread == 0x12C && first.address == 0x5000_0000 && first.size == 0x1000)
    #expect(first.protect == 4 && first.oldProtect == 0x3000 && first.status == 0)
    #expect(first.caller == 0x6FFF_FF54_555A && first.checksum == nil)
    #expect(events[1].checksum == 0xFFA3_AE7F && events[2].checksum == 0xFFA3_AE7F)
    #expect(events[3].protect == 0x20 && events[3].oldProtect == 4)
    #expect(
      events[1].reportLine
        == "write tid=12c addr=0x50000000 size=0x6 prot=0x0 old=0x0 status=0x0 ret=0x6fffff549cdf fnv=ffa3ae7f"
    )
    #expect(NFS2015PageTraceEvent.parse(PageFixtures.traceLines[0]) == nil)
  }

  @Test
  func `accepts every operation the runtime names, and no other`() {
    for operation in NFS2015PageTraceEvent.Operation.allCases {
      let line =
        "wine-trace: op=\(operation.rawValue) tid=1 addr=1b30000 size=1000 prot=40 old=4 status=0 ret=1"
      #expect(NFS2015PageTraceEvent.parse(line)?.operation == operation)
    }
    #expect(NFS2015PageTraceEvent.Operation.allCases.count == 8)
    let other = "wine-trace: op=password tid=1 addr=1 size=1 prot=1 old=1 status=0 ret=1"
    #expect(NFS2015PageTraceEvent.parse(other) == nil)
  }

  @Test(arguments: [
    "", "wine-trace: ", "wine-trace: op=alloc", "something wine-trace: op=alloc tid=1",
    "wine-trace: op=alloc tid=zz addr=1 size=1 prot=1 old=1 status=0 ret=1",
    "wine-trace: op=alloc tid=1 addr=11111111111111111 size=1 prot=1 old=1 status=0 ret=1",
    "wine-trace: op=alloc tid=1 addr=1 size=1 prot=1 old=1 status=0",
    "wine-trace: op=alloc tid=123456789 addr=1 size=1 prot=1 old=1 status=0 ret=1",
    "wine-trace: op=alloc tid=1 addr= size=1 prot=1 old=1 status=0 ret=1",
    " fnv=ffa3ae7f", "wine-trace: window=1-2 pid=1",
  ])
  func `drops a line that is not a whole trace line`(line: String) {
    #expect(NFS2015PageTraceEvent.parse(line) == nil)
  }

  @Test
  func `ignores a field it does not know and keeps the first of a repeated one`() throws {
    let line =
      "wine-trace: op=flush tid=1 addr=10 size=2 prot=0 old=0 status=0 ret=5 extra=whatever tid=9"
    let event = try #require(NFS2015PageTraceEvent.parse(line))
    #expect(event.thread == 1 && event.operation == .flush)
  }

  @Test(arguments: [
    "wine-trace: window=zz-2 pid=1", "wine-trace: window=1 pid=1", "wine-trace: window=1-2",
    "wine-trace: window=1-2 pid=", "wine-trace: window=1-2 pid=123456789",
    "wine-trace: window=1-2-3 pid=1", "wine-trace: window=1-2 tid=1",
  ])
  func `drops a window line that is not whole`(line: String) {
    #expect(NFS2015PageTraceWindow.parse(line) == nil)
  }

  private func event(_ index: Int) -> String {
    "wine-trace: op=write tid=1 addr=\(String(0x1B3_0000 + index, radix: 16)) size=8 prot=0 old=0 status=0 ret=1"
  }

  @Test
  func `keeps the newest two hundred events before the fault and counts the rest`() {
    var trace = NFS2015PageTrace()
    trace.read("wine-trace: window=1b30000-1b31000 pid=a")
    for index in 0..<750 { trace.read(event(index)) }
    trace.markFault()
    for index in 750..<760 { trace.read(event(index)) }
    #expect(trace.total == 760 && trace.totalBeforeLastFault == 750)
    #expect(trace.retainedCount <= 2 * NFS2015PageTrace.keepLimit)
    #expect(trace.beforeLastFault.count == NFS2015PageTrace.keepLimit)
    #expect(trace.beforeLastFault.first?.address == 0x1B3_0000 + 550)
    #expect(trace.beforeLastFault.last?.address == 0x1B3_0000 + 749)
    #expect(trace.droppedBeforeLastFault == 550 && trace.afterLastFault == 10)
    #expect(trace.windows == [.init(start: 0x1B3_0000, end: 0x1B3_1000, process: "a")])
  }

  @Test
  func `freezes again at a later fault, and shows fewer than two hundred when there are fewer`() {
    var trace = NFS2015PageTrace()
    for index in 0..<5 { trace.read(event(index)) }
    trace.markFault()
    #expect(trace.beforeLastFault.count == 5 && trace.droppedBeforeLastFault == 0)
    for index in 5..<8 { trace.read(event(index)) }
    trace.markFault()
    #expect(trace.beforeLastFault.count == 8 && trace.afterLastFault == 0)
  }

  @Test
  func `repeats of one window collapse, and at most eight windows are kept`() {
    var trace = NFS2015PageTrace()
    for _ in 0..<3 { trace.read("wine-trace: window=1-2 pid=1") }
    #expect(trace.windows.count == 1)
    for pid in 2..<20 { trace.read("wine-trace: window=1-2 pid=\(pid)") }
    #expect(trace.windows.count == 8)
  }

  @Test
  func `an empty trace is empty, and a fault alone makes no events`() {
    var trace = NFS2015PageTrace()
    #expect(trace.isEmpty)
    trace.markFault()
    #expect(trace.beforeLastFault.isEmpty && trace.total == 0)
  }
}

struct NFS2015PageTraceInReportTests {
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

  private func log(events: Int, after: Int = 0) -> String {
    var lines = ["compatdb: NFS16.exe [x86_64]", "wine-trace: window=1b30000-1b31000 pid=2c"]
    for index in 0..<events {
      lines.append(
        "wine-trace: op=protect tid=3 addr=\(String(0x1B3_0000 + index, radix: 16)) size=1000 prot=40 old=4 status=0 ret=\(String(0x1000 + index, radix: 16))"
      )
    }
    lines.append(fault)
    for index in 0..<after {
      lines.append(
        "wine-trace: op=free tid=3 addr=1b30000 size=0 prot=0 old=8000 status=\(index) ret=1")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  @Test
  func
    `puts the newest two hundred events before the fault in a section of numbers, and says what was dropped`()
    throws
  {
    let text = try report(log(events: 450, after: 3))
    #expect(text.contains("== Page trace (wine-trace lines) =="))
    #expect(text.contains("window 0x1b30000 to 0x1b31000, announced by process 2c"))
    #expect(
      text.contains(
        "450 events before the last fault: the newest 200 are shown, 250 earlier dropped; 3 came after the fault"
      ))
    let rows = text.components(separatedBy: "\n").filter { $0.hasPrefix("  protect tid=3") }
    #expect(rows.count == 200)
    #expect(
      rows.first
        == "  protect tid=3 addr=0x1b300fa size=0x1000 prot=0x40 old=0x4 status=0x0 ret=0x10fa")
    #expect(rows.last?.hasSuffix("ret=0x11c1") == true)
    #expect(!text.contains("op=free"))
    // The section is last, so a report cut at its size limit loses it before anything else.
    let sections = text.components(separatedBy: "\n").filter { $0.hasPrefix("== ") }
    #expect(sections.last == "== Page trace (wine-trace lines) ==")
  }

  @Test
  func `says so when there is nothing before the fault`() throws {
    let text = try report(
      "compatdb: NFS16.exe [x86_64]\n" + fault
        + "\nwine-trace: op=free tid=3 addr=1b30000 size=0 prot=0 old=8000 status=0 ret=1\n")
    #expect(text.contains("no event before the last fault; 1 after it"))
  }

  @Test
  func `a log with no trace lines gives no section, unless the switch was set`() throws {
    let plain = try report(CrashFixtures.log)
    #expect(!plain.contains("Page trace") && !plain.contains("wine-trace"))
    let switches = NFS2015WineExperimentsChoice(
      preference: .init(tracePage: true), experiment: NFS2015ExperimentOverrides())
    let set = try report(CrashFixtures.log, switches: switches)
    #expect(
      set.contains("WINE_TRACE_PAGE was set for this launch, and the log holds no wine-trace line"))
  }

  @Test
  func
    `reading in pieces gives what reading the whole log gives, and trace lines are not diagnostic context`()
  {
    let whole = log(events: 30, after: 2)
    var chunked = NFS2015LogDigest()
    var index = whole.startIndex
    while index < whole.endIndex {
      let end = whole.index(index, offsetBy: 41, limitedBy: whole.endIndex) ?? whole.endIndex
      chunked.feed(String(whole[index..<end]))
      index = end
    }
    chunked.finish()
    #expect(chunked == NFS2015LogDigest(log: whole))
    #expect(chunked.pageTrace.totalBeforeLastFault == 30 && chunked.pageTrace.afterLastFault == 2)
    #expect(chunked.context.allSatisfy { !$0.contains("wine-trace") })
  }

  @Test
  func `text that is not numbers never reaches the report through a trace line`() throws {
    let hostile = [
      "wine-trace: op=alloc tid=1 addr=1b30000 size=1000 prot=4 old=0 status=0 ret=1 note=/Users/someone/secret",
      "wine-trace: op=alloc tid=1 addr=authToken size=1 prot=1 old=1 status=0 ret=1",
      "wine-trace: window=1-2 pid=1 name=someone@example.com",
    ].joined(separator: "\n")
    let text = try report(hostile + "\n" + fault + "\n")
    #expect(!text.contains("someone") && !text.contains("secret") && !text.contains("authToken"))
    #expect(text.contains("alloc tid=1 addr=0x1b30000"))
  }
}
