import Foundation
import LauncherCore

/// Shared validators for model fields.
package enum Check {
  /// Helper to validate ASCII bytes with first and rest byte predicates.
  package static func ascii(_ s: String, _ len: ClosedRange<Int>, first: (UInt8) -> Bool, rest: (UInt8) -> Bool) -> Bool {
    let bytes = s.utf8
    guard len.contains(bytes.count) else { return false }
    guard let firstByte = bytes.first, first(firstByte) else { return false }
    for byte in bytes.dropFirst() {
      guard rest(byte) else { return false }
    }
    return true
  }

  /// Validates an identifier: `^[a-z0-9][a-z0-9-]{0,47}$`
  package static func id(_ s: String, field: String) throws(HubError) {
    guard (1...48).contains(s.utf8.count) else {
      throw HubError.invalid("\(field): id must be 1 to 48 characters")
    }
    let bytes = s.utf8
    guard let first = bytes.first,
      (first >= 0x61 && first <= 0x7a) || (first >= 0x30 && first <= 0x39)
    else {
      throw HubError.invalid("\(field): id must start with a-z or 0-9")
    }
    for byte in bytes {
      let isLower = byte >= 0x61 && byte <= 0x7a
      let isDigit = byte >= 0x30 && byte <= 0x39
      let isHyphen = byte == 0x2d
      guard isLower || isDigit || isHyphen else {
        throw HubError.invalid("\(field): id may only contain a-z, 0-9, and hyphens")
      }
    }
  }

  /// Validates text: non-empty after trimming, <= max UTF-8 bytes on original, no control characters on original.
  package static func text(_ s: String, field: String, max: Int) throws(HubError) {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw HubError.invalid("\(field): must not be empty")
    }
    guard s.utf8.count <= max else {
      throw HubError.invalid("\(field): must be at most \(max) UTF-8 bytes")
    }
    for scalar in s.unicodeScalars {
      let value = scalar.value
      if (value >= 0x0000 && value <= 0x001f) || value == 0x007f {
        throw HubError.invalid("\(field): may not contain control characters")
      }
    }
  }

  /// Validates an executable name.
  package static func exe(_ s: String, field: String) throws(HubError) {
    guard RendererSelection.isExecutableName(s) else {
      throw HubError.invalid("\(field): must be a Windows executable name like game.exe")
    }
  }

  /// Validates a SHA256 hash: exactly 64 hex characters.
  package static func sha256(_ s: String, field: String) throws(HubError) {
    guard s.utf8.count == 64 else {
      throw HubError.invalid("\(field): sha256 must be exactly 64 characters")
    }
    for byte in s.utf8 {
      let isHex = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
      guard isHex else {
        throw HubError.invalid("\(field): sha256 must be hexadecimal [0-9a-f]")
      }
    }
  }

  /// Validates a relative path: non-empty, <= 240 bytes, no leading `/` or `\`, no `..` or `.` or empty components, no `\` or `:`.
  package static func relativePath(_ s: String, field: String) throws(HubError) {
    let bytes = s.utf8
    guard !bytes.isEmpty else {
      throw HubError.invalid("\(field): path must not be empty")
    }
    guard bytes.count <= 240 else {
      throw HubError.invalid("\(field): path must be at most 240 bytes")
    }
    guard let first = bytes.first else {
      throw HubError.invalid("\(field): path must not be empty")
    }
    guard first != 0x2f && first != 0x5c else {
      throw HubError.invalid("\(field): path must not start with / or \\")
    }
    for scalar in s.unicodeScalars {
      let value = scalar.value
      if (value >= 0x0000 && value <= 0x001f) || value == 0x007f {
        throw HubError.invalid("\(field): path may not contain control characters")
      }
      if value == 0x5c || value == 0x3a {  // \ or :
        throw HubError.invalid("\(field): path may not contain \\ or :")
      }
    }
    let components = s.split(separator: "/", omittingEmptySubsequences: false)
    for component in components {
      guard component != ".." && component != "." && !component.isEmpty else {
        throw HubError.invalid("\(field): path may not contain . or .. components or empty parts")
      }
    }
  }

  /// Validates a destination path: must start with `{gameRoot}/` or `{prefix}/drive_c/` and have a valid relative path after.
  package static func destination(_ s: String, field: String) throws(HubError) {
    if s.hasPrefix("{gameRoot}/") {
      let rest = String(s.dropFirst(11))
      try relativePath(rest, field: field)
    } else if s.hasPrefix("{prefix}/drive_c/") {
      let rest = String(s.dropFirst(17))
      try relativePath(rest, field: field)
    } else {
      throw HubError.invalid("\(field): must start with {gameRoot}/ or {prefix}/drive_c/")
    }
  }

  /// Validates a registry key for FixAction.registry.
  package static func registryKey(_ key: String, hive: String, field: String) throws(HubError) {
    guard key.utf8.count <= 255 else {
      throw HubError.invalid("\(field): must be at most 255 bytes")
    }
    for scalar in key.unicodeScalars {
      let value = scalar.value
      if (value >= 0x0000 && value <= 0x001f) || value == 0x007f || scalar == "]" || scalar == "/" {
        throw HubError.invalid("\(field): invalid character")
      }
    }
    guard !key.hasPrefix("\\") && !key.hasSuffix("\\") else {
      throw HubError.invalid("\(field): must not start or end with backslash")
    }
    let components = key.split(separator: "\\", omittingEmptySubsequences: false)
    for component in components {
      guard !component.isEmpty else {
        throw HubError.invalid("\(field): may not have empty components")
      }
    }
    let machineSystemPrefix = "System\\CurrentControlSet\\Control\\Session Manager\\Environment"
    if key.hasPrefix("System\\") {
      guard hive == "machine" else {
        throw HubError.invalid("\(field): System keys only in machine hive")
      }
      guard key == machineSystemPrefix || key.hasPrefix(machineSystemPrefix + "\\") else {
        throw HubError.invalid("\(field): must be exactly or start with System\\CurrentControlSet\\Control\\Session Manager\\Environment")
      }
    } else if key.hasPrefix("Software\\") {
      // OK
    } else {
      throw HubError.invalid("\(field): must start with Software\\ or System\\CurrentControlSet\\Control\\Session Manager\\Environment")
    }
  }

  /// Validates a registry value name: 1...255 bytes, no control chars, no `"`.
  package static func registryValueName(_ name: String, field: String) throws(HubError) {
    guard (1...255).contains(name.utf8.count) else {
      throw HubError.invalid("\(field): must be 1 to 255 bytes")
    }
    for scalar in name.unicodeScalars {
      let value = scalar.value
      if (value >= 0x0000 && value <= 0x001f) || value == 0x007f || scalar == "\"" {
        throw HubError.invalid("\(field): invalid character")
      }
    }
  }

  /// Validates placeholders: every `{...}` must be a Placeholder raw value.
  package static func placeholders(_ s: String, field: String) throws(HubError) {
    var braceCount = 0
    var currentPlaceholder = ""
    var inPlaceholder = false

    for char in s {
      if char == "{" {
        guard !inPlaceholder else {
          throw HubError.invalid("\(field): unbalanced braces")
        }
        braceCount += 1
        inPlaceholder = true
        currentPlaceholder = ""
      } else if char == "}" {
        guard inPlaceholder else {
          throw HubError.invalid("\(field): unbalanced braces")
        }
        inPlaceholder = false
        let validPlaceholders = Set(Placeholder.allCases.map { $0.rawValue })
        guard validPlaceholders.contains(currentPlaceholder) else {
          throw HubError.invalid("\(field): unknown placeholder \(currentPlaceholder)")
        }
        braceCount -= 1
      } else if inPlaceholder {
        currentPlaceholder.append(char)
      }
    }

    guard braceCount == 0 else {
      throw HubError.invalid("\(field): unbalanced braces")
    }
  }
}

/// Valid placeholders that can appear in text.
package enum Placeholder: String, CaseIterable, Sendable {
  case prefix = "prefix"
  case hubRoot = "hubRoot"
  case gameRoot = "gameRoot"
  case providerRoot = "providerRoot"
  case eaClientDir = "eaClientDir"
  case offerIDs = "offerIDs"
  case appID = "appID"
}
