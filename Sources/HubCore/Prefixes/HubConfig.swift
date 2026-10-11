import Darwin
import Foundation

/// Configuration for the Game Hub.
package struct HubConfig: Codable, Equatable, Sendable {
  package let schemaVersion: Int
  package let prefix: String
  package let runtime: String
  package let runtimeManifestSHA256: String
  package let generation: Int

  package init(
    schemaVersion: Int, prefix: String, runtime: String,
    runtimeManifestSHA256: String, generation: Int
  ) {
    self.schemaVersion = schemaVersion
    self.prefix = prefix
    self.runtime = runtime
    self.runtimeManifestSHA256 = runtimeManifestSHA256
    self.generation = generation
  }

  // MARK: - Reading and writing

  /// Reads and validates the Hub configuration from a file.
  /// S12: Uses open(O_RDONLY|O_NOFOLLOW|O_CLOEXEC), fstat must be regular file <= 64 KiB,
  /// reads at most 64 KiB + 1 bytes (handles short reads). Uses dynamic CodingKey for key validation.
  package static func read(_ url: URL) throws(HubError) -> HubConfig {
    // S12: open with O_RDONLY|O_NOFOLLOW|O_CLOEXEC
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      throw posixFailure("open", url.path)
    }
    defer { Darwin.close(fd) }

    // S12: fstat must be a regular file <= 64 KiB
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw posixFailure("fstat", url.path)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw .unsafePath("hub.json is not a regular file.")
    }
    guard info.st_size <= 64 * 1024 else {
      throw .invalid("hub.json is larger than 64 KiB.")
    }

    // S12: Read loop until EOF or 64 KiB + 1 bytes (handle short reads)
    let maxReadSize = 64 * 1024 + 1
    var buffer = [UInt8]()
    var totalRead = 0
    while totalRead < maxReadSize {
      let chunkSize = min(4096, maxReadSize - totalRead)
      var chunk = [UInt8](repeating: 0, count: chunkSize)
      let bytesRead = Darwin.read(fd, &chunk, chunkSize)

      if bytesRead < 0 {
        throw posixFailure("read", url.path)
      }
      if bytesRead == 0 {
        break // EOF
      }

      buffer.append(contentsOf: chunk.prefix(bytesRead))
      totalRead += bytesRead
    }

    // Check that total bytes read does not exceed 64 KiB
    guard totalRead <= 64 * 1024 else {
      throw .invalid("hub.json: larger than 64 KiB")
    }

    guard !buffer.isEmpty else {
      throw .io("Cannot read hub.json")
    }

    let data = Data(buffer)

    let decoder = JSONDecoder()

    // S12: Key check with dynamic CodingKey struct (AnyKey to capture all keys)
    struct AnyKey: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init?(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }

    struct Keys: Decodable {
      let names: Set<String>
      init(from d: Decoder) throws {
        let c = try d.container(keyedBy: AnyKey.self)
        names = Set(c.allKeys.map(\.stringValue))
      }
    }

    var validationError: HubError?
    do {
      let keys = try decoder.decode(Keys.self, from: data)
      let allowedKeys = Set(["schemaVersion", "prefix", "runtime", "runtimeManifestSHA256", "generation"])
      let unknownKeys = keys.names.subtracting(allowedKeys)
      if !unknownKeys.isEmpty {
        validationError = .invalid("Unknown keys in hub.json: \(unknownKeys.sorted().joined(separator: ", "))")
      }
    } catch {
      validationError = .invalid("Cannot parse hub.json: \(error)")
    }

    if let error = validationError {
      throw error
    }

    // Decode as HubConfig
    let config: HubConfig
    do {
      config = try decoder.decode(HubConfig.self, from: data)
    } catch {
      throw .invalid("Cannot decode hub.json: \(error)")
    }

    // Validate
    try config.validate()
    return config
  }

  /// Writes the Hub configuration to a file atomically.
  /// S12: Calls validate() first.
  package func write(to url: URL) throws(HubError) {
    // S12: Validate before writing
    try validate()

    // Check that parent directory exists
    let parent = url.deletingLastPathComponent()
    var info = stat()
    guard lstat(parent.path, &info) == 0 else {
      throw .invalid("Parent directory does not exist: \(parent.path)")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(self)
    } catch {
      throw .io("Cannot encode hub.json: \(error)")
    }

    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw posixFailure("write", url.path)
    }
  }

  // MARK: - Private validation

  private func validate() throws(HubError) {
    // Validate schemaVersion
    guard schemaVersion == 1 else {
      throw .invalid("schemaVersion must be 1, got \(schemaVersion).")
    }

    // Validate prefix: must be absolute and without .. components
    guard prefix.starts(with: "/") else {
      throw .invalid("prefix must be absolute.")
    }
    let components = prefix.split(separator: "/", omittingEmptySubsequences: true)
    for component in components {
      guard component != ".." else {
        throw .invalid("prefix cannot contain .. components.")
      }
    }

    // Validate runtime id
    let bytes = runtime.utf8
    guard bytes.count >= 1, bytes.count <= 48 else {
      throw .invalid("runtime id must be 1 to 48 characters long.")
    }
    for (index, byte) in bytes.enumerated() {
      let isDigit = byte >= 0x30 && byte <= 0x39
      let isLowercase = byte >= 0x61 && byte <= 0x7A
      let isHyphen = byte == 0x2D
      let isValid = isLowercase || isDigit || (isHyphen && index > 0)
      guard isValid else {
        throw .invalid("runtime id must match ^[a-z0-9][a-z0-9-]{0,47}$.")
      }
    }

    // Validate runtimeManifestSHA256: 64 lowercase hex characters
    guard runtimeManifestSHA256.count == 64 else {
      throw .invalid("runtimeManifestSHA256 must be 64 characters long.")
    }
    for char in runtimeManifestSHA256 {
      let isHexDigit = (char >= "0" && char <= "9") || (char >= "a" && char <= "f")
      guard isHexDigit else {
        throw .invalid("runtimeManifestSHA256 must be lowercase hex.")
      }
    }

    // Validate generation: 0...1000
    guard generation >= 0 && generation <= 1000 else {
      throw .invalid("generation must be between 0 and 1000.")
    }
  }
}
