import Foundation
import Testing

@testable import NFS2015Core

/// Fixtures for the `wine-crash:` block of a runtime with patch 0005.
enum CrashBlockFixtures {
  /// Captured from the real runtime (`runtime/wine-0005`, 2026-10-08) running the patch's own
  /// fixture program `crash-context.exe`, which writes through a non-canonical pointer. It is a
  /// test program, not the game: the numbers are the fixture's, the format is the runtime's.
  static let realLines = """
    wine: Unhandled page fault on write access to 85BC35850173FF31 at address 000000014000166F (thread 016c), starting debugger...
    wine-crash: begin pid=0168 tid=016c code=c0000005 flags=00000000 address=000000014000166F
    wine-crash: access=1 target=85BC35850173FF31
    wine-crash: rip=000000014000166F rsp=000000000031FC60 rbp=0000000000000002 eflags=00000246 mxcsr=00001f80
    wine-crash: rax=1111111111111111 rbx=2222222222222222 rcx=85BC35850173FF31 rdx=3333333333333333
    wine-crash: rsi=4444444444444444 rdi=5555555555555555 r8=0808080808080808 r9=0909090909090909
    wine-crash: r10=1010101010101010 r11=1111000011110000 r12=1212121212121212 r13=1313131313131313
    wine-crash: r14=1414141414141414 r15=1515151515151515 cs=002b ss=0023 ds=0023 es=0023 fs=0000 gs=0023
    wine-crash: pc 000000014000166F state=1000 protect=20 type=1000000 region=0000000140001000+0000000000002000 module=crash-context.exe
    wine-crash: pc-bytes[16]=48 89 01 ff 15 28 6c 00 00 89 c2 48 8d 0d 90 29 
    wine-crash: target 85BC35850173FF31 not queryable (non-canonical or outside the address space)
    wine-crash: stack[000000000031FC60]: 0000000000000000 0000000000000000 0000000000000000 0000000000000000 000000000031FCF0 0000000000000000 000000000003BD98 0000000000000000
    wine-crash: tf state=0 guest_flags=0 steps=0
    wine-crash: end
    """.split(separator: "\n").map(String.init)

  /// The block alone, without the `wine: Unhandled page fault` line before it.
  static var block: [String] { Array(realLines.dropFirst()) }

  /// The 32-bit form, written from the format strings of the patch (`eip`, `esp`, no `mxcsr`,
  /// no trap-flag line): no 32-bit program has been run on the runtime for this fixture.
  static let i386Lines = [
    "wine-crash: begin pid=0044 tid=0048 code=c0000005 flags=00000000 address=00401234",
    "wine-crash: access=0 target=00000010",
    "wine-crash: eip=00401234 esp=0019FF40 ebp=0019FF58 eflags=00010246",
    "wine-crash: eax=00000000 ebx=7FFDF000 ecx=00000010 edx=00000001 esi=00000002 edi=00000003",
    "wine-crash: cs=0023 ss=002B ds=002B es=002B fs=0053 gs=002B",
    "wine-crash: pc 00401234 state=1000 protect=20 type=1000000 region=00401000+00002000 module=game32.exe",
    "wine-crash: pc-bytes[3]=8b 01 c3 ",
    "wine-crash: target 00000010 state=10000 protect=1 type=0 region=00000000+00010000 module=none",
    "wine-crash: stack[0019FF40]: 00000000 00401250 0019FF58 00000001",
    "wine-crash: end",
  ]

  static func block(replacing prefix: String, with line: String) -> [String] {
    block.map { $0.hasPrefix("wine-crash: " + prefix) ? line : $0 }
  }
}

struct NFS2015CrashBlockTests {
  private func parse(_ lines: [String]) throws -> NFS2015CrashBlock {
    try #require(NFS2015CrashBlock(lines: lines))
  }

