import Foundation

// MARK: - Recipe-related types

/// Recipe kind.
package enum RecipeKind: String, Codable, Sendable, CaseIterable {
  case game
  case provider
}

/// Recipe status.
package enum RecipeStatus: String, Codable, Sendable, CaseIterable {
  case verified
  case unverified
  case proposed
}

/// Architecture.
package enum Architecture: String, Codable, Sendable, CaseIterable {
  case i386
  case x86_64
}

/// Store IDs for a recipe.
package struct StoreIDs: Codable, Equatable, Sendable {
  package let eaOfferIDs: [String]?
  package let steamAppID: String?
  package let epicAppName: String?
  package let ubisoftID: String?

  package init(
    eaOfferIDs: [String]? = nil, steamAppID: String? = nil, epicAppName: String? = nil,
    ubisoftID: String? = nil
  ) {
    self.eaOfferIDs = eaOfferIDs
    self.steamAppID = steamAppID
    self.epicAppName = epicAppName
    self.ubisoftID = ubisoftID
  }

  /// Validates these store IDs.
  package func validate() throws(HubError) {
    if let ids = eaOfferIDs {
      guard (1...32).contains(ids.count) else {
        throw HubError.invalid("StoreIDs.eaOfferIDs: must have 1 to 32 IDs")
      }
      for id in ids {
        guard Check.ascii(id, 1...64, first: { b in
          (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x3a || b == 0x2e || b == 0x5f || b == 0x2d
        }, rest: { b in
          (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x3a || b == 0x2e || b == 0x5f || b == 0x2d
        }) else {
          throw HubError.invalid("StoreIDs.eaOfferID: invalid format")
        }
      }
    }

    if let id = steamAppID {
      guard Check.ascii(id, 1...10, first: { b in
        b >= 0x30 && b <= 0x39
      }, rest: { b in
        b >= 0x30 && b <= 0x39
      }) else {
        throw HubError.invalid("StoreIDs.steamAppID: invalid format")
      }
    }

    if let name = epicAppName {
      guard Check.ascii(name, 1...64, first: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f || b == 0x2e || b == 0x2d
      }, rest: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f || b == 0x2e || b == 0x2d
      }) else {
        throw HubError.invalid("StoreIDs.epicAppName: invalid format")
      }
    }

    if let id = ubisoftID {
      guard Check.ascii(id, 1...10, first: { b in
        b >= 0x30 && b <= 0x39
      }, rest: { b in
        b >= 0x30 && b <= 0x39
      }) else {
        throw HubError.invalid("StoreIDs.ubisoftID: invalid format")
      }
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["eaOfferIDs", "steamAppID", "epicAppName", "ubisoftID"],
      type: "StoreIDs")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.eaOfferIDs = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "eaOfferIDs"))
    self.steamAppID = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "steamAppID"))
    self.epicAppName = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "epicAppName"))
    self.ubisoftID = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "ubisoftID"))
  }
}

