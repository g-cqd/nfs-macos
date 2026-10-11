import Foundation

/// A coding key that accepts both String and Int initializers.
package struct AnyCodingKey: CodingKey {
  package let stringValue: String
  package let intValue: Int?

  package init(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  package init(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

/// Rejects any unknown keys in a keyed container during decoding.
/// - Parameters:
///   - decoder: The decoder with the container to check.
///   - allowed: The set of keys that are permitted.
///   - type: The name of the type being decoded, for error messages.
/// - Throws: `HubError.invalid` if an unknown key is found.
package func rejectUnknownKeys(
  _ decoder: any Decoder,
  allowed: Set<String>,
  type: String
) throws {
  let container = try decoder.container(keyedBy: AnyCodingKey.self)
  for key in container.allKeys {
    guard allowed.contains(key.stringValue) else {
      throw HubError.invalid("\(type): unknown key \(key.stringValue)")
    }
  }
}
