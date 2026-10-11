import Foundation

/// A problem detected in a Wine prefix.
package enum PrefixProblem: Codable, Equatable, Sendable {
  case cDrive(actual: String?)
  case missingDrive(String)
  case driveTarget(String, actual: String, expected: String)
  case updateStamp(prefix: String?, runtime: String?)
  case driveUnreachable(String, target: String)

  package var summary: String {
    switch self {
    case .cDrive(let actual):
      if let actual {
        return "The c: drive link points to \(actual) but should point to ../drive_c."
      } else {
        return "The c: drive link is missing."
      }

    case .missingDrive(let letter):
      return "The \(letter): drive is missing."

    case .driveTarget(let letter, let actual, let expected):
      return "The \(letter): drive link points to \(actual) but should point to \(expected)."

    case .updateStamp(let prefix, let runtime):
      let prefixPart = prefix.map { "prefix \($0)" } ?? "prefix"
      let runtimePart = runtime.map { "runtime \($0)" } ?? "runtime"
      return "Wine needs to update the \(prefixPart) for the \(runtimePart)."

    case .driveUnreachable(let letter, let target):
      return "The \(letter): drive link points to \(target) which does not exist."
    }
  }

  // Nits: private CodingKeys
  private enum CodingKeys: String, CodingKey {
    case type
    case actual
    case letter
    case expected
    case prefix
    case runtime
    case target
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "cDrive":
      let actual = try container.decodeIfPresent(String.self, forKey: .actual)
      self = .cDrive(actual: actual)

    case "missingDrive":
      let letter = try container.decode(String.self, forKey: .letter)
      self = .missingDrive(letter)

    case "driveTarget":
      let letter = try container.decode(String.self, forKey: .letter)
      let actual = try container.decode(String.self, forKey: .actual)
      let expected = try container.decode(String.self, forKey: .expected)
      self = .driveTarget(letter, actual: actual, expected: expected)

    case "updateStamp":
      let prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
      let runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
      self = .updateStamp(prefix: prefix, runtime: runtime)

    case "driveUnreachable":
      let letter = try container.decode(String.self, forKey: .letter)
      let target = try container.decode(String.self, forKey: .target)
      self = .driveUnreachable(letter, target: target)

    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "Unknown type: \(type)"
      )
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .cDrive(let actual):
      try container.encode("cDrive", forKey: .type)
      try container.encodeIfPresent(actual, forKey: .actual)

    case .missingDrive(let letter):
      try container.encode("missingDrive", forKey: .type)
      try container.encode(letter, forKey: .letter)

    case .driveTarget(let letter, let actual, let expected):
      try container.encode("driveTarget", forKey: .type)
      try container.encode(letter, forKey: .letter)
      try container.encode(actual, forKey: .actual)
      try container.encode(expected, forKey: .expected)

    case .updateStamp(let prefix, let runtime):
      try container.encode("updateStamp", forKey: .type)
      try container.encodeIfPresent(prefix, forKey: .prefix)
      try container.encodeIfPresent(runtime, forKey: .runtime)

    case .driveUnreachable(let letter, let target):
      try container.encode("driveUnreachable", forKey: .type)
      try container.encode(letter, forKey: .letter)
      try container.encode(target, forKey: .target)
    }
  }
}
