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

  /// The key a `[Key] 1234567890` header names, or nil for any other line.
  private static func key(ofHeader line: Substring) -> String? {
    guard let close = line.lastIndex(of: "]"), close > line.startIndex else { return nil }
    let stamp = line[line.index(after: close)...]
    guard stamp.count > 1, stamp.first == " ", stamp.dropFirst().allSatisfy(\.isASCII),
      stamp.dropFirst().allSatisfy(\.isNumber)
    else { return nil }
    let key = line[line.index(after: line.startIndex)..<close]
    return key.replacingOccurrences(of: "\\\\", with: "\\").lowercased()
  }

  /// The hive with the part appended.
  /// - Throws: A failure when the hive is not a Wine hive, or the part names a key it already has.
  static func merged(hive: Data, part: Data) throws(LauncherError) -> Data {
    guard hive.starts(with: Data("WINE REGEDIT4".utf8)) else {
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
}