  @Test
  func `reads every part of the block the real runtime printed`() throws {
    let block = try parse(CrashBlockFixtures.block)
    #expect(block.architecture == .amd64 && block.isComplete)
    #expect(block.process == "0168" && block.thread == "016c")
    #expect(block.code == 0xC000_0005 && block.flags == 0 && block.address == 0x1_4000_166F)
    #expect(block.access == 1 && block.target == 0x85BC_3585_0173_FF31)
    let names = block.registers.map(\.name)
    #expect(
      names == [
        "rip", "rsp", "rbp", "eflags", "mxcsr", "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8",
        "r9", "r10", "r11", "r12", "r13", "r14", "r15", "cs", "ss", "ds", "es", "fs", "gs",
      ])
    let values = Dictionary(uniqueKeysWithValues: block.registers.map { ($0.name, $0.value) })
    #expect(values["rcx"] == 0x85BC_3585_0173_FF31 && values["rax"] == 0x1111_1111_1111_1111)
    #expect(values["r11"] == 0x1111_0000_1111_0000 && values["mxcsr"] == 0x1F80)
    #expect(values["cs"] == 0x2B && values["fs"] == 0)
    #expect(
      block.pc
        == .region(
          .init(
            state: 0x1000, protect: 0x20, type: 0x100_0000, base: 0x1_4000_1000, size: 0x2000,
            module: "crash-context.exe")))
    #expect(block.targetProbe == .notQueryable)
    #expect(
      block.pcBytes == [
        0x48, 0x89, 0x01, 0xFF, 0x15, 0x28, 0x6C, 0x00, 0x00, 0x89, 0xC2, 0x48, 0x8D, 0x0D, 0x90,
        0x29,
      ])
    #expect(block.stackAddress == 0x31_FC60 && block.stack.count == 8)
    #expect(block.stack[4] == 0x31_FCF0)
    #expect(
      block.traceFlag?.state == 0 && block.traceFlag?.guestFlags == 0 && block.traceFlag?.steps == 0
    )
  }

  @Test
  func `reads the 32-bit form with eip and esp`() throws {
    let block = try parse(CrashBlockFixtures.i386Lines)
    #expect(block.architecture == .i386 && block.isComplete)
    #expect(block.address == 0x0040_1234 && block.access == 0 && block.target == 0x10)
    #expect(block.registers.first?.name == "eip" && block.registers.contains { $0.name == "esp" })
    #expect(block.registers.contains { $0.name == "edi" && $0.value == 3 })
    #expect(block.pcBytes == [0x8B, 0x01, 0xC3])
    #expect(block.traceFlag == nil)
    guard case .region(let free)? = block.targetProbe else {
      Issue.record("the target probe was not a region")
      return
    }
    #expect(free.isFree && free.module == "none")
    #expect(block.reportLines[0].contains("i386") && block.reportLines[0].contains("0x00401234"))
    #expect(block.observations.contains("the target page is not mapped"))
    #expect(block.observations.contains("the instruction pointer is in module game32.exe"))
  }

  @Test
  func `says what the numbers show for the not queryable target of the real block`() throws {
    let block = try parse(CrashBlockFixtures.block)
    #expect(
      block.observations == [
        "Wine could not query the target page: the address is not in the process's address space",
        "the target address is the value of rcx",
        "the instruction pointer is in module crash-context.exe",
      ])
    let lines = block.reportLines
    #expect(
      lines[0] == "process 0168 thread 016c, x86_64, exception 0xC0000005 at 0x000000014000166F")
    #expect(lines[1] == "  write of 0x85BC35850173FF31")
    #expect(lines.contains("  target page: not queryable"))
    #expect(
      lines.contains(
        "  bytes at the instruction pointer: 48 89 01 FF 15 28 6C 00 00 89 C2 48 8D 0D 90 29"))
    #expect(
      lines.contains(
        "  rip=000000014000166F rsp=000000000031FC60 rbp=0000000000000002 eflags=00000246"))
    #expect(lines.last == "  - the instruction pointer is in module crash-context.exe")
  }

  @Test
  func `describes a target page by its protection and a pc page that is not executable`() throws {
    let readOnly = CrashBlockFixtures.block(
      replacing: "target",
      with:
        "wine-crash: target 85BC35850173FF31 state=1000 protect=2 type=20000 region=0000000140000000+0000000000001000 module=NFS16.exe"
    )
    #expect(
      try parse(readOnly).observations.contains(
        "the program wrote to a page that is not writable (protect 0x2)"))
    let data = CrashBlockFixtures.block(
      replacing: "pc ",
      with:
        "wine-crash: pc 000000014000166F state=1000 protect=4 type=20000 region=0000000140001000+0000000000002000 module=NFS16.exe"
    )
    #expect(
      try parse(data).observations.contains(
        "the instruction pointer is in a page that is not executable (protect 0x4)"))
    let guarded = CrashBlockFixtures.block(
      replacing: "target",
      with:
        "wine-crash: target 85BC35850173FF31 state=1000 protect=104 type=20000 region=0000000140000000+0000000000001000 module=none"
    )
    #expect(
      try parse(guarded).observations.contains(
        "the target page is a guard or no-access page (protect 0x104)"))
    let reserved = CrashBlockFixtures.block(
      replacing: "target",
      with:
        "wine-crash: target 85BC35850173FF31 state=2000 protect=0 type=20000 region=0000000140000000+0000000000001000 module=none"
    )
    #expect(
      try parse(reserved).observations.contains("the target page is reserved but not committed"))
  }

  @Test(arguments: [
    (UInt32(0x01), false), (0x02, false), (0x04, true), (0x08, true), (0x10, false), (0x20, false),
    (0x40, true), (0x80, true),
  ])
  func `tells a writable page from one that is not by the protection flags`(
    protect: UInt32, writable: Bool
  ) throws {
    let page = String(protect, radix: 16)
    let lines = CrashBlockFixtures.block(
      replacing: "target",
      with:
        "wine-crash: target 85BC35850173FF31 state=1000 protect=\(page) type=20000 region=0000000140000000+0000000000001000 module=NFS16.exe"
    )
    let observations = try parse(lines).observations
    let refused = observations.contains {
      $0.hasPrefix("the program wrote to a page that is not writable")
    }
    let guarded = observations.contains { $0.hasPrefix("the target page is a guard or no-access") }
    let allowed = observations.contains { $0.contains("allows the access") }
    #expect(allowed == writable)
    #expect(refused == (!writable && protect != 0x01))
    #expect(guarded == (protect == 0x01))
  }

  @Test
  func `keeps a block that was cut short, and says so`() throws {
    let cut = Array(CrashBlockFixtures.block.prefix(6))
    let block = try parse(cut)
    #expect(!block.isComplete && block.pc == nil && block.stack.isEmpty)
    #expect(block.reportLines[0].hasSuffix("(the block was cut short)"))
  }

  @Test
  func `ignores lines it does not know, and refuses a block with no usable begin line`() throws {
    var lines = CrashBlockFixtures.block
    lines.insert("wine-crash: something a later runtime adds x=1", at: 3)
    lines.insert("not a crash line", at: 2)
    #expect(try parse(lines) == parse(CrashBlockFixtures.block))
    for bad in [
      [], ["wine-crash: end"], ["wine-crash: begin pid=zz tid=1 code=c0000005 address=1"],
      ["wine-crash: begin pid=1 tid=2 code=c0000005"],
      ["wine-crash: begin pid=1 tid=2 code=c0000005 address=" + String(repeating: "F", count: 17)],
      ["wine-crash: begin pid=123456789 tid=2 code=c0000005 address=1"],
    ] {
      #expect(NFS2015CrashBlock(lines: bad) == nil, "\(bad)")
    }
  }

  @Test
  func `bounds what it keeps`() throws {
    var lines = CrashBlockFixtures.block
    lines[lines.count - 3] =
      "wine-crash: stack[000000000031FC60]:"
      + String(repeating: " 0000000000000001", count: 100)
    #expect(try parse(lines).stack.count == NFS2015CrashBlock.stackLimit)
    let long = String(repeating: "A", count: 500)
    let module = CrashBlockFixtures.block(
      replacing: "pc ",
      with:
        "wine-crash: pc 000000014000166F state=1000 protect=20 type=1000000 region=0000000140001000+0000000000002000 module=\(long)"
    )
    guard case .region(let region)? = try parse(module).pc else {
      Issue.record("no region")
      return
    }
    #expect(region.module.count == 64)
    let many = Array(repeating: "wine-crash: rax=1", count: 100)
    #expect(
      try parse([CrashBlockFixtures.block[0]] + many).registers.count
        < NFS2015CrashBlock.lineLimit)
  }
}

