import Foundation

/// Bounded section-based text editor that retains unrelated lines.
package struct ConfigText {
  private var lines: [String]
  package var text: String { lines.joined(separator: "\n") }

  package init(_ text: String) throws(LauncherError) {
    guard text.utf8.count <= 1_048_576, !text.contains("\0") else {
      throw .operation("Configuration file is too large or contains invalid text.")
    }
    lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
  }

  package func value(section: String, key: String) -> String? {
    var current = ""
    for line in lines {
      if let heading = heading(line) {
        current = heading
        continue
      }
      guard current == section, let parts = assignment(line), parts.0 == key else { continue }
      return parts.1.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map
      {
        $0.trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  package mutating func set(section: String, key: String, value: String, compact: Bool = false) {
    let replacement = compact ? "\(key)=\(value)" : "\(key) = \(value)"
    var current = ""
    var inserted = false
    var foundSection = section.isEmpty
    var output: [String] = []
    output.reserveCapacity(lines.count + 3)
    for line in lines {
      if let heading = heading(line) {
        if current == section && !inserted {
          output.append(replacement)
          inserted = true
        }
        current = heading
        if current == section { foundSection = true }
      }
      if current == section, let parts = assignment(line), parts.0 == key {
        if !inserted {
          output.append(replacement)
          inserted = true
        }
      } else {
        output.append(line)
      }
    }
    if !inserted {
      if !foundSection { output.append("[\(section)]") }
      output.append(replacement)
    }
    lines = output
  }

  private func heading(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") else { return nil }
    return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
  }

  private func assignment(_ line: String) -> (String, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=")
    else { return nil }
    return (
      trimmed[..<equals].trimmingCharacters(in: .whitespaces),
      trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    )
  }
}
