import Foundation
import LauncherCore

/// A lossless, attribute-level editor for Far Cry 2's `GamerProfile.xml`.
///
/// The game writes this file and reads it back with its own parser, so the editor never re-serializes
/// it: it locates start tags in the original bytes and replaces only the attribute values it is asked
/// to change. Comments, whitespace, attribute order, unknown elements and the text encoding stay as
/// the game wrote them. DOCTYPE declarations are refused, so no entity is ever expanded.
package struct GamerProfileDocument {
  /// An attribute of every element whose ancestry ends with `path`, for example `["CustomQuality", "quality"]`.
  package struct Target: Hashable, Sendable {
    package let path: [String]
    package let attribute: String
    package init(_ path: [String], _ attribute: String) {
      self.path = path
      self.attribute = attribute
    }
  }

  private enum Encoding {
    case utf8, utf8WithBOM, utf16LittleEndian, utf16BigEndian
  }

  private struct Attribute {
    let name: String
    let value: Range<Int>
  }

  private struct Element {
    let path: [String]
    let attributes: [Attribute]
  }

  private static let limit = 1_048_576
  private var bytes: [UInt8]
  private var elements: [Element]
  private let encoding: Encoding

  /// - Throws: A message when the file is not well-formed, uses a DOCTYPE or exceeds 1 MiB.
  package init(_ data: Data) throws(LauncherError) {
    guard data.count <= Self.limit else {
      throw .operation("GamerProfile.xml is larger than 1 MiB.")
    }
    var payload = Array(data)
    if payload.starts(with: [0xEF, 0xBB, 0xBF]) {
      encoding = .utf8WithBOM
      payload.removeFirst(3)
    } else if payload.starts(with: [0xFF, 0xFE]) || payload.starts(with: [0xFE, 0xFF]) {
      let little = payload[0] == 0xFF
      encoding = little ? .utf16LittleEndian : .utf16BigEndian
      guard
        let text = String(
          data: Data(payload.dropFirst(2)),
          encoding: little ? .utf16LittleEndian : .utf16BigEndian)
      else { throw .operation("GamerProfile.xml is not valid text.") }
      payload = Array(text.utf8)
    } else {
      encoding = .utf8
    }
    guard !payload.contains(0), String(validating: payload, as: UTF8.self) != nil else {
      throw .operation("GamerProfile.xml is not valid UTF-8 text.")
    }
    bytes = payload
    elements = try Self.parse(payload)
  }

  /// The document in its original encoding, with only the requested values changed.
  package var data: Data {
    switch encoding {
    case .utf8: return Data(bytes)
    case .utf8WithBOM: return Data([0xEF, 0xBB, 0xBF] + bytes)
    case .utf16LittleEndian, .utf16BigEndian:
      let little = encoding == .utf16LittleEndian
      let text = String(decoding: bytes, as: UTF8.self)
      let body = text.data(using: little ? .utf16LittleEndian : .utf16BigEndian) ?? Data()
      return Data(little ? [0xFF, 0xFE] : [0xFE, 0xFF]) + body
    }
  }

  package func hasElement(_ path: [String]) -> Bool {
    elements.contains { $0.path.suffix(path.count).elementsEqual(path) }
  }

  /// Current values of the attribute on every matching element, in document order.
  package func values(_ target: Target) -> [String] {
    matches(target).compactMap { range in
      let text = String(decoding: bytes[range], as: UTF8.self)
      return text.contains("&") ? nil : text
    }
  }

  /// Replaces the attribute value on every matching element that already carries it.
  /// - Parameter value: A token of letters, digits, `.`, `_` or `-`; nothing needs escaping.
  /// - Returns: The number of attributes changed. Missing elements and attributes are not created.
  @discardableResult
  package mutating func set(_ value: String, for target: Target) throws(LauncherError) -> Int {
    guard Self.isToken(value) else {
      throw .operation("The value \(value) cannot be written to GamerProfile.xml.")
    }
    let replacement = Array(value.utf8)
    let ranges = matches(target)
    for range in ranges.reversed() { bytes.replaceSubrange(range, with: replacement) }
    if !ranges.isEmpty { elements = try Self.parse(bytes) }
    return ranges.count
  }

  private func matches(_ target: Target) -> [Range<Int>] {
    elements.flatMap { element -> [Range<Int>] in
      guard element.path.suffix(target.path.count).elementsEqual(target.path) else { return [] }
      return element.attributes.filter { $0.name == target.attribute }.map(\.value)
    }
  }

  private static func isToken(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 46 || $0 == 95 || $0 == 45
      }
  }

  // MARK: - Tokenizer

  private static func parse(_ bytes: [UInt8]) throws(LauncherError) -> [Element] {
    let malformed = LauncherError.operation("GamerProfile.xml is not well-formed XML.")
    var elements: [Element] = []
    var stack: [String] = []
    var index = 0
    func starts(_ text: String, at position: Int) -> Bool {
      let pattern = Array(text.utf8)
      return position + pattern.count <= bytes.count
        && bytes[position..<(position + pattern.count)].elementsEqual(pattern)
    }
    func find(_ text: String, from position: Int) -> Int? {
      let pattern = Array(text.utf8)
      guard pattern.count <= bytes.count else { return nil }
      var cursor = position
      while cursor + pattern.count <= bytes.count {
        if bytes[cursor..<(cursor + pattern.count)].elementsEqual(pattern) { return cursor }
        cursor += 1
      }
      return nil
    }
    func isNameStart(_ byte: UInt8) -> Bool {
      (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 58
    }
    func isNameByte(_ byte: UInt8) -> Bool {
      isNameStart(byte) || (48...57).contains(byte) || byte == 45 || byte == 46
    }
    func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    func name(at position: inout Int) -> String? {
      guard position < bytes.count, isNameStart(bytes[position]) else { return nil }
      let start = position
      while position < bytes.count, isNameByte(bytes[position]) { position += 1 }
      return String(decoding: bytes[start..<position], as: UTF8.self)
    }
    while index < bytes.count {
      guard bytes[index] == 0x3C else {
        index += 1
        continue
      }
      if starts("<!--", at: index) {
        guard let end = find("-->", from: index + 4) else { throw malformed }
        index = end + 3
      } else if starts("<![CDATA[", at: index) {
        guard let end = find("]]>", from: index + 9) else { throw malformed }
        index = end + 3
      } else if starts("<?", at: index) {
        guard let end = find("?>", from: index + 2) else { throw malformed }
        index = end + 2
      } else if starts("<!", at: index) {
        throw LauncherError.operation(
          "GamerProfile.xml declares a DOCTYPE, which is not supported.")
      } else if starts("</", at: index) {
        index += 2
        guard let closing = name(at: &index), stack.popLast() == closing else { throw malformed }
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
        guard index < bytes.count, bytes[index] == 0x3E else { throw malformed }
        index += 1
      } else {
        index += 1
        guard let element = name(at: &index), stack.count < 64 else { throw malformed }
        var attributes: [Attribute] = []
        var selfClosing = false
        tag: while true {
          while index < bytes.count, isSpace(bytes[index]) { index += 1 }
          guard index < bytes.count else { throw malformed }
          if bytes[index] == 0x3E {
            index += 1
            break tag
          }
          if starts("/>", at: index) {
            index += 2
            selfClosing = true
            break tag
          }
          guard let attribute = name(at: &index), attributes.count < 256 else { throw malformed }
          while index < bytes.count, isSpace(bytes[index]) { index += 1 }
          guard index < bytes.count, bytes[index] == 0x3D else { throw malformed }
          index += 1
          while index < bytes.count, isSpace(bytes[index]) { index += 1 }
          guard index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 else {
            throw malformed
          }
          let quote = bytes[index]
          index += 1
          let start = index
          while index < bytes.count, bytes[index] != quote, bytes[index] != 0x3C { index += 1 }
          guard index < bytes.count, bytes[index] == quote else { throw malformed }
          attributes.append(Attribute(name: attribute, value: start..<index))
          index += 1
        }
        let path = stack + [element]
        elements.append(Element(path: path, attributes: attributes))
        if !selfClosing { stack.append(element) }
        guard elements.count <= 20_000 else { throw malformed }
      }
    }
    guard stack.isEmpty, !elements.isEmpty else { throw malformed }
    return elements
  }
}