struct NFS2015CrashBlockReaderTests {
  private func read(_ lines: [String]) -> NFS2015CrashBlockReader {
    var reader = NFS2015CrashBlockReader()
    for line in lines { reader.read(line) }
    return reader
  }

  @Test
  func `collects a block between the fault line and the next output, leaving other lines alone`() {
    let reader = read(
      ["info:  before"] + CrashBlockFixtures.realLines + ["compatdb: winedbg.exe [x86_64]"])
    #expect(reader.blocks.count == 1 && !reader.isOpen)
    #expect(reader.blocks[0].isComplete)
  }

  @Test
  func `stays open until the end line, and closes a cut block when the next one begins`() {
    var reader = read(Array(CrashBlockFixtures.block.prefix(5)))
    #expect(reader.isOpen && reader.blocks.isEmpty)
    for line in CrashBlockFixtures.block { reader.read(line) }
    #expect(reader.blocks.count == 2 && !reader.isOpen)
    #expect(!reader.blocks[0].isComplete && reader.blocks[1].isComplete)
  }

  @Test
  func `output of other programs between the lines of a block does not end it`() {
    var lines = CrashBlockFixtures.block
    lines.insert("0188:err:ole:start_rpcss Failed to start RpcSs service", at: 4)
    lines.insert("info:  Setting display mode: 1920x1200@60", at: 9)
    #expect(read(lines).blocks.count == 1)
    #expect(read(lines).blocks[0].isComplete)
  }

  @Test
  func `finish keeps a block the log stopped in, and keeps at most eight`() {
    var reader = read(Array(CrashBlockFixtures.block.prefix(4)))
    reader.finish()
    #expect(reader.blocks.count == 1 && !reader.isOpen)
    let many = read(Array(repeating: CrashBlockFixtures.block, count: 12).flatMap { $0 })
    #expect(many.blocks.count == NFS2015CrashBlockReader.blockLimit)
  }

