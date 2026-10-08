import Foundation

extension NFS2015CrashBlock {
  private static func hex(_ value: UInt64, width: Int) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  /// Digits the runtime printed for a pointer: 16 for 64-bit code, 8 for 32-bit code.
  private var width: Int { architecture == .amd64 ? 16 : 8 }

  private func text(_ value: UInt64) -> String { "0x" + Self.hex(value, width: width) }

  /// What the numbers show, in the order of how telling each is. Nothing here says why the
  /// program faulted; it only restates facts the block holds.
  package var observations: [String] {
    var found: [String] = []
    if let target {
      switch targetProbe {
      case .notQueryable:
        found.append(
          "Wine could not query the target page: the address is not in the process's address space")
      case .region(let region):
        found.append(contentsOf: Self.describeTarget(region, access: access))
      case nil: break
      }
      let holders = registers.filter { $0.value == target && $0.name != "rip" && $0.name != "eip" }
      if !holders.isEmpty {
        found.append(
          "the target address is the value of "
            + holders.prefix(3).map(\.name).joined(separator: ", "))
      }
    }
    switch pc {
    case .notQueryable:
      found.append("Wine could not query the page of the instruction pointer")
    case .region(let region):
      if region.isFree {
        found.append("the instruction pointer is in unmapped memory")
      } else if region.isCommitted, !region.isExecutable {
        found.append(
          "the instruction pointer is in a page that is not executable (protect 0x"
            + String(region.protect, radix: 16, uppercase: true) + ")")
      }
      found.append("the instruction pointer is in module \(region.module)")
    case nil: break
    }
    if pcBytesUnreadable { found.append("the bytes at the instruction pointer could not be read") }
    if let traceFlag, traceFlag.state != 0 || traceFlag.steps > 0 {
      found.append(
        "the trap-flag emulation was active (state \(traceFlag.state), \(traceFlag.steps) steps)")
    }
    return found
  }

  private static func describeTarget(_ region: Region, access: UInt64?) -> [String] {
    if region.isFree { return ["the target page is not mapped"] }
    if !region.isCommitted { return ["the target page is reserved but not committed"] }
    var found: [String] = []
    let protect = "0x" + String(region.protect, radix: 16, uppercase: true)
    if region.isGuardOrNoAccess {
      found.append("the target page is a guard or no-access page (protect \(protect))")
    } else if access == 1, !region.isWritable {
      found.append("the program wrote to a page that is not writable (protect \(protect))")
    } else if access == 8, !region.isExecutable {
      found.append("the program ran code in a page that is not executable (protect \(protect))")
    } else {
      found.append("the target page is committed and its protection (\(protect)) allows the access")
    }
    found.append("the target page belongs to module \(region.module)")
    return found
  }

  /// The block as report lines: short, free of names, one fact group per line.
  package var reportLines: [String] {
    var lines: [String] = []
    let exception = "0x" + Self.hex(UInt64(code), width: 8)
    lines.append(
      "process \(process) thread \(thread), \(architecture.rawValue), exception \(exception) "
        + "at \(text(address))" + (isComplete ? "" : " (the block was cut short)"))
    if let target {
      let kind =
        switch access {
        case 0: "read"
        case 1: "write"
        case 8: "execute"
        default: "access \(access.map(String.init) ?? "?")"
        }
      lines.append("  \(kind) of \(text(target))")
    }
    var row: [String] = []
    for register in registers {
      // Segment registers print as 16 bits, the flag and control registers as 32.
      let digits =
        register.name.count == 2 ? 4 : ["eflags", "mxcsr"].contains(register.name) ? 8 : width
      row.append("\(register.name)=\(Self.hex(register.value, width: digits))")
      if row.count == 4 {
        lines.append("  " + row.joined(separator: " "))
        row = []
      }
    }
    if !row.isEmpty { lines.append("  " + row.joined(separator: " ")) }
    for (label, probe) in [("instruction pointer", pc), ("target", targetProbe)] {
      switch probe {
      case .notQueryable?: lines.append("  \(label) page: not queryable")
      case .region(let region)?:
        lines.append(
          "  \(label) page: state 0x\(String(region.state, radix: 16, uppercase: true)) protect "
            + "0x\(String(region.protect, radix: 16, uppercase: true)) type "
            + "0x\(String(region.type, radix: 16, uppercase: true)) region "
            + "\(text(region.base))+0x\(String(region.size, radix: 16, uppercase: true)) module \(region.module)"
        )
      case nil: break
      }
    }
    if let pcBytes {
      lines.append(
        "  bytes at the instruction pointer: "
          + (pcBytes.isEmpty
            ? "none read" : pcBytes.map { Self.hex(UInt64($0), width: 2) }.joined(separator: " ")))
    }
    if !stack.isEmpty, let stackAddress {
      lines.append(
        "  stack at \(text(stackAddress)): "
          + stack.map { Self.hex($0, width: width) }.joined(separator: " "))
    }
    if let traceFlag {
      lines.append(
        "  trap-flag emulation: state \(traceFlag.state), guest flags "
          + "0x\(String(traceFlag.guestFlags, radix: 16, uppercase: true)), steps \(traceFlag.steps)"
      )
    }
    for observation in observations { lines.append("  - \(observation)") }
    return lines
  }
}