/// A location where a game or program can be found.
package enum Location: Codable, Equatable, Sendable {
  case windowsPath(path: String)
  case registry(hive: String, key: String, name: String)
  case hostPath(path: String)

  /// Validates this location.
  package func validate() throws(HubError) {
    switch self {
    case .windowsPath(let path):
      guard (3...240).contains(path.utf8.count) else {
        throw HubError.invalid("Location.windowsPath: must be 3 to 240 bytes")
      }
      guard path.utf8.count >= 3 && Check.ascii(String(path.prefix(1)), 1...1, first: { b in
        (b >= 0x43 && b <= 0x5A) || (b >= 0x63 && b <= 0x7A)  // C-Z or c-z
      }, rest: { _ in false }) && path.dropFirst().starts(with: ":\\") else {
        throw HubError.invalid("Location.windowsPath: must start with drive letter")
      }
      for scalar in path.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
          throw HubError.invalid("Location.windowsPath: may not contain control characters")
        }
      }
      // Split on both \ and / when checking for .. components
      let backslashComponents = path.split(separator: "\\", omittingEmptySubsequences: false)
      for component in backslashComponents {
        let forwardSlashComponents = component.split(separator: "/", omittingEmptySubsequences: false)
        for subComponent in forwardSlashComponents {
          guard subComponent != ".." else {
            throw HubError.invalid("Location.windowsPath: may not contain .. component")
          }
        }
      }

    case .registry(let hive, let key, let name):
      guard hive == "user" || hive == "machine" else {
        throw HubError.invalid("Location.registry.hive: must be user or machine")
      }
      guard (1...255).contains(key.utf8.count) else {
        throw HubError.invalid("Location.registry.key: must be 1 to 255 bytes")
      }
      for scalar in key.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || scalar == "]" || scalar == "/" {
          throw HubError.invalid("Location.registry.key: invalid character")
        }
      }
      guard !key.hasPrefix("\\") && !key.hasSuffix("\\") else {
        throw HubError.invalid("Location.registry.key: must not start or end with backslash")
      }
      let keyComponents = key.split(separator: "\\", omittingEmptySubsequences: false)
      for component in keyComponents {
        guard !component.isEmpty else {
          throw HubError.invalid("Location.registry.key: may not have empty components")
        }
      }

      let softwarePrefix = "Software\\"
      let machinePrefix = "System\\CurrentControlSet\\Control\\Session Manager\\Environment"
      if hive == "user" {
        guard key.hasPrefix(softwarePrefix) else {
          throw HubError.invalid("Location.registry.key: user hive must start with Software\\")
        }
      } else {
        if key.hasPrefix(machinePrefix) {
          guard key == machinePrefix || key.hasPrefix(machinePrefix + "\\") else {
            throw HubError.invalid("Location.registry.key: machine hive System prefix must be exact or continue with backslash")
          }
        } else {
          guard key.hasPrefix(softwarePrefix) else {
            throw HubError.invalid("Location.registry.key: machine hive must start with Software\\ or System\\CurrentControlSet\\Control\\Session Manager\\Environment")
          }
        }
      }
      try Check.registryValueName(name, field: "Location.registry.name")

    case .hostPath(let path):
      guard path.hasPrefix("/") else {
        throw HubError.invalid("Location.hostPath: must be absolute")
      }
      for scalar in path.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
          throw HubError.invalid("Location.hostPath: may not contain control characters")
        }
      }
      let components = path.split(separator: "/", omittingEmptySubsequences: false)
      for component in components {
        guard component != ".." else {
          throw HubError.invalid("Location.hostPath: may not contain .. component")
        }
      }
    }
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    guard let kindKey = container.allKeys.first(where: { $0.stringValue == "kind" }) else {
      throw HubError.invalid("Location: missing kind field")
    }
    let kind = try container.decode(String.self, forKey: kindKey)

    switch kind {
    case "windowsPath":
      let allowed: Set<String> = ["kind", "path"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "Location.windowsPath")
      let path = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "path"))
      self = .windowsPath(path: path)

    case "registry":
      let allowed: Set<String> = ["kind", "hive", "key", "name"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "Location.registry")
      let hive = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "hive"))
      let key = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "key"))
      let name = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "name"))
      self = .registry(hive: hive, key: key, name: name)

    case "hostPath":
      let allowed: Set<String> = ["kind", "path"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "Location.hostPath")
      let path = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "path"))
      self = .hostPath(path: path)

    default:
      throw HubError.invalid("Location: unknown kind \(kind)")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: AnyCodingKey.self)
    switch self {
    case .windowsPath(let path):
      try container.encode("windowsPath", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(path, forKey: AnyCodingKey(stringValue: "path"))
    case .registry(let hive, let key, let name):
      try container.encode("registry", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(hive, forKey: AnyCodingKey(stringValue: "hive"))
      try container.encode(key, forKey: AnyCodingKey(stringValue: "key"))
      try container.encode(name, forKey: AnyCodingKey(stringValue: "name"))
    case .hostPath(let path):
      try container.encode("hostPath", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(path, forKey: AnyCodingKey(stringValue: "path"))
    }
  }
}

/// Launch method.
package enum LaunchMethod: String, Codable, Sendable, CaseIterable {
  case direct
  case provider
  case browser
  case wrapper
}

/// Launch configuration.
package struct Launch: Codable, Equatable, Sendable {
  package let method: LaunchMethod
  package let executable: String?
  package let arguments: [String]
  package let urlTemplate: String?

  package init(
    method: LaunchMethod, executable: String? = nil, arguments: [String] = [],
    urlTemplate: String? = nil
  ) {
    self.method = method
    self.executable = executable
    self.arguments = arguments
    self.urlTemplate = urlTemplate
  }

  /// Validates this launch configuration.
  package func validate() throws(HubError) {
    if let executable = executable {
      try Check.exe(executable, field: "Launch.executable")
    }

    if let urlTemplate = urlTemplate {
      guard (1...512).contains(urlTemplate.utf8.count) else {
        throw HubError.invalid("Launch.urlTemplate: must be 1 to 512 bytes")
      }
      guard let colonIndex = urlTemplate.firstIndex(of: ":") else {
        throw HubError.invalid("Launch.urlTemplate: must contain :")
      }
      let scheme = String(urlTemplate[..<colonIndex])
      let validSchemes = Set(["origin2", "link2ea", "steam", "com.epicgames.launcher", "uplay"])
      guard validSchemes.contains(scheme) else {
        throw HubError.invalid("Launch.urlTemplate: invalid scheme")
      }
      for scalar in urlTemplate.unicodeScalars {
        let value = scalar.value
        if (value >= 0x0000 && value <= 0x001f) || value == 0x007f || value == 0x20 {  // control chars or space
          throw HubError.invalid("Launch.urlTemplate: may not contain control characters or spaces")
        }
      }
      try Check.placeholders(urlTemplate, field: "Launch.urlTemplate")
    }

    guard (0...16).contains(arguments.count) else {
      throw HubError.invalid("Launch.arguments: must have 0 to 16 arguments")
    }
    for (i, arg) in arguments.enumerated() {
      guard (1...256).contains(arg.utf8.count) else {
        throw HubError.invalid("Launch.arguments[\(i)]: must be 1 to 256 bytes")
      }
      for scalar in arg.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
          throw HubError.invalid("Launch.arguments[\(i)]: may not contain control characters")
        }
      }
      try Check.placeholders(arg, field: "Launch.arguments[\(i)]")
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["method", "executable", "arguments", "urlTemplate"], type: "Launch")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.method = try container.decode(
      LaunchMethod.self, forKey: AnyCodingKey(stringValue: "method"))
    self.executable = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "executable"))
    self.arguments = try container.decode(
      [String].self, forKey: AnyCodingKey(stringValue: "arguments"))
    self.urlTemplate = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "urlTemplate"))
  }
}