  @Test
  func `a block that never ends is closed at the line limit`() {
    let lines =
      [CrashBlockFixtures.block[0]]
      + Array(repeating: "wine-crash: rax=1", count: NFS2015CrashBlock.lineLimit + 40)
    let reader = read(lines)
    #expect(reader.blocks.count == 1 && !reader.isOpen)
  }
}

struct NFS2015CrashBlockInReportTests {
  private let fault = CrashBlockFixtures.realLines[0]

  private func digest(_ text: String) -> NFS2015LogDigest { NFS2015LogDigest(log: text) }

  private func report(_ log: String, expects: Bool = false) throws -> String {
    var context = CrashFixtures.context()
    if expects { context.pins.runtimeCapabilities = ["crashContextBlock"] }
    return try #require(
      NFS2015CrashReport(
        digest: digest(log), context: context, load: CrashFixtures.load, now: CrashFixtures.now)
    ).text
  }

  private var withBlock: String {
    "compatdb: NFS16.exe [x86_64]\n" + CrashBlockFixtures.realLines.joined(separator: "\n") + "\n"
  }

  @Test
  func `puts the block in the report with what it shows`() throws {
    let text = try report(withBlock)
    #expect(text.contains("== Crash context (wine-crash block) =="))
    #expect(text.contains("block 1 of 1: process 0168 thread 016c, x86_64, exception 0xC0000005"))
    #expect(text.contains("  target page: not queryable"))
    #expect(text.contains("  - the target address is the value of rcx"))
    #expect(text.contains("  trap-flag emulation: state 0, guest flags 0x0, steps 0"))
    #expect(!text.contains("<line removed"))
    #expect(!text.contains("/Users"))
  }

  @Test
  func `a log with no block adds nothing, and a block adds only its own section`() throws {
    let plain = try report(CrashFixtures.log)
    #expect(!plain.contains("Crash context") && !plain.contains("wine-crash"))
    #expect(!plain.contains("runtime capabilities"))
    let with = try report(
      CrashFixtures.log + CrashBlockFixtures.realLines.joined(separator: "\n") + "\n")
    func headings(_ text: String) -> [String] {
      text.components(separatedBy: "\n").filter { $0.hasPrefix("== ") }
    }
    #expect(
      headings(with).filter { $0 != "== Crash context (wine-crash block) ==" } == headings(plain))
    #expect(headings(with).count == headings(plain).count + 1)
  }

  @Test
  func `a runtime that should print the block but did not gets a line saying so`() throws {
    let text = try report(CrashFixtures.log, expects: true)
    #expect(text.contains("== Crash context (wine-crash block) =="))
    #expect(text.contains("none was found in the log"))
    #expect(text.contains("runtime capabilities: crashContextBlock"))
  }

  @Test
  func `drops a block line that mentions a credential word, like any other line`() throws {
    var lines = CrashBlockFixtures.realLines
    lines[8] =
      "wine-crash: pc 000000014000166F state=1000 protect=20 type=1000000 region=0000000140001000+0000000000002000 module=login.dll"
    let text = try report("compatdb: NFS16.exe [x86_64]\n" + lines.joined(separator: "\n") + "\n")
    #expect(text.contains("<line removed: it mentions a credential-related word>"))
    #expect(!text.contains("login.dll"))
  }

  @Test
  func `reading in pieces gives the blocks reading the whole log gives`() {
    let log = withBlock + "info:  tail\n"
    var chunked = NFS2015LogDigest()
    var index = log.startIndex
    while index < log.endIndex {
      let end = log.index(index, offsetBy: 37, limitedBy: log.endIndex) ?? log.endIndex
      chunked.feed(String(log[index..<end]))
      index = end
    }
    chunked.finish()
    #expect(chunked.crashBlocks.count == 1 && chunked == digest(log))
    #expect(!chunked.hasOpenCrashBlock)
    #expect(digest(CrashFixtures.log).crashBlocks.isEmpty)
  }

  @Test
  func `a log that ends inside a block keeps the block when reading finishes`() {
    let cut = CrashBlockFixtures.realLines.prefix(5).joined(separator: "\n")
    var value = NFS2015LogDigest()
    value.feed(cut)
    #expect(value.crashBlocks.isEmpty)
    value.finish()
    #expect(value.crashBlocks.count == 1 && !value.hasOpenCrashBlock)
    #expect(value.crashBlocks[0].isComplete == false)
  }

  @Test
  func `a block does not enter the diagnostic context lines`() {
    let value = digest(withBlock)
    #expect(value.context.allSatisfy { !$0.contains("wine-crash") })
    #expect(value.faults.count == 1)
  }
}
