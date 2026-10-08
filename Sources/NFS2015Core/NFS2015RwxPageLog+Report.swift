import Foundation

extension NFS2015RwxPageLog {
  private static func address(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

  private static func counts<Key: RawRepresentable & Hashable & CaseIterable>(
    _ values: [Key: Int]
  ) -> String where Key.RawValue == String {
    Key.allCases.compactMap { key in values[key].map { "\(key.rawValue) \($0)" } }
      .joined(separator: ", ")
  }

  /// One report line for an event: numbers and the fixed words only.
  package static func line(_ event: Event) -> String {
    switch event {
    case .protected(let page, let reason, let protection):
      return
        "protected \(address(page)) via \(reason.rawValue), protection \(address(UInt64(protection)))"
    case .skipped(let page, let reason, let protection, let via):
      return
        "left alone \(address(page)): \(reason.rawValue), protection \(address(UInt64(protection))), "
        + "found via \(via.rawValue)"
    case .store(let page, let number, let instruction, let thread):
      return
        "store #\(number) into \(address(page)) by the instruction at \(address(instruction)), "
        + "thread \(String(thread, radix: 16))"
    case .released(let page, let reason, let stores):
      return "released \(address(page)): \(reason.rawValue) after \(stores) stores"
    case .stateDropped(let page):
      return "\(address(page)): released state dropped after a protection change"
    }
  }

  /// The report's lines for these page lines: one summary per page, then the first and the newest
  /// events in the order read. Empty when the log held none.
  package var reportLines: [String] {
    guard !isEmpty else { return [] }
    var lines = [
      "page history, \(total) line\(total == 1 ? "" : "s") (the runtime prints at most 200 per "
        + "process; the lines of several processes are merged):"
    ]
    for page in pages {
      var parts: [String] = []
      if !page.protections.isEmpty {
        parts.append(
          "protected \(Self.counts(page.protections).replacingOccurrences(of: ",", with: " and"))")
      }
      if !page.skips.isEmpty { parts.append("left alone: \(Self.counts(page.skips))") }
      if !page.releases.isEmpty { parts.append("released: \(Self.counts(page.releases))") }
      if page.droppedStates > 0 {
        parts.append(
          "released state dropped \(page.droppedStates) time\(page.droppedStates == 1 ? "" : "s")")
      }
      if parts.isEmpty { parts.append("no protection, skip or release line") }
      lines.append("  page \(Self.address(page.page)): " + parts.joined(separator: "; "))
      if let stores = page.storesAtRelease {
        lines.append("    stores counted at the last release: \(stores)")
      }
      if !page.firstStores.isEmpty {
        lines.append(
          "    first stores (of \(page.lastStoreNumber) printed): "
            + page.firstStores.map { "#\($0.number) from \(Self.address($0.instruction))" }
            .joined(separator: ", "))
      }
    }
    if pages.count == Self.pageLimit {
      lines.append("  (at most \(Self.pageLimit) pages are summarized)")
    }
    lines.append("  events in the order read:")
    lines += head.map { "    " + Self.line($0) }
    if dropped > 0 { lines.append("    … \(dropped) events not shown …") }
    let rest = tail.suffix(Self.tailLimit)
    lines += rest.map { "    " + Self.line($0) }
    return lines
  }
}