/// Stop configuration.
package struct Stop: Codable, Equatable, Sendable {
  package let arguments: [String]?
  package let taskkill: [String]

  package init(arguments: [String]? = nil, taskkill: [String]) {
    self.arguments = arguments
    self.taskkill = taskkill
  }

  /// Validates this stop configuration.
  package func validate() throws(HubError) {
    if let arguments = arguments {
      guard (1...16).contains(arguments.count) else {
        throw HubError.invalid("Stop.arguments: must have 1 to 16 arguments")
      }
      for (i, arg) in arguments.enumerated() {
        guard (1...256).contains(arg.utf8.count) else {
          throw HubError.invalid("Stop.arguments[\(i)]: must be 1 to 256 bytes")
        }
        for scalar in arg.unicodeScalars {
          let v = scalar.value
          if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
            throw HubError.invalid("Stop.arguments[\(i)]: may not contain control characters")
          }
        }
        try Check.placeholders(arg, field: "Stop.arguments[\(i)]")
      }
    }
    guard (1...16).contains(taskkill.count) else {
      throw HubError.invalid("Stop.taskkill: must have 1 to 16 executables")
    }
    for exe in taskkill {
      try Check.exe(exe, field: "Stop.taskkill")
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["arguments", "taskkill"], type: "Stop")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.arguments = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "arguments"))
    self.taskkill = try container.decode(
      [String].self, forKey: AnyCodingKey(stringValue: "taskkill"))
  }
}

/// Checksum policy.
package enum ChecksumPolicy: String, Codable, Sendable, CaseIterable {
  case pinned
  case authenticodeRecord
}

