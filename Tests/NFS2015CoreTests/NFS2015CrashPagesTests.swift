import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015CrashPagesTests {
  private func parse(_ lines: [String]) throws -> NFS2015CrashBlock {
    try #require(NFS2015CrashBlock(lines: lines))
  }

  @Test
  func `reads the page, checksum, thread, return and code lines the real runtime printed`() throws {
    let block = try parse(PageFixtures.block)
    #expect(block.isComplete && block.architecture == .amd64)
    let pages = block.pages
    #expect(pages.queries.map(\.page) == [0x1_4000_1000, 0x1_4000_0000, 0x1_4000_2000])
    let first = try #require(pages.queries[0].info)
    #expect(first.allocationBase == 0x1_4000_0000 && first.allocationProtect == 0x80)
    #expect(first.base == 0x1_4000_1000 && first.size == 0x2000)
    #expect(first.state == 0x1000 && first.protect == 0x20 && first.type == 0x100_0000)
    #expect(pages.queries[1].info?.protect == 0x2 && pages.queries[2].info?.size == 0x1000)
    #expect(
      pages.checksum == .init(page: 0x1_4000_1000, fnv1a64: 0x061B_710B_C5E5_A8E7, zeroGroups: 0))
    #expect(pages.threads == 1 && pages.teb == 0x7FFC_0000 && pages.hasThreadLine)
    #expect(pages.returns.map(\.slot) == [15, 17, 23, 35, 37, 39])
    #expect(
      pages.returns[0]
        == .init(slot: 15, address: 0x6FFF_FFC1_369A, module: "ntdll.dll", offset: 0x5369A))
    #expect(pages.returns[2].module == "kernel32.dll" && pages.returns[5].module == "ucrtbase.dll")
    let window = try #require(pages.windows.first)
    #expect(pages.windows.count == 1 && window.label == "pc")
    #expect(window.center == 0x1_4000_166F && window.before == 0x100 && window.after == 0x100)
    #expect(window.rows.count == 17 && window.rows[0].address == 0x1_4000_1560)
    #expect(window.rows.allSatisfy { $0.bytes.count == 32 } && window.unreadable.isEmpty)
    let row = try #require(window.rows.first { $0.address == 0x1_4000_1660 })
    #expect(
      Array(row.bytes[5..<17]) == [
        0x48, 0xB9, 0x31, 0xFF, 0x73, 0x01, 0x85, 0x35, 0xBC, 0x85, 0x48, 0x89,
      ])
    #expect(pages.near.isEmpty)
  }

  @Test
  func `reads the shapes the real capture does not show`() throws {
    let block = try parse(PageFixtures.richBlock)
    let pages = block.pages
    #expect(pages.queries.count == 4 && pages.queries[3] == .init(page: 0x1B3_1000, info: nil))
    #expect(pages.windows.map(\.label) == ["pc", "r12"])
    let register = pages.windows[1]
    #expect(register.center == 0x1B3_00E3 && register.before == 0x40 && register.after == 0x40)
    #expect(register.rows.count == 1 && register.rows[0].bytes.first == 0xA2)
    #expect(register.unreadable == [.init(start: 0x1B3_00C0, end: 0x1B3_00FF)])
    #expect(
      pages.near == [
        .init(register: "r12", delta: -0x76), .init(register: "rbp", delta: 0x10),
        .init(register: "rcx", delta: 0),
      ])
    let unknown = try parse([
      "wine-crash: begin pid=0044 tid=0048 code=c0000005 flags=00000000 address=00401234",
      "wine-crash: pagesum 0000000000401000 unreadable", "wine-crash: threads=? teb=7FFDF000",
      "wine-crash: ret[3]=00401250 game32.exe+0", "wine-crash: end",
    ]).pages
    #expect(unknown.checksum == .init(page: 0x401000, fnv1a64: nil, zeroGroups: nil))
    #expect(unknown.hasThreadLine && unknown.threads == nil && unknown.teb == 0x7FFD_F000)
    #expect(unknown.returns == [.init(slot: 3, address: 0x401250, module: "game32.exe", offset: 0)])
  }

  @Test
  func `puts the new lines in the report as plain hex, without decoding, and states facts`() throws
  {
    let lines = try parse(PageFixtures.richBlock).reportLines
    #expect(
      lines.contains { $0.hasPrefix("  page 0x0000000140001000: allocation 0x0000000140000000") })
    #expect(lines.contains("  page 0x0000000001B31000: not queryable"))
    #expect(
      lines.contains(
        "  page checksum 0x0000000140001000: FNV-1a 64 061B710BC5E5A8E7, all-zero 16-byte groups 0 of 256"
      ))
    #expect(lines.contains("  threads: 1, TEB 0x000000007FFC0000"))
    #expect(
      lines.contains(
        "  return address candidate [15]: 0x00006FFFFFC1369A ntdll.dll+0x5369A"))
    #expect(
      lines.contains("  registers near the instruction pointer: r12=pc-0x76 rbp=pc+0x10 rcx=pc+0x0")
    )
    #expect(
      lines.contains { $0.hasPrefix("  code window pc 0x000000014000166F, -0x100 to +0x100") })
    let row =
      "    0x0000000140001660: 1515151515" + "48B931FF73018535BC85"
      + "488901FF15286C000089C2488D0D9029"
      + "00"
    #expect(lines.contains(row))
    #expect(
      lines.contains("    0x0000000001B300C0..0x0000000001B300FF: unreadable"))
    let facts = lines.filter { $0.hasPrefix("  - ") }
    #expect(
      facts.contains(
        "  - the instruction pointer is in private memory that is both writable and executable (protect 0x40)"
      ))
    #expect(
      facts.contains(
        "  - 0 of 256 groups of 16 bytes in the instruction pointer's page are all zero"))
    #expect(facts.contains("  - register r12 is 0x76 below the instruction pointer"))
    #expect(facts.contains("  - register rbp is 0x10 above the instruction pointer"))
    #expect(facts.contains("  - register rcx is 0x0 at the instruction pointer"))
    #expect(facts.contains("  - the first return address candidate is in ntdll.dll"))
    #expect(facts.contains("  - the process had 1 thread"))
    // No mnemonic and no verdict: the report states numbers and restates what Wine printed.
    let text = lines.joined(separator: "\n").lowercased()
    for word in ["mov ", "denuvo", "self-modifying", "stale", "tamper"] {
      #expect(!text.contains(word), "\(word)")
    }
  }

  @Test
  func `ignores lines that do not parse, and rows that have no window`() throws {
    let lines = [
      "wine-crash: begin pid=0044 tid=0048 code=c0000005 flags=00000000 address=00401234",
      "wine-crash: code[0000000000401000]: 90 90 90",
      "wine-crash: vq[zz] alloc=1",
      "wine-crash: vq[1000] alloc=1 aprot=zz base=1 size=1 state=1 prot=1 type=1",
      "wine-crash: pagesum 1000 fnv1a64=zz zero16=0/256",
      "wine-crash: pagesum 1000 fnv1a64=1 zero16=999/256",
      "wine-crash: threads=lots teb=1", "wine-crash: ret[x]=1 a.dll+0x1",
      "wine-crash: ret[1]=1 nomodule",
      "wine-crash: window secret=0000000000401000 span=-10..+10",
      "wine-crash: code[0000000000401000]: 90 90 90",
      "wine-crash: window pc=0000000000401000 span=-zz..+10",
      "wine-crash: near-pc: rax=pc+0x1000 foo=pc+0x1 rbx=2+0x1 rcx=pc*0x1", "wine-crash: end",
    ]
    let pages = try parse(lines).pages
    #expect(pages.isEmpty)
  }

  @Test
  func `keeps a row after a window it did not keep out of the earlier window`() throws {
    var lines = ["wine-crash: begin pid=0044 tid=0048 code=c0000005 flags=0 address=401234"]
    for index in 0..<6 {
      lines.append("wine-crash: window rax=000000000040\(index)000 span=-10..+10")
      lines.append("wine-crash: code[000000000040\(index)000]: 90 90")
    }
    let pages = try parse(lines).pages
    #expect(pages.windows.count == NFS2015CrashPages.windowLimit)
    #expect(pages.windows.allSatisfy { $0.rows.count == 1 })
  }

  @Test
  func `bounds every list`() throws {
    var lines = ["wine-crash: begin pid=0044 tid=0048 code=c0000005 flags=0 address=401234"]
    lines += Array(
      repeating:
        "wine-crash: vq[1000] alloc=1000 aprot=40 base=1000 size=1000 state=1000 prot=40 type=20000",
      count: 10)
    lines += (0..<10).map { "wine-crash: ret[\($0)]=00401250 a.dll+0x10" }
    lines.append("wine-crash: window pc=0000000000401000 span=-1000..+1000")
    lines += Array(repeating: "wine-crash: code[0000000000401000]: 90 90", count: 40)
    lines += Array(repeating: "wine-crash: code[1000..1fff]: unreadable", count: 20)
    let pages = try parse(lines).pages
    #expect(pages.queries.count == NFS2015CrashPages.queryLimit)
    #expect(pages.returns.count == NFS2015CrashPages.returnLimit)
    #expect(pages.windows[0].rows.count == NFS2015CrashPages.rowLimit)
    #expect(pages.windows[0].unreadable.count == NFS2015CrashPages.unreadableLimit)
    let long = String(repeating: "m", count: 300)
    let module = try parse([lines[0], "wine-crash: ret[1]=00401250 \(long).dll+0x10"]).pages
    #expect(module.returns.first?.module.count == NFS2015CrashPages.moduleLimit)
  }

  @Test
  func
    `the reader keeps a whole block of about sixty lines and closes at one hundred and twenty-eight`()
  {
    var reader = NFS2015CrashBlockReader()
    for line in PageFixtures.richBlock { reader.read(line) }
    #expect(reader.blocks.count == 1 && reader.blocks[0].isComplete && !reader.isOpen)
    #expect(PageFixtures.richBlock.count > 24)
    var endless = NFS2015CrashBlockReader()
    endless.read(PageFixtures.block[0])
    for _ in 0..<200 { endless.read("wine-crash: rax=1") }
    #expect(endless.blocks.count == 1 && !endless.isOpen)
  }

  @Test
  func `a block from a runtime with patch 0005 only reads exactly as before`() throws {
    let old = try parse(CrashBlockFixtures.block)
    #expect(old.pages.isEmpty)
    #expect(!old.reportLines.contains { $0.contains("code window") || $0.contains("page 0x") })
  }
}
