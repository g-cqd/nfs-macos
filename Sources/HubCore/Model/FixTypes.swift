import Foundation
import LauncherCore

// MARK: - FixAction

/// An action that fixes a problem or configures the runtime.
package enum FixAction: Codable, Equatable, Sendable {
  case env(name: String, value: String, scope: EnvScope)
  case renderer(exe: String, api: String, backend: String)
  case dllOverride(exe: String?, dll: String, mode: String)
  case registry(hive: String, key: String, name: String, type: String, value: String)
  case file(asset: String, destination: String, sha256: String)
  case ini(file: String, section: String, key: String, value: String)
  case drive(letter: String, target: String, lifetime: String)
  case arguments(exe: String, append: [String])
  case sidecar(enabled: Bool)
  case window(mode: String, size: String?, enabled: Bool?, exe: String?)
  case prerequisite(id: String)
  case companion(exe: String, after: String, readiness: Readiness)
  case xmlAttribute(file: String, element: String, attribute: String, value: String)

  /// Validates this action.
  package func validate() throws(HubError) {
    switch self {
    case .env(let name, let value, _):
      guard Check.ascii(name, 2...64, first: { b in
        b >= 0x41 && b <= 0x5a  // A-Z
      }, rest: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x30 && b <= 0x39) || b == 0x5f  // A-Z, 0-9, _
      }) else {
        throw HubError.invalid("FixAction.env.name: must match ^[A-Z][A-Z0-9_]{1,63}$")
      }
      guard (1...512).contains(value.utf8.count) else {
        throw HubError.invalid("FixAction.env.value: must be 1 to 512 bytes")
      }
      for scalar in value.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
          throw HubError.invalid("FixAction.env.value: may not contain control characters")
        }
      }

    case .renderer(let exe, let api, let backend):
      if exe != "*" {
        try Check.exe(exe, field: "FixAction.renderer.exe")
      }
      guard backend == "dxmt" || backend == "wined3d" || backend == "mtld3d" else {
        throw HubError.invalid("FixAction.renderer.backend: must be dxmt, wined3d, or mtld3d")
      }
      let selection = RendererSelection(api: api, backend: backend, executable: exe == "*" ? nil : exe)
      do {
        try selection.validate()
      } catch let LauncherError.operation(msg) {
        throw HubError.invalid("FixAction.renderer: \(msg)")
      } catch {
        throw HubError.invalid("FixAction.renderer: validation failed")
      }

    case .dllOverride(let exe, let dll, let mode):
      let validModes = Set(["native,builtin", "builtin", "native", "builtin,native", "disabled"])
      guard validModes.contains(mode) else {
        throw HubError.invalid("FixAction.dllOverride.mode: invalid mode")
      }
      if exe == nil {
        guard mode == "disabled" && dll.lowercased().hasSuffix(".exe") else {
          throw HubError.invalid("FixAction.dllOverride: exe-less override only allowed with mode disabled and dll ending .exe")
        }
      } else {
        try Check.exe(exe!, field: "FixAction.dllOverride.exe")
      }
      guard Check.ascii(dll, 1...64, first: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f || b == 0x2e || b == 0x2d
      }, rest: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f || b == 0x2e || b == 0x2d
      }) else {
        throw HubError.invalid("FixAction.dllOverride.dll: invalid format")
      }

    case .registry(let hive, let key, let name, let type, let value):
      guard hive == "user" || hive == "machine" else {
        throw HubError.invalid("FixAction.registry.hive: must be user or machine")
      }
      try Check.registryKey(key, hive: hive, field: "FixAction.registry.key")
      try Check.registryValueName(name, field: "FixAction.registry.name")
      guard type == "string" || type == "dword" else {
        throw HubError.invalid("FixAction.registry.type: must be string or dword")
      }
      if type == "dword" {
        if value.hasPrefix("0x") {
          let hexPart = String(value.dropFirst(2))
          guard (1...8).contains(hexPart.utf8.count) else {
            throw HubError.invalid("FixAction.registry.value: hex must be 1 to 8 chars")
          }
          guard Check.ascii(hexPart, 1...8, first: { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
          }, rest: { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
          }) else {
            throw HubError.invalid("FixAction.registry.value: invalid hex")
          }
        } else {
          guard Check.ascii(value, 1...10, first: { b in
            b >= 0x30 && b <= 0x39
          }, rest: { b in
            b >= 0x30 && b <= 0x39
          }) else {
            throw HubError.invalid("FixAction.registry.value: must be decimal")
          }
          guard let num = UInt64(value), num <= 4294967295 else {
            throw HubError.invalid("FixAction.registry.value: must be 0 to 4294967295")
          }
        }
      } else {
        guard value.utf8.count <= 1024 else {
          throw HubError.invalid("FixAction.registry.value: must be at most 1024 bytes")
        }
        for scalar in value.unicodeScalars {
          let v = scalar.value
          if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
            throw HubError.invalid("FixAction.registry.value: may not contain control characters")
          }
        }
        try Check.placeholders(value, field: "FixAction.registry.value")
      }

    case .file(let asset, let destination, let sha256):
      try Check.relativePath(asset, field: "FixAction.file.asset")
      try Check.destination(destination, field: "FixAction.file.destination")
      try Check.sha256(sha256, field: "FixAction.file.sha256")

    case .ini(let file, let section, let key, let value):
      try Check.destination(file, field: "FixAction.ini.file")
      guard (1...128).contains(section.utf8.count) else {
        throw HubError.invalid("FixAction.ini.section: must be 1 to 128 bytes")
      }
      for scalar in section.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || scalar == "]" {
          throw HubError.invalid("FixAction.ini.section: invalid character")
        }
      }
      guard (1...128).contains(key.utf8.count) else {
        throw HubError.invalid("FixAction.ini.key: must be 1 to 128 bytes")
      }
      for scalar in key.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f || scalar == "=" {
          throw HubError.invalid("FixAction.ini.key: invalid character")
        }
      }
      guard value.utf8.count <= 512 else {
        throw HubError.invalid("FixAction.ini.value: must be at most 512 bytes")
      }
      for scalar in value.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
          throw HubError.invalid("FixAction.ini.value: may not contain control characters")
        }
      }

    case .drive(let letter, let target, let lifetime):
      guard Check.ascii(letter, 1...1, first: { b in
        b >= 0x64 && b <= 0x79  // d-y (lowercase only)
      }, rest: { _ in false }) else {
        throw HubError.invalid("FixAction.drive.letter: must be d-y")
      }
      guard target == "{hubRoot}" || target == "{gameRoot}" else {
        throw HubError.invalid("FixAction.drive.target: must be {hubRoot} or {gameRoot}")
      }
      guard lifetime == "session" || lifetime == "persistent" else {
        throw HubError.invalid("FixAction.drive.lifetime: must be session or persistent")
      }

    case .arguments(let exe, let append):
      try Check.exe(exe, field: "FixAction.arguments.exe")
      guard (1...16).contains(append.count) else {
        throw HubError.invalid("FixAction.arguments.append: must have 1 to 16 arguments")
      }
      for (i, arg) in append.enumerated() {
        guard (1...256).contains(arg.utf8.count) else {
          throw HubError.invalid("FixAction.arguments.append[\(i)]: must be 1 to 256 bytes")
        }
        for scalar in arg.unicodeScalars {
          let v = scalar.value
          if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
            throw HubError.invalid("FixAction.arguments.append[\(i)]: may not contain control characters")
          }
        }
        try Check.placeholders(arg, field: "FixAction.arguments.append[\(i)]")
      }

    case .sidecar:
      break

    case .window(let mode, let size, let enabled, let exe):
      if mode == "virtualDesktop" {
        guard let size = size else {
          throw HubError.invalid("FixAction.window: virtualDesktop requires size")
        }
        guard enabled == nil else {
          throw HubError.invalid("FixAction.window: virtualDesktop must not have enabled")
        }
        guard let exe = exe else {
          throw HubError.invalid("FixAction.window: virtualDesktop requires exe")
        }
        try Check.exe(exe, field: "FixAction.window.exe")
        // Validate size format: ^\d{3,4}x\d{3,4}$
        let parts = size.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
          throw HubError.invalid("FixAction.window.size: invalid format")
        }
        guard Check.ascii(String(parts[0]), 3...4, first: { b in
          b >= 0x30 && b <= 0x39
        }, rest: { b in
          b >= 0x30 && b <= 0x39
        }) && Check.ascii(String(parts[1]), 3...4, first: { b in
          b >= 0x30 && b <= 0x39
        }, rest: { b in
          b >= 0x30 && b <= 0x39
        }) else {
          throw HubError.invalid("FixAction.window.size: invalid format")
        }
      } else if mode == "retina" {
        guard enabled != nil else {
          throw HubError.invalid("FixAction.window: retina requires enabled")
        }
        guard size == nil else {
          throw HubError.invalid("FixAction.window: retina must not have size")
        }
        guard exe == nil else {
          throw HubError.invalid("FixAction.window: retina must not have exe")
        }
      } else {
        throw HubError.invalid("FixAction.window.mode: must be virtualDesktop or retina")
      }

    case .prerequisite(let id):
      try Check.id(id, field: "FixAction.prerequisite.id")

    case .companion(let exe, let after, let readiness):
      try Check.exe(exe, field: "FixAction.companion.exe")
      guard after == "ready" else {
        throw HubError.invalid("FixAction.companion.after: must be 'ready'")
      }
      try readiness.validate()

    case .xmlAttribute(let file, let element, let attribute, let value):
      try Check.destination(file, field: "FixAction.xmlAttribute.file")
      guard Check.ascii(element, 1...64, first: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b == 0x5f  // A-Z, a-z, _
      }, rest: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f || b == 0x2e || b == 0x2d  // A-Z, a-z, 0-9, _, ., -
      }) else {
        throw HubError.invalid("FixAction.xmlAttribute.element: must match ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")
      }
      guard Check.ascii(attribute, 1...64, first: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b == 0x5f  // A-Z, a-z, _
      }, rest: { b in
        (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x5f || b == 0x2e || b == 0x2d  // A-Z, a-z, 0-9, _, ., -
      }) else {
        throw HubError.invalid("FixAction.xmlAttribute.attribute: must match ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")
      }
      guard (1...256).contains(value.utf8.count) else {
        throw HubError.invalid("FixAction.xmlAttribute.value: must be 1 to 256 bytes")
      }
      for scalar in value.unicodeScalars {
        let v = scalar.value
        if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
          throw HubError.invalid("FixAction.xmlAttribute.value: may not contain control characters")
        }
      }
    }
  }


  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    guard let kindKey = container.allKeys.first(where: { $0.stringValue == "kind" }) else {
      throw HubError.invalid("FixAction: missing kind field")
    }
    let kind = try container.decode(String.self, forKey: kindKey)

    switch kind {
    case "env":
      let allowed: Set<String> = ["kind", "name", "value", "scope"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.env")
      let name = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "name"))
      let value = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "value"))
      let scope = try container.decode(EnvScope.self, forKey: AnyCodingKey(stringValue: "scope"))
      self = .env(name: name, value: value, scope: scope)

    case "renderer":
      let allowed: Set<String> = ["kind", "exe", "api", "backend"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.renderer")
      let exe = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "exe"))
      let api = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "api"))
      let backend = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "backend"))
      self = .renderer(exe: exe, api: api, backend: backend)

    case "dllOverride":
      let allowed: Set<String> = ["kind", "exe", "dll", "mode"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.dllOverride")
      let exe = try container.decodeIfPresent(String.self, forKey: AnyCodingKey(stringValue: "exe"))
      let dll = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "dll"))
      let mode = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "mode"))
      self = .dllOverride(exe: exe, dll: dll, mode: mode)

    case "registry":
      let allowed: Set<String> = ["kind", "hive", "key", "name", "type", "value"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.registry")
      let hive = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "hive"))
      let key = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "key"))
      let name = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "name"))
      let type = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "type"))
      let value = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "value"))
      self = .registry(hive: hive, key: key, name: name, type: type, value: value)

    case "file":
      let allowed: Set<String> = ["kind", "asset", "destination", "sha256"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.file")
      let asset = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "asset"))
      let destination = try container.decode(
        String.self, forKey: AnyCodingKey(stringValue: "destination"))
      let sha256 = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "sha256"))
      self = .file(asset: asset, destination: destination, sha256: sha256)

    case "ini":
      let allowed: Set<String> = ["kind", "file", "section", "key", "value"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.ini")
      let file = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "file"))
      let section = try container.decode(
        String.self, forKey: AnyCodingKey(stringValue: "section"))
      let key = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "key"))
      let value = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "value"))
      self = .ini(file: file, section: section, key: key, value: value)

    case "drive":
      let allowed: Set<String> = ["kind", "letter", "target", "lifetime"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.drive")
      let letter = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "letter"))
      let target = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "target"))
      let lifetime = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "lifetime"))
      self = .drive(letter: letter, target: target, lifetime: lifetime)

    case "arguments":
      let allowed: Set<String> = ["kind", "exe", "append"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.arguments")
      let exe = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "exe"))
      let append = try container.decode([String].self, forKey: AnyCodingKey(stringValue: "append"))
      self = .arguments(exe: exe, append: append)

    case "sidecar":
      let allowed: Set<String> = ["kind", "enabled"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.sidecar")
      let enabled = try container.decode(Bool.self, forKey: AnyCodingKey(stringValue: "enabled"))
      self = .sidecar(enabled: enabled)

    case "window":
      let allowed: Set<String> = ["kind", "mode", "size", "enabled", "exe"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.window")
      let mode = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "mode"))
      let size = try container.decodeIfPresent(String.self, forKey: AnyCodingKey(stringValue: "size"))
      let enabled = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey(stringValue: "enabled"))
      let exe = try container.decodeIfPresent(String.self, forKey: AnyCodingKey(stringValue: "exe"))
      self = .window(mode: mode, size: size, enabled: enabled, exe: exe)

    case "prerequisite":
      let allowed: Set<String> = ["kind", "id"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.prerequisite")
      let id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
      self = .prerequisite(id: id)

    case "companion":
      let allowed: Set<String> = ["kind", "exe", "after", "readiness"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.companion")
      let exe = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "exe"))
      let after = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "after"))
      let readiness = try container.decode(
        Readiness.self, forKey: AnyCodingKey(stringValue: "readiness"))
      self = .companion(exe: exe, after: after, readiness: readiness)

    case "xmlAttribute":
      let allowed: Set<String> = ["kind", "file", "element", "attribute", "value"]
      try rejectUnknownKeys(decoder, allowed: allowed, type: "FixAction.xmlAttribute")
      let file = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "file"))
      let element = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "element"))
      let attribute = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "attribute"))
      let value = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "value"))
      self = .xmlAttribute(file: file, element: element, attribute: attribute, value: value)

    default:
      throw HubError.invalid("FixAction: unknown kind \(kind)")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: AnyCodingKey.self)
    switch self {
    case .env(let name, let value, let scope):
      try container.encode("env", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(name, forKey: AnyCodingKey(stringValue: "name"))
      try container.encode(value, forKey: AnyCodingKey(stringValue: "value"))
      try container.encode(scope, forKey: AnyCodingKey(stringValue: "scope"))
    case .renderer(let exe, let api, let backend):
      try container.encode("renderer", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(exe, forKey: AnyCodingKey(stringValue: "exe"))
      try container.encode(api, forKey: AnyCodingKey(stringValue: "api"))
      try container.encode(backend, forKey: AnyCodingKey(stringValue: "backend"))
    case .dllOverride(let exe, let dll, let mode):
      try container.encode("dllOverride", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encodeIfPresent(exe, forKey: AnyCodingKey(stringValue: "exe"))
      try container.encode(dll, forKey: AnyCodingKey(stringValue: "dll"))
      try container.encode(mode, forKey: AnyCodingKey(stringValue: "mode"))
    case .registry(let hive, let key, let name, let type, let value):
      try container.encode("registry", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(hive, forKey: AnyCodingKey(stringValue: "hive"))
      try container.encode(key, forKey: AnyCodingKey(stringValue: "key"))
      try container.encode(name, forKey: AnyCodingKey(stringValue: "name"))
      try container.encode(type, forKey: AnyCodingKey(stringValue: "type"))
      try container.encode(value, forKey: AnyCodingKey(stringValue: "value"))
    case .file(let asset, let destination, let sha256):
      try container.encode("file", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(asset, forKey: AnyCodingKey(stringValue: "asset"))
      try container.encode(destination, forKey: AnyCodingKey(stringValue: "destination"))
      try container.encode(sha256, forKey: AnyCodingKey(stringValue: "sha256"))
    case .ini(let file, let section, let key, let value):
      try container.encode("ini", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(file, forKey: AnyCodingKey(stringValue: "file"))
      try container.encode(section, forKey: AnyCodingKey(stringValue: "section"))
      try container.encode(key, forKey: AnyCodingKey(stringValue: "key"))
      try container.encode(value, forKey: AnyCodingKey(stringValue: "value"))
    case .drive(let letter, let target, let lifetime):
      try container.encode("drive", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(letter, forKey: AnyCodingKey(stringValue: "letter"))
      try container.encode(target, forKey: AnyCodingKey(stringValue: "target"))
      try container.encode(lifetime, forKey: AnyCodingKey(stringValue: "lifetime"))
    case .arguments(let exe, let append):
      try container.encode("arguments", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(exe, forKey: AnyCodingKey(stringValue: "exe"))
      try container.encode(append, forKey: AnyCodingKey(stringValue: "append"))
    case .sidecar(let enabled):
      try container.encode("sidecar", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(enabled, forKey: AnyCodingKey(stringValue: "enabled"))
    case .window(let mode, let size, let enabled, let exe):
      try container.encode("window", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(mode, forKey: AnyCodingKey(stringValue: "mode"))
      try container.encodeIfPresent(size, forKey: AnyCodingKey(stringValue: "size"))
      try container.encodeIfPresent(enabled, forKey: AnyCodingKey(stringValue: "enabled"))
      try container.encodeIfPresent(exe, forKey: AnyCodingKey(stringValue: "exe"))
    case .prerequisite(let id):
      try container.encode("prerequisite", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(id, forKey: AnyCodingKey(stringValue: "id"))
    case .companion(let exe, let after, let readiness):
      try container.encode("companion", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(exe, forKey: AnyCodingKey(stringValue: "exe"))
      try container.encode(after, forKey: AnyCodingKey(stringValue: "after"))
      try container.encode(readiness, forKey: AnyCodingKey(stringValue: "readiness"))
    case .xmlAttribute(let file, let element, let attribute, let value):
      try container.encode("xmlAttribute", forKey: AnyCodingKey(stringValue: "kind"))
      try container.encode(file, forKey: AnyCodingKey(stringValue: "file"))
      try container.encode(element, forKey: AnyCodingKey(stringValue: "element"))
      try container.encode(attribute, forKey: AnyCodingKey(stringValue: "attribute"))
      try container.encode(value, forKey: AnyCodingKey(stringValue: "value"))
    }
  }
}

// MARK: - FixStatus, FixParameter, Fix

/// Status of a fix.
package enum FixStatus: String, Codable, Sendable, CaseIterable {
  case verified
  case experimental
  case rejected
}

/// Type of a fix parameter.
package enum FixParameterType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case bool
  case choice
  case int
  case float
}

/// Parses a binds string of the form "actions[INDEX].FIELD" where INDEX is 1-2 digits and FIELD is 1+ ASCII letters.
/// Returns (actionIndex, fieldName) on success.
private func parseBindsString(_ binds: String) throws(HubError) -> (Int, String) {
  let prefix = "actions["
  guard binds.hasPrefix(prefix) else {
    throw HubError.invalid("FixParameter.binds: invalid format")
  }

  let utf8 = binds.utf8
  var index = utf8.startIndex

  // Skip "actions["
  for _ in 0..<prefix.utf8.count {
    guard index < utf8.endIndex else {
      throw HubError.invalid("FixParameter.binds: invalid format")
    }
    index = utf8.index(after: index)
  }

  // Parse 1-2 digits (0x30-0x39)
  var digitCount = 0
  var digitStartIndex = index
  while index < utf8.endIndex && digitCount < 2 {
    let byte = utf8[index]
    if byte >= 0x30 && byte <= 0x39 {
      digitCount += 1
      index = utf8.index(after: index)
    } else {
      break
    }
  }

  guard (1...2).contains(digitCount) else {
    throw HubError.invalid("FixParameter.binds: invalid format")
  }

  let digitBytes = utf8[digitStartIndex..<index]
  let digitStr = String(bytes: digitBytes, encoding: .utf8) ?? ""
  guard let actionIndex = Int(digitStr) else {
    throw HubError.invalid("FixParameter.binds: invalid format")
  }

  // Parse "].
  guard index < utf8.endIndex, utf8[index] == 0x5d else {  // ]
    throw HubError.invalid("FixParameter.binds: invalid format")
  }
  index = utf8.index(after: index)

  guard index < utf8.endIndex, utf8[index] == 0x2e else {  // .
    throw HubError.invalid("FixParameter.binds: invalid format")
  }
  index = utf8.index(after: index)

  // Parse 1+ ASCII letters
  var letterCount = 0
  var letterStartIndex = index
  while index < utf8.endIndex {
    let byte = utf8[index]
    if (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) {  // A-Z or a-z
      letterCount += 1
      index = utf8.index(after: index)
    } else {
      break
    }
  }

  guard letterCount >= 1 else {
    throw HubError.invalid("FixParameter.binds: invalid format")
  }

  // Ensure we've consumed the entire string
  guard index == utf8.endIndex else {
    throw HubError.invalid("FixParameter.binds: invalid format")
  }

  let letterBytes = utf8[letterStartIndex..<index]
  let fieldName = String(bytes: letterBytes, encoding: .utf8) ?? ""

  return (actionIndex, fieldName)
}

/// A parameter that can be bound to a fix action.
package struct FixParameter: Codable, Equatable, Sendable {
  package let id: String
  package let title: String
  package let type: FixParameterType
  package let defaultValue: String
  package let choices: [String]?
  package let range: [Double]?
  package let binds: String

  package init(
    id: String, title: String, type: FixParameterType, defaultValue: String,
    choices: [String]? = nil, range: [Double]? = nil, binds: String
  ) {
    self.id = id
    self.title = title
    self.type = type
    self.defaultValue = defaultValue
    self.choices = choices
    self.range = range
    self.binds = binds
  }

  /// Validates this parameter.
  package func validate(actionCount: Int) throws(HubError) {
    try Check.id(id, field: "FixParameter.id")
    try Check.text(title, field: "FixParameter.title", max: 80)

    let (actionIndex, _) = try parseBindsString(binds)
    guard actionIndex < actionCount else {
      throw HubError.invalid("FixParameter.binds: action index out of range")
    }

    switch type {
    case .bool:
      guard defaultValue == "true" || defaultValue == "false" else {
        throw HubError.invalid("FixParameter.defaultValue: bool must be true or false")
      }
    case .choice:
      guard let choices = choices, (2...16).contains(choices.count) else {
        throw HubError.invalid("FixParameter.choices: must have 2 to 16 choices for choice type")
      }
      for choice in choices {
        guard choice.utf8.count <= 512 else {
          throw HubError.invalid("FixParameter.choices: each choice must be at most 512 bytes")
        }
        for scalar in choice.unicodeScalars {
          let v = scalar.value
          if (v >= 0x0000 && v <= 0x001f) || v == 0x007f {
            throw HubError.invalid("FixParameter.choices: may not contain control characters")
          }
        }
      }
      guard choices.contains(defaultValue) else {
        throw HubError.invalid("FixParameter.defaultValue: must be in choices")
      }
    case .int:
      guard let rangeArray = range, rangeArray.count == 2 else {
        throw HubError.invalid("FixParameter.range: must have exactly 2 elements for int")
      }
      guard rangeArray[0] < rangeArray[1] else {
        throw HubError.invalid("FixParameter.range: lower bound must be less than upper bound")
      }
      guard let val = Int(defaultValue) else {
        throw HubError.invalid("FixParameter.defaultValue: must be a valid integer")
      }
      guard (rangeArray[0]...rangeArray[1]).contains(Double(val)) else {
        throw HubError.invalid("FixParameter.defaultValue: must be within range")
      }
    case .float:
      guard let rangeArray = range, rangeArray.count == 2 else {
        throw HubError.invalid("FixParameter.range: must have exactly 2 elements for float")
      }
      guard rangeArray[0] < rangeArray[1] else {
        throw HubError.invalid("FixParameter.range: lower bound must be less than upper bound")
      }
      if let val = Double(defaultValue) {
        guard (rangeArray[0]...rangeArray[1]).contains(val) else {
          throw HubError.invalid("FixParameter.defaultValue: must be within range")
        }
      } else {
        throw HubError.invalid("FixParameter.defaultValue: must be a valid number")
      }
    default:
      throw HubError.invalid("FixParameter.type: invalid type")
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["id", "title", "type", "default", "choices", "range", "binds"],
      type: "FixParameter")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.title = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "title"))
    self.type = try container.decode(FixParameterType.self, forKey: AnyCodingKey(stringValue: "type"))
    self.defaultValue = try container.decode(
      String.self, forKey: AnyCodingKey(stringValue: "default"))
    self.choices = try container.decodeIfPresent(
      [String].self, forKey: AnyCodingKey(stringValue: "choices"))
    self.range = try container.decodeIfPresent(
      [Double].self, forKey: AnyCodingKey(stringValue: "range"))
    self.binds = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "binds"))
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: AnyCodingKey.self)
    try container.encode(id, forKey: AnyCodingKey(stringValue: "id"))
    try container.encode(title, forKey: AnyCodingKey(stringValue: "title"))
    try container.encode(type, forKey: AnyCodingKey(stringValue: "type"))
    try container.encode(defaultValue, forKey: AnyCodingKey(stringValue: "default"))
    try container.encodeIfPresent(choices, forKey: AnyCodingKey(stringValue: "choices"))
    try container.encodeIfPresent(range, forKey: AnyCodingKey(stringValue: "range"))
    try container.encode(binds, forKey: AnyCodingKey(stringValue: "binds"))
  }
}

/// A fix that addresses a problem or configures behavior.
package struct Fix: Codable, Equatable, Sendable {
  package let id: String
  package let title: String
  package let reason: String
  package let status: FixStatus
  package let evidence: [String]
  package let appliesWhen: Predicate
  package let requires: [Capability]
  package let actions: [FixAction]
  package let parameters: [FixParameter]
  package let optIn: Bool

  package init(
    id: String, title: String, reason: String, status: FixStatus, evidence: [String],
    appliesWhen: Predicate, requires: [Capability], actions: [FixAction],
    parameters: [FixParameter] = [], optIn: Bool = false
  ) {
    self.id = id
    self.title = title
    self.reason = reason
    self.status = status
    self.evidence = evidence
    self.appliesWhen = appliesWhen
    self.requires = requires
    self.actions = actions
    self.parameters = parameters
    self.optIn = optIn
  }

  /// Validates this fix.
  package func validate() throws(HubError) {
    try Check.id(id, field: "Fix.id")
    try Check.text(title, field: "Fix.title", max: 80)
    try Check.text(reason, field: "Fix.reason", max: 400)

    guard (0...8).contains(evidence.count) else {
      throw HubError.invalid("Fix.evidence: must have 0 to 8 entries")
    }
    for (i, ev) in evidence.enumerated() {
      try Check.text(ev, field: "Fix.evidence[\(i)]", max: 300)
    }

    if status == .verified || status == .rejected {
      guard !evidence.isEmpty else {
        throw HubError.invalid("Fix: \(status.rawValue) status requires at least 1 evidence")
      }
    }

    try appliesWhen.validate()

    guard (1...32).contains(actions.count) else {
      throw HubError.invalid("Fix.actions: must have 1 to 32 actions")
    }
    for action in actions {
      try action.validate()
    }

    var parameterIDs = Set<String>()
    for parameter in parameters {
      try parameter.validate(actionCount: actions.count)
      guard !parameterIDs.contains(parameter.id) else {
        throw HubError.invalid("Fix.parameters: duplicate id \(parameter.id)")
      }
      parameterIDs.insert(parameter.id)

      let (actionIndex, field) = try parseBindsString(parameter.binds)
      let action = actions[actionIndex]
      let isBindable = switch action {
      case .env:
        field == "value"
      case .renderer:
        field == "backend"
      case .arguments:
        field == "append"
      case .sidecar:
        field == "enabled"
      case .window:
        field == "size" || field == "enabled"
      case .ini:
        field == "value"
      case .registry:
        field == "value"
      case .xmlAttribute:
        field == "value"
      default:
        false
      }
      guard isBindable else {
        throw HubError.invalid("FixParameter.binds: field '\(field)' is not bindable for this action kind")
      }
    }
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder,
      allowed: [
        "id", "title", "reason", "status", "evidence", "appliesWhen", "requires", "actions",
        "parameters", "optIn"
      ],
      type: "Fix")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id"))
    self.title = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "title"))
    self.reason = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "reason"))
    self.status = try container.decode(
      FixStatus.self, forKey: AnyCodingKey(stringValue: "status"))
    self.evidence = try container.decode(
      [String].self, forKey: AnyCodingKey(stringValue: "evidence"))
    self.appliesWhen = try container.decode(
      Predicate.self, forKey: AnyCodingKey(stringValue: "appliesWhen"))
    self.requires = try container.decode(
      [Capability].self, forKey: AnyCodingKey(stringValue: "requires"))
    self.actions = try container.decode(
      [FixAction].self, forKey: AnyCodingKey(stringValue: "actions"))
    self.parameters = try container.decodeIfPresent(
      [FixParameter].self, forKey: AnyCodingKey(stringValue: "parameters")) ?? []
    self.optIn = try container.decodeIfPresent(
      Bool.self, forKey: AnyCodingKey(stringValue: "optIn")) ?? false
  }
}