/// Checksum information.
package struct Checksum: Codable, Equatable, Sendable {
  package let policy: ChecksumPolicy
  package let sha256: String?
  package let signer: String?

  package init(policy: ChecksumPolicy, sha256: String? = nil, signer: String? = nil) {
    self.policy = policy
    self.sha256 = sha256
    self.signer = signer
  }

  /// Validates this checksum.
  package func validate() throws(HubError) {
    switch policy {
    case .pinned:
      guard let sha256 = sha256 else {
        throw HubError.invalid("Checksum.pinned: requires sha256")
      }
      try Check.sha256(sha256, field: "Checksum.sha256")
    case .authenticodeRecord:
      guard let signer = signer else {
        throw HubError.invalid("Checksum.authenticodeRecord: requires signer")
      }
      try Check.text(signer, field: "Checksum.signer", max: 120)
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["policy", "sha256", "signer"], type: "Checksum")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.policy = try container.decode(
      ChecksumPolicy.self, forKey: AnyCodingKey(stringValue: "policy"))
    self.sha256 = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "sha256"))
    self.signer = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "signer"))
  }
}

/// Install configuration.
package struct Install: Codable, Equatable, Sendable {
  package let url: String
  package let page: String
  package let checksum: Checksum
  package let command: [String]

  package init(url: String, page: String, checksum: Checksum, command: [String]) {
    self.url = url
    self.page = page
    self.checksum = checksum
    self.command = command
  }

  /// Validates this install configuration.
  package func validate() throws(HubError) {
    guard url.hasPrefix("https://") else {
      throw HubError.invalid("Install.url: must start with https://")
    }
    guard url.utf8.count <= 400 else {
      throw HubError.invalid("Install.url: must be at most 400 bytes")
    }
    for scalar in url.unicodeScalars {
      let v = scalar.value
      if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || v == 0x20 {
        throw HubError.invalid("Install.url: may not contain control characters or spaces")
      }
    }
    guard page.hasPrefix("https://") else {
      throw HubError.invalid("Install.page: must start with https://")
    }
    guard page.utf8.count <= 400 else {
      throw HubError.invalid("Install.page: must be at most 400 bytes")
    }
    for scalar in page.unicodeScalars {
      let v = scalar.value
      if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || v == 0x20 {
        throw HubError.invalid("Install.page: may not contain control characters or spaces")
      }
    }
    try checksum.validate()
    guard (1...16).contains(command.count) else {
      throw HubError.invalid("Install.command: must have 1 to 16 arguments")
    }
    for (i, arg) in command.enumerated() {
      guard (1...256).contains(arg.utf8.count) else {
        throw HubError.invalid("Install.command[\(i)]: must be 1 to 256 bytes")
      }
      for scalar in arg.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
          throw HubError.invalid("Install.command[\(i)]: may not contain control characters")
        }
      }
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["url", "page", "checksum", "command"], type: "Install")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.url = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "url"))
    self.page = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "page"))
    self.checksum = try container.decode(
      Checksum.self, forKey: AnyCodingKey(stringValue: "checksum"))
    self.command = try container.decode(
      [String].self, forKey: AnyCodingKey(stringValue: "command"))
  }
}

/// Setting store type.
package enum SettingStore: String, Codable, Sendable, CaseIterable {
  case hub
  case ini
  case registry
}

/// Type of a setting.
package enum SettingType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case bool
  case choice
  case int
  case float
  case string
}

