import Foundation

/// Appends registry sections to a Wine hive file while the prefix's Wine server is stopped.
///
/// Wine keeps each hive as text: a header, then one `[Key] stamp` section per key with its value
/// lines. A section appended at the end is read exactly like one Wine wrote itself, and it keeps
/// every value type byte for byte, which a `reg import` of the same data cannot promise.
enum RegistryHiveText {
  /// The largest hive the app edits; a fresh prefix's `system.reg` is a few megabytes.
  static let hiveLimit = 64 * 1024 * 1024
  static let partLimit = 8 * 1024 * 1024
  /// The first line of every hive file the bundled Wine writes.
  static let header = "WINE REGISTRY Version 2"

  /// The lowercased keys of a hive's text, with Wine's doubled backslashes undone.
  /// - Complexity: O(lines).
  static func keys(in text: String) -> Set<String> {
    var keys = Set<String>()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true)
    where line.hasPrefix("[") {
      guard let key = key(ofHeader: line) else { continue }
      keys.insert(key)
    }
    return keys
  }

  /// The key a `[Key] 1234567890` header names, with Wine's doubled backslashes undone and its case
  /// kept, or nil for any other line.
  private static func plainKey(ofHeader line: Substring) -> String? {
    key(ofHeader: line, folded: false)
  }

  /// The key a `[Key] 1234567890` header names, or nil for any other line.
  private static func key(ofHeader line: Substring, folded: Bool = true) -> String? {
    guard let close = line.lastIndex(of: "]"), close > line.startIndex else { return nil }
    let stamp = line[line.index(after: close)...]
    guard stamp.count > 1, stamp.first == " ", stamp.dropFirst().allSatisfy(\.isASCII),
      stamp.dropFirst().allSatisfy(\.isNumber)
    else { return nil }
    let key = line[line.index(after: line.startIndex)..<close].replacingOccurrences(
      of: "\\\\", with: "\\")
    return folded ? key.lowercased() : key
  }

  /// The hive with the part appended.
  /// - Throws: A failure when the hive is not a Wine hive, or the part names a key it already has.
  static func merged(hive: Data, part: Data) throws(LauncherError) -> Data {
    guard hive.starts(with: Data(Self.header.utf8)) else {
      throw .operation("The Windows folder's registry file is not a Wine registry.")
    }
    let existing = keys(in: String(decoding: hive, as: UTF8.self))
    let added = keys(in: String(decoding: part, as: UTF8.self))
    guard !added.isEmpty else {
      throw .operation("The EA app's registry entries hold no keys.")
    }
    if let clash = existing.intersection(added).sorted().first {
      throw .operation("The Windows folder already has a registry key the EA app adds: \(clash)")
    }
    // A hive ends with a blank line after its last section; make sure the part starts a new section.
    var separator = Data()
    if !hive.suffix(2).elementsEqual(Data("\n\n".utf8)) {
      separator = Data((hive.last == 10 ? "\n" : "\n\n").utf8)
    }
    return hive + separator + part
  }

  /// Checks that a part is plain key sections of keys a client layer may add, before any of it is appended.
  ///
  /// Each section is a `[Key] stamp` header, an optional `#time=` line, and value lines that start with a
  /// quoted name or `@=`, where a hex value may continue on lines after a trailing backslash. Anything
  /// else, a key outside the client's own, or a key count that differs from the manifest's, is refused.
  /// - Complexity: O(lines).
  static func validate(part: Data, hive: String, keys expected: Int) throws(LauncherError) {
    guard let text = String(data: part, encoding: .utf8) else {
      throw .operation("The EA app's registry entries are not text: \(hive)")
    }
    var keys = 0
    var inSection = false
    var continued = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if let key = plainKey(ofHeader: line) {
        try ClientLayerPolicy.validate(registryKey: key, hive: hive)
        keys += 1
        inSection = true
        continued = false
        continue
      }
      // A blank line only separates sections.
      if line.isEmpty {
        continued = false
        continue
      }
      guard inSection else {
        throw .operation("The EA app's registry entries start with something other than a key.")
      }
      if continued {
        continued = line.hasSuffix("\\")
      } else if !line.hasPrefix("#time=") {
        guard line.hasPrefix("\"") || line.hasPrefix("@=") else {
          throw .operation("The EA app's registry entries hold an unexpected line in \(hive).")
        }
        let value = line.split(separator: "=", maxSplits: 1).dropFirst().first ?? ""
        continued = line.hasSuffix("\\") && value.hasPrefix("hex")
      }
    }
    guard keys > 0, keys == expected else {
      throw .operation("The EA app's registry entries do not hold the keys they declare: \(hive)")
    }
  }
}
