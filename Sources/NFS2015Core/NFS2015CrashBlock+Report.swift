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
    found.append(contentsOf: pageObservations)
    if pcBytesUnreadable { found.append("the bytes at the instruction pointer could not be read") }
    if let traceFlag, traceFlag.state != 0 || traceFlag.steps > 0 {
      found.append(
        "the trap-flag emulation was active (state \(traceFlag.state), \(traceFlag.steps) steps)")
    }
    return found
  }

  /// Facts from the patch 0006 lines; nothing here says why the program faulted.
  private var pageObservations: [String] {
    var found: [String] = []
    if case .region(let region)? = pc, region.type == 0x2_0000, region.isExecutable,
      region.isWritable
    {
      found.append(
        "the instruction pointer is in private memory that is both writable and executable "
          + "(protect 0x\(String(region.protect, radix: 16, uppercase: true)))")
    }
    if let zero = pages.checksum?.zeroGroups {
      found.append(
        "\(zero) of 256 groups of 16 bytes in the instruction pointer's page are all zero")
    }
    for near in pages.near.prefix(3) {
      let distance = "0x" + String(near.delta.magnitude, radix: 16, uppercase: true)
      found.append(
        "register \(near.register) is \(distance) "
          + (near.delta < 0 ? "below" : near.delta > 0 ? "above" : "at")
          + " the instruction pointer")
    }
    if let first = pages.returns.first {
      found.append("the first return address candidate is in \(first.module)")
    }
    if let threads = pages.threads, threads > 0 {
      found.append("the process had \(threads) thread\(threads == 1 ? "" : "s")")
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
    lines += pageLines
    for observation in observations { lines.append("  - \(observation)") }
    return lines
  }

  /// The patch 0006 lines as report lines: code windows as plain hex, no decoding.
  private var pageLines: [String] {
    var lines: [String] = []
    func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16, uppercase: true) }
    for query in pages.queries {
      guard let info = query.info else {
        lines.append("  page \(text(query.page)): not queryable")
        continue
      }
      lines.append(
        "  page \(text(query.page)): allocation \(text(info.allocationBase)) (first protect "
          + "\(hex(UInt64(info.allocationProtect)))), region \(text(info.base))+\(hex(info.size)), "
          + "state \(hex(UInt64(info.state))) protect \(hex(UInt64(info.protect))) "
          + "type \(hex(UInt64(info.type)))")
    }
    if let sum = pages.checksum {
      if let fnv = sum.fnv1a64, let zero = sum.zeroGroups {
        lines.append(
          "  page checksum \(text(sum.page)): FNV-1a 64 \(Self.hex(fnv, width: 16)), "
            + "all-zero 16-byte groups \(zero) of 256")
      } else {
        lines.append("  page checksum \(text(sum.page)): the page could not be read")
      }
    }
    if pages.hasThreadLine {
      lines.append(
        "  threads: \(pages.threads.map(String.init) ?? "unknown")"
          + (pages.teb.map { ", TEB \(text($0))" } ?? ""))
    }
    for candidate in pages.returns {
      lines.append(
        "  return address candidate [\(candidate.slot)]: \(text(candidate.address)) "
          + "\(candidate.module)+\(hex(candidate.offset))")
    }
    if !pages.near.isEmpty {
      lines.append(
        "  registers near the instruction pointer: "
          + pages.near.map {
            "\($0.register)=pc" + ($0.delta < 0 ? "-" : "+") + hex($0.delta.magnitude)
          }.joined(separator: " "))
    }
    for window in pages.windows {
      lines.append(
        "  code window \(window.label) \(text(window.center)), -\(hex(window.before)) to "
          + "+\(hex(window.after)) (bytes, not decoded):")
      for row in window.rows {
        lines.append(
          "    \(text(row.address)): " + row.bytes.map { Self.hex(UInt64($0), width: 2) }.joined())
      }
      for range in window.unreadable {
        lines.append("    \(text(range.start))..\(text(range.end)): unreadable")
      }
    }
    return lines
  }
}