/// A setting that can be configured.
package struct Setting: Codable, Equatable, Sendable {
  package let id: String
  package let title: String
  package let group: String
  package let store: SettingStore
  package let file: String?
  package let section: String?
  package let key: String?
  package let type: SettingType
  package let defaultValue: String
  package let choices: [String]?
  package let range: [Double]?

  package init(
    id: String, title: String, group: String, store: SettingStore,
    file: String? = nil, section: String? = nil, key: String? = nil,
    type: SettingType, defaultValue: String,
    choices: [String]? = nil, range: [Double]? = nil
  ) {
    self.id = id
    self.title = title
    self.group = group
    self.store = store
    self.file = file
    self.section = section
    self.key = key
    self.type = type
    self.defaultValue = defaultValue
    self.choices = choices
    self.range = range
  }

  /// Validates this setting.
  package func validate() throws(HubError) {
    try Check.id(id, field: "Setting.id")
    try Check.text(title, field: "Setting.title", max: .max)
    try Check.text(group, field: "Setting.group", max: .max)

    guard defaultValue.utf8.count <= 512 else {
      throw HubError.invalid("Setting.defaultValue: must be at most 512 bytes")
    }
    for scalar in defaultValue.unicodeScalars {
      let value = scalar.value
      if (value >= 0x0000 && value <= 0x001f) || value == 0x007f {
        throw HubError.invalid("Setting.defaultValue: may not contain control characters")
      }
    }

    switch store {
    case .ini:
      guard let file = file, let section = section, let key = key else {
        throw HubError.invalid("Setting: ini store requires file, section, and key")
      }
      try Check.destination(file, field: "Setting.file")
      guard (1...128).contains(section.utf8.count) else {
        throw HubError.invalid("Setting.section: must be 1 to 128 bytes")
      }
      for scalar in section.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || scalar == "]" {
          throw HubError.invalid("Setting.section: invalid character")
        }
      }
      guard (1...128).contains(key.utf8.count) else {
        throw HubError.invalid("Setting.key: must be 1 to 128 bytes")
      }
      for scalar in key.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || scalar == "=" {
          throw HubError.invalid("Setting.key: invalid character")
        }
      }

    case .registry:
      guard let key = key, let section = section else {
        throw HubError.invalid("Setting: registry store requires key and section")
      }
      try Check.registryKey(key, hive: "machine", field: "Setting.key")
      try Check.registryValueName(section, field: "Setting.section")

    case .hub:
      guard file == nil && section == nil && key == nil else {
        throw HubError.invalid("Setting: hub store must not have file, section, or key")
      }
    }

    switch type {
    case .bool:
      guard defaultValue == "true" || defaultValue == "false" else {
        throw HubError.invalid("Setting.defaultValue: bool must be true or false")
      }
    case .choice:
      guard let choices = choices, (2...16).contains(choices.count) else {
        throw HubError.invalid("Setting.choices: must have 2 to 16 choices for choice type")
      }
      for choice in choices {
        guard choice.utf8.count <= 512 else {
          throw HubError.invalid("Setting.choices: each choice must be at most 512 bytes")
        }
        for scalar in choice.unicodeScalars {
          let v = scalar.value
          if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
            throw HubError.invalid("Setting.choices: may not contain control characters")
          }
        }
      }
      guard choices.contains(defaultValue) else {
        throw HubError.invalid("Setting.defaultValue: must be in choices")
      }
    case .int:
      guard let rangeArray = range, rangeArray.count == 2 else {
        throw HubError.invalid("Setting.range: must have exactly 2 elements for int")
      }
      guard rangeArray[0] < rangeArray[1] else {
        throw HubError.invalid("Setting.range: lower bound must be less than upper bound")
      }
      if let val = Int(defaultValue) {
        guard (rangeArray[0]...rangeArray[1]).contains(Double(val)) else {
          throw HubError.invalid("Setting.defaultValue: must be within range")
        }
      } else {
        throw HubError.invalid("Setting.defaultValue: must be a valid integer")
      }
    case .float:
      guard let rangeArray = range, rangeArray.count == 2 else {
        throw HubError.invalid("Setting.range: must have exactly 2 elements for float")
      }
      guard rangeArray[0] < rangeArray[1] else {
        throw HubError.invalid("Setting.range: lower bound must be less than upper bound")
      }
      if let val = Double(defaultValue) {
        guard (rangeArray[0]...rangeArray[1]).contains(val) else {
          throw HubError.invalid("Setting.defaultValue: must be within range")
        }
      } else {
        throw HubError.invalid("Setting.defaultValue: must be a valid number")
      }
    case .string:
      break
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder,
      allowed: [
        "id", "title", "group", "store", "file", "section", "key", "type", "default",
        "choices", "range"
      ],
      type: "Setting")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.title = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "title"))
    self.group = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "group"))
    self.store = try container.decode(
      SettingStore.self, forKey: AnyCodingKey(stringValue: "store"))
    self.file = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "file"))
    self.section = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "section"))
    self.key = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "key"))
    self.type = try container.decode(SettingType.self, forKey: AnyCodingKey(stringValue: "type"))
    self.defaultValue = try container.decode(
      String.self, forKey: AnyCodingKey(stringValue: "default"))
    self.choices = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "choices"))
    self.range = try container.decodeIfPresent(
      [Double].self, forKey: AnyCodingKey(stringValue: "range"))
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: AnyCodingKey.self)
    try container.encode(id, forKey: AnyCodingKey(stringValue: "id"))
    try container.encode(title, forKey: AnyCodingKey(stringValue: "title"))
    try container.encode(group, forKey: AnyCodingKey(stringValue: "group"))
    try container.encode(store, forKey: AnyCodingKey(stringValue: "store"))
    try container.encodeIfPresent(file, forKey: AnyCodingKey(stringValue: "file"))
    try container.encodeIfPresent(section, forKey: AnyCodingKey(stringValue: "section"))
    try container.encodeIfPresent(key, forKey: AnyCodingKey(stringValue: "key"))
    try container.encode(type, forKey: AnyCodingKey(stringValue: "type"))
    try container.encode(defaultValue, forKey: AnyCodingKey(stringValue: "default"))
    try container.encodeIfPresent(choices, forKey: AnyCodingKey(stringValue: "choices"))
    try container.encodeIfPresent(range, forKey: AnyCodingKey(stringValue: "range"))
  }
}

