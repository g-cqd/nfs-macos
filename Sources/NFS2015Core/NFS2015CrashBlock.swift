import Foundation

/// The `wine-crash:` lines that a runtime with patch 0005 prints from `UnhandledExceptionFilter`
/// when a Windows program dies of an unhandled exception, read back into one value.
///
/// The block holds the numbers Wine had at the fault: the exception, the registers, the bytes at
/// the instruction pointer, what the memory manager says about the instruction pointer and the
/// faulting address, eight words of stack and the trap-flag emulation counters. It holds no path,
/// no name and no account data: module names are the base names of loaded modules.
///
/// Reading is lenient and additive. Only `begin` is required; a line this reader does not know is
/// ignored, and a part the runtime did not print stays `nil`. A runtime without the patch prints
/// no block, and then nothing in this file runs.
package struct NFS2015CrashBlock: Equatable, Sendable {
  package enum Architecture: String, Equatable, Sendable {
    case amd64 = "x86_64"
    case i386
  }

  /// What `NtQueryVirtualMemory` reported for the page holding an address.
  package struct Region: Equatable, Sendable {
    package let state: UInt32
    package let protect: UInt32
    package let type: UInt32
    package let base: UInt64
    package let size: UInt64
    /// The base name of the module that owns the address, `none` when no module does.
    package let module: String

    package var isCommitted: Bool { state == 0x1000 }
    package var isFree: Bool { state == 0x10000 }
    /// `PAGE_READWRITE`, `PAGE_WRITECOPY` and the executable forms of both.
    package var isWritable: Bool { protect & 0xCC != 0 }
    /// `PAGE_EXECUTE` and the three executable forms of the others.
    package var isExecutable: Bool { protect & 0xF0 != 0 }
    package var isGuardOrNoAccess: Bool { protect & 0x101 != 0 }
  }

  /// What the block says about one address.
  package enum Probe: Equatable, Sendable {
    case region(Region)
    /// Wine could not query the address: non-canonical, or outside the address space.
    case notQueryable
  }

  package let architecture: Architecture
  package let process: String
  package let thread: String
  package let code: UInt32
  package let flags: UInt32
  package let address: UInt64
  /// 0 read, 1 write, 8 execute (data execution prevention), as in an access violation record.
  package let access: UInt64?
  package let target: UInt64?
  /// Register values in the order the runtime printed them, such as `("rax", 0x1111)`.
  package let registers: [(name: String, value: UInt64)]
  package let pc: Probe?
  package let targetProbe: Probe?
  package let pcBytes: [UInt8]?
  /// The runtime could not read the bytes at the instruction pointer.
  package let pcBytesUnreadable: Bool
  package let stack: [UInt64]
  package let stackAddress: UInt64?
  package let traceFlag: (state: UInt32, guestFlags: UInt32, steps: UInt64)?
  /// The `end` line was read. A block cut short by the process dying or by another block is kept.
  package let isComplete: Bool

  /// The registers the runtime prints; any other `name=value` pair is not a register.
  static let registerNames: Set<String> = [
    "rip", "rsp", "rbp", "eip", "esp", "ebp", "eflags", "mxcsr", "rax", "rbx", "rcx", "rdx", "rsi",
    "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "eax", "ebx", "ecx", "edx", "esi",
    "edi", "cs", "ss", "ds", "es", "fs", "gs",
  ]

  static let linePrefix = "wine-crash: "
  static let lineLimit = 24
  static let stackLimit = 16

  package static func == (left: Self, right: Self) -> Bool {
    left.architecture == right.architecture && left.process == right.process
      && left.thread == right.thread && left.code == right.code && left.flags == right.flags
      && left.address == right.address && left.access == right.access
      && left.target == right.target
      && left.registers.map(\.name) == right.registers.map(\.name)
      && left.registers.map(\.value) == right.registers.map(\.value) && left.pc == right.pc
      && left.targetProbe == right.targetProbe && left.pcBytes == right.pcBytes
      && left.pcBytesUnreadable == right.pcBytesUnreadable && left.stack == right.stack
      && left.stackAddress == right.stackAddress
      && left.traceFlag?.state == right.traceFlag?.state
      && left.traceFlag?.guestFlags == right.traceFlag?.guestFlags
      && left.traceFlag?.steps == right.traceFlag?.steps && left.isComplete == right.isComplete
  }

  /// Reads the lines of one block, with or without the closing `end` line.
  /// - Parameter lines: The block's lines, each with its `wine-crash: ` prefix.
  /// - Returns: nil when there is no readable `begin` line.
  package init?(lines: [String]) {
    var begin: [String: String]?
    var access: UInt64?
    var target: UInt64?
    var registers: [(name: String, value: UInt64)] = []
    var pc: Probe?
    var targetProbe: Probe?
    var pcBytes: [UInt8]?
    var unreadable = false
    var stack: [UInt64] = []
    var stackAddress: UInt64?
    var traceFlag: (state: UInt32, guestFlags: UInt32, steps: UInt64)?
    var complete = false
    var arch = Architecture.amd64
    for line in lines.prefix(Self.lineLimit) {
      guard line.hasPrefix(Self.linePrefix) else { continue }
      let body = line.dropFirst(Self.linePrefix.count)
      if body.hasPrefix("begin ") {
        if begin == nil { begin = Self.pairs(body.dropFirst(6)) }
      } else if body == "end" {
        complete = true
      } else if body.hasPrefix("access=") {
        let fields = Self.pairs(body)
        access = fields["access"].flatMap { UInt64($0) }
        target = fields["target"].flatMap { Self.hex($0) }
      } else if body.hasPrefix("pc-bytes[") {
        if let equals = body.firstIndex(of: "=") {
          let bytes = body[body.index(after: equals)...].split(separator: " ").compactMap {
            $0.count == 2 ? UInt8($0, radix: 16) : nil
          }
          pcBytes = Array(bytes.prefix(16))
        }
      } else if body.hasPrefix("pc-bytes unreadable") {
        unreadable = true
      } else if body.hasPrefix("pc ") {
        pc = Self.probe(body.dropFirst(3))
      } else if body.hasPrefix("target ") {
        targetProbe = Self.probe(body.dropFirst(7))
      } else if body.hasPrefix("stack[") {
        if let close = body.firstIndex(of: "]") {
          stackAddress = Self.hex(String(body[body.index(body.startIndex, offsetBy: 6)..<close]))
          stack = Array(
            body[body.index(after: close)...].split(separator: " ")
              .compactMap { Self.hex(String($0)) }.prefix(Self.stackLimit))
        }
      } else if body.hasPrefix("tf ") {
        let fields = Self.pairs(body.dropFirst(3))
        if let state = fields["state"].flatMap({ UInt32($0, radix: 16) }),
          let guest = fields["guest_flags"].flatMap({ UInt32($0, radix: 16) }),
          let steps = fields["steps"].flatMap({ UInt64($0) })
        {
          traceFlag = (state, guest, steps)
        }
      } else {
        let fields = Self.orderedPairs(body)
        if fields.contains(where: { $0.0 == "eip" }) { arch = .i386 }
        for (name, text) in fields {
          guard Self.registerNames.contains(name), let value = Self.hex(text) else { continue }
          registers.append((name, value))
        }
      }
    }
    guard let begin, let process = begin["pid"], let thread = begin["tid"],
      Self.isShortHex(process), Self.isShortHex(thread),
      let code = begin["code"].flatMap({ UInt32($0, radix: 16) }),
      let address = begin["address"].flatMap({ Self.hex($0) })
    else { return nil }
    self.architecture = arch
    self.process = process
    self.thread = thread
    self.code = code
    self.flags = begin["flags"].flatMap { UInt32($0, radix: 16) } ?? 0
    self.address = address
    self.access = access
    self.target = target
    self.registers = registers
    self.pc = pc
    self.targetProbe = targetProbe
    self.pcBytes = pcBytes
    self.pcBytesUnreadable = unreadable
    self.stack = stack
    self.stackAddress = stackAddress
    self.traceFlag = traceFlag
    self.isComplete = complete
  }

  private static func isShortHex(_ text: String) -> Bool {
    (1...8).contains(text.count) && text.allSatisfy(\.isHexDigit)
  }

  static func hex(_ text: String) -> UInt64? {
    (1...16).contains(text.count) && text.allSatisfy(\.isHexDigit)
      ? UInt64(text, radix: 16) : nil
  }

  private static func orderedPairs(_ text: Substring) -> [(String, String)] {
    text.split(separator: " ").compactMap { token in
      guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return nil }
      return (String(token[..<equals]), String(token[token.index(after: equals)...]))
    }
  }

  private static func pairs(_ text: Substring) -> [String: String] {
    Dictionary(orderedPairs(text), uniquingKeysWith: { first, _ in first })
  }

  /// `<address> not queryable (...)` or `<address> state=1000 protect=20 type=1000000
  /// region=<base>+<size> module=<name>`.
  private static func probe(_ text: Substring) -> Probe? {
    let words = text.split(separator: " ", maxSplits: 1).map(String.init)
    guard words.count == 2, hex(words[0]) != nil else { return nil }
    if words[1].hasPrefix("not queryable") { return .notQueryable }
    let tail = words[1]
    let marker = tail.range(of: " module=")
    let head = marker.map { tail[..<$0.lowerBound] } ?? tail[...]
    let module = marker.map { String(tail[$0.upperBound...].filter { $0.isASCII }.prefix(64)) }
    let fields = pairs(head)
    guard let state = fields["state"].flatMap({ UInt32($0, radix: 16) }),
      let protect = fields["protect"].flatMap({ UInt32($0, radix: 16) }),
      let type = fields["type"].flatMap({ UInt32($0, radix: 16) }),
      let region = fields["region"]?.split(separator: "+").map(String.init), region.count == 2,
      let base = hex(region[0]), let size = hex(region[1])
    else { return nil }
    return .region(
      Region(
        state: state, protect: protect, type: type, base: base, size: size,
        module: module ?? "none"))
  }
}

/// Collects `wine-crash:` lines into blocks as a log is read line by line.
struct NFS2015CrashBlockReader: Equatable, Sendable {
  static let blockLimit = 8

  private(set) var blocks: [NFS2015CrashBlock] = []
  private var open: [String]?

  /// Whether a block has begun and not ended.
  var isOpen: Bool { open != nil }

  /// Takes one log line. Lines that are not part of a block change nothing.
  mutating func read(_ line: String) {
    guard line.hasPrefix(NFS2015CrashBlock.linePrefix) else { return }
    let body = line.dropFirst(NFS2015CrashBlock.linePrefix.count)
    if body.hasPrefix("begin ") {
      close()
      open = [String(line.prefix(300))]
    } else if open != nil {
      open?.append(String(line.prefix(300)))
      if body == "end" || (open?.count ?? 0) >= NFS2015CrashBlock.lineLimit { close() }
    }
  }

  /// Ends a block the log stopped in the middle of.
  mutating func finish() { close() }

  private mutating func close() {
    guard let lines = open else { return }
    open = nil
    if let block = NFS2015CrashBlock(lines: lines), blocks.count < Self.blockLimit {
      blocks.append(block)
    }
  }
}