/// A recipe for a game or provider.
package struct Recipe: Codable, Equatable, Sendable {
  package let schemaVersion: Int
  package let id: String
  package let kind: RecipeKind
  package let title: String
  package let status: RecipeStatus
  package let evidence: [String]
  package let provider: ProviderID?
  package let ids: StoreIDs?
  package let location: Location?
  package let executable: String?
  package let architecture: Architecture?
  package let processes: [String]
  package let leaseTarget: String?
  package let launchChain: [String]?
  package let launch: Launch
  package let stop: Stop?
  package let readiness: Readiness?
  package let fixes: [String]
  package let settings: [Setting]
  package let install: Install?
  package let legacyWrapper: String?

  package init(
    schemaVersion: Int, id: String, kind: RecipeKind, title: String,
    status: RecipeStatus, evidence: [String] = [], provider: ProviderID? = nil,
    ids: StoreIDs? = nil, location: Location? = nil, executable: String? = nil,
    architecture: Architecture? = nil, processes: [String] = [], leaseTarget: String? = nil,
    launchChain: [String]? = nil, launch: Launch, stop: Stop? = nil,
    readiness: Readiness? = nil, fixes: [String] = [], settings: [Setting] = [],
    install: Install? = nil, legacyWrapper: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.kind = kind
    self.title = title
    self.status = status
    self.evidence = evidence
    self.provider = provider
    self.ids = ids
    self.location = location
    self.executable = executable
    self.architecture = architecture
    self.processes = processes
    self.leaseTarget = leaseTarget
    self.launchChain = launchChain
    self.launch = launch
    self.stop = stop
    self.readiness = readiness
    self.fixes = fixes
    self.settings = settings
    self.install = install
    self.legacyWrapper = legacyWrapper
  }

  /// Validates this recipe.
  package func validate() throws(HubError) {
    guard schemaVersion == 1 else {
      throw HubError.invalid("Recipe.schemaVersion: must be 1")
    }

    try Check.id(id, field: "Recipe.id")
    try Check.text(title, field: "Recipe.title", max: 80)

    if kind == .provider {
      guard let provider = provider, provider != .none else {
        throw HubError.invalid("Recipe: provider kind requires non-none provider")
      }
      guard stop != nil else {
        throw HubError.invalid("Recipe: provider kind requires stop")
      }
      guard readiness != nil else {
        throw HubError.invalid("Recipe: provider kind requires readiness")
      }
      guard executable != nil else {
        throw HubError.invalid("Recipe: provider kind requires executable")
      }
    }

    if let executable = executable {
      try Check.exe(executable, field: "Recipe.executable")
    }

    for process in processes {
      try Check.exe(process, field: "Recipe.processes")
    }

    if let leaseTarget = leaseTarget {
      try Check.exe(leaseTarget, field: "Recipe.leaseTarget")
    }

    if let launchChain = launchChain {
      for exe in launchChain {
        try Check.exe(exe, field: "Recipe.launchChain")
      }
    }

    if launch.method == .provider {
      guard let provider = provider, provider != .none else {
        throw HubError.invalid("Recipe: launch method provider requires non-none provider")
      }
    }

    if launch.method == .wrapper {
      guard let legacyWrapper = legacyWrapper else {
        throw HubError.invalid("Recipe: wrapper launch method requires legacyWrapper")
      }
      try Check.text(legacyWrapper, field: "Recipe.legacyWrapper", max: 120)
    } else {
      guard legacyWrapper == nil else {
        throw HubError.invalid("Recipe: legacyWrapper only allowed with wrapper launch method")
      }
    }

    guard (0...8).contains(evidence.count) else {
      throw HubError.invalid("Recipe.evidence: must have 0 to 8 entries")
    }
    for (i, ev) in evidence.enumerated() {
      try Check.text(ev, field: "Recipe.evidence[\(i)]", max: 300)
    }

    if status == .verified {
      guard !evidence.isEmpty else {
        throw HubError.invalid("Recipe: verified status requires at least 1 evidence")
      }
    }

    try ids?.validate()
    try location?.validate()
    try launch.validate()
    try stop?.validate()
    try readiness?.validate()
    try install?.validate()

    var settingIDs = Set<String>()
    for setting in settings {
      try setting.validate()
      guard !settingIDs.contains(setting.id) else {
        throw HubError.invalid("Recipe.settings: duplicate id")
      }
      settingIDs.insert(setting.id)
    }

    var fixIDs = Set<String>()
    for fixID in fixes {
      try Check.id(fixID, field: "Recipe.fixes")
      guard !fixIDs.contains(fixID) else {
        throw HubError.invalid("Recipe.fixes: duplicate id")
      }
      fixIDs.insert(fixID)
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder,
      allowed: [
        "schemaVersion", "id", "kind", "title", "status", "evidence", "provider", "ids",
        "location", "executable", "architecture", "processes", "leaseTarget", "launchChain",
        "launch", "stop", "readiness", "fixes", "settings", "install", "legacyWrapper"
      ],
      type: "Recipe")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.schemaVersion = try container.decode(
      Int.self, forKey: AnyCodingKey(stringValue: "schemaVersion"))
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.kind = try container.decode(RecipeKind.self, forKey: AnyCodingKey(stringValue: "kind"))
    self.title = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "title"))
    self.status = try container.decode(
      RecipeStatus.self, forKey: AnyCodingKey(stringValue: "status"))
    self.evidence = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "evidence")) ?? []
    self.provider = try container.decodeIfPresent(
      ProviderID.self, forKey: AnyCodingKey(stringValue: "provider"))
    self.ids = try container.decodeIfPresent(
      StoreIDs.self, forKey: AnyCodingKey(stringValue: "ids"))
    self.location = try container.decodeIfPresent(
      Location.self, forKey: AnyCodingKey(stringValue: "location"))
    self.executable = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "executable"))
    self.architecture = try container.decodeIfPresent(
      Architecture.self, forKey: AnyCodingKey(stringValue: "architecture"))
    self.processes = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "processes")) ?? []
    self.leaseTarget = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "leaseTarget"))
    self.launchChain = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "launchChain"))
    self.launch = try container.decode(
      Launch.self, forKey: AnyCodingKey(stringValue: "launch"))
    self.stop = try container.decodeIfPresent(
      Stop.self, forKey: AnyCodingKey(stringValue: "stop"))
    self.readiness = try container.decodeIfPresent(
      Readiness.self, forKey: AnyCodingKey(stringValue: "readiness"))
    self.fixes = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "fixes")) ?? []
    self.settings = try container.decodeIfPresent(
      [Setting].self, forKey: AnyCodingKey(stringValue: "settings")) ?? []
    self.install = try container.decodeIfPresent(
      Install.self, forKey: AnyCodingKey(stringValue: "install"))
    self.legacyWrapper = try container.decodeIfPresent(
      String.self, forKey: AnyCodingKey(stringValue: "legacyWrapper"))
  }
}
