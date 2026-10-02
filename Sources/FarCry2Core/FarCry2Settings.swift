import Foundation
import LauncherCore

/// Validated, portable settings. Anything the starter does not manage stays exactly as the game wrote it.
package struct FarCry2Settings: Codable, Equatable, Sendable {
  package var values: [String: String]

  package init() { values = [:] }

  /// The Wine registry section the Mac driver reads, as written in `user.reg`.
  package static let macDriverSection = "Software\\\\Wine\\\\Mac Driver"

  /// Reads the managed options that are present and valid in each place the game keeps them.
  /// Unknown or out-of-range values are left alone rather than imported.
  package init(
    profile: GamerProfileDocument?, renderer: String?, registry: String? = nil,
    launcher: Data? = nil
  ) throws(LauncherError) {
    self.init()
    if let profile {
      for setting in FarCry2Catalog.settings {
        guard case .profile(let targets) = setting.storage else { continue }
        if setting.id == "resolution" {
          let x = profile.values(targets[0])
          let y = profile.values(targets[1])
          if let width = x.first, let height = y.first, setting.accepts("\(width)x\(height)") {
            values[setting.id] = "\(width)x\(height)"
          }
        } else if let value = profile.values(targets[0]).first, setting.accepts(value) {
          values[setting.id] = value
        }
      }
    }
    if let renderer {
      let config = try ConfigText(renderer)
      for setting in FarCry2Catalog.settings where setting.isRenderer {
        if let value = config.value(section: "", key: setting.id), setting.accepts(value) {
          values[setting.id] = value
        }
      }
    }
    if let registry {
      let config = try ConfigText(registry)
      for setting in FarCry2Catalog.settings {
        guard let name = setting.registryName,
          let raw = config.value(section: Self.macDriverSection, key: "\"\(name)\"")
        else { continue }
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        values[setting.id] = ["y", "t", "1"].contains(text.lowercased().prefix(1)) ? "1" : "0"
      }
    }
    if let launcher {
      guard let saved = try? JSONDecoder().decode([String: String].self, from: launcher) else {
        throw .operation("The saved launcher options are unreadable.")
      }
      for setting in FarCry2Catalog.settings where setting.isLauncher {
        if let value = saved[setting.id], setting.accepts(value) { values[setting.id] = value }
      }
    }
    try validate()
  }

  package func value(_ id: String) -> String {
    values[id] ?? FarCry2Catalog.setting(id)?.defaultValue ?? ""
  }

  /// Rejects unknown options and values outside the starter's limits.
  package func validate() throws(LauncherError) {
    guard values.count <= FarCry2Catalog.settings.count else {
      throw .operation("The setup contains too many settings.")
    }
    for (id, value) in values {
      guard let setting = FarCry2Catalog.setting(id), setting.accepts(value) else {
        throw .operation("The setup contains an unsupported setting value.")
      }
    }
  }

  /// What applying a setup to a profile did.
  package struct Report: Equatable, Sendable {
    /// Option ids whose attributes were rewritten.
    package let applied: [String]
    /// Option ids with no matching attribute in this profile; they were not created.
    package let absent: [String]
    /// Whether the renderer attribute was forced to Direct3D 9 or already was.
    package let platformSet: Bool
    /// Whether a Direct3D 10 quality id was normalised for the Direct3D 9 renderer.
    package let qualityNormalised: Bool
  }

  /// Rewrites the explicitly chosen options and forces Direct3D 9, leaving every other byte intact.
  package func applying(to profile: inout GamerProfileDocument) throws(LauncherError) -> Report {
    try validate()
    guard profile.hasElement(["RenderProfile"]) else {
      throw .operation("GamerProfile.xml has no RenderProfile; it was not changed.")
    }
    var applied: [String] = []
    var absent: [String] = []
    for setting in FarCry2Catalog.settings {
      guard case .profile(let targets) = setting.storage, let chosen = values[setting.id] else {
        continue
      }
      var changed = 0
      if setting.id == "resolution" {
        let parts = chosen.split(separator: "x").map(String.init)
        for (index, target) in targets.enumerated() {
          changed += try profile.set(parts[index % 2], for: target)
        }
      } else {
        for target in targets { changed += try profile.set(chosen, for: target) }
      }
      if changed > 0 { applied.append(setting.id) } else { absent.append(setting.id) }
    }
    let platformSet =
      try profile.set(FarCry2Catalog.requiredPlatform, for: FarCry2Catalog.platform) > 0
    var normalised = false
    if let quality = profile.values(FarCry2Catalog.quality).first,
      quality.hasSuffix(FarCry2Catalog.direct3D10Suffix),
      quality.count > FarCry2Catalog.direct3D10Suffix.count
    {
      let base = String(quality.dropLast(FarCry2Catalog.direct3D10Suffix.count))
      normalised = try profile.set(base, for: FarCry2Catalog.quality) > 0
    }
    return Report(
      applied: applied, absent: absent, platformSet: platformSet, qualityNormalised: normalised)
  }

  /// Updates only the renderer-owned keys, retaining every other line of `mtld3d.conf`.
  package func rendererConfig(original: String) throws(LauncherError) -> String {
    try validate()
    var config = try ConfigText(original)
    for setting in FarCry2Catalog.settings where setting.isRenderer {
      config.set(section: "", key: setting.id, value: value(setting.id))
    }
    return config.text
  }

  /// Updates only the Mac driver values the starter owns in the prefix's `user.reg`.
  /// - Returns: nil when the file is not a Wine registry, which is then left alone.
  package func registryConfig(original: String) throws(LauncherError) -> String? {
    try validate()
    guard original.hasPrefix("WINE REGISTRY Version 2") else { return nil }
    var config = try ConfigText(original)
    for setting in FarCry2Catalog.settings {
      guard let name = setting.registryName else { continue }
      config.set(
        section: Self.macDriverSection, key: "\"\(name)\"",
        value: value(setting.id) == "1" ? "\"Y\"" : "\"N\"", compact: true)
    }
    return config.text
  }

  /// The launcher-owned options, as persisted next to the player data.
  package func launcherData() throws(LauncherError) -> Data {
    try validate()
    var saved: [String: String] = [:]
    for setting in FarCry2Catalog.settings where setting.isLauncher {
      saved[setting.id] = value(setting.id)
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(saved)
    } catch { throw .operation("Could not encode the launcher options.") }
  }

  /// Environment, switches and console lines the chosen launcher options turn into.
  package struct LaunchPlan: Equatable, Sendable {
    package var environment: [String: String] = [:]
    package var arguments: [String] = []
    package var console: [String] = []
    package init() {}
  }

  package func launchPlan() -> LaunchPlan {
    var plan = LaunchPlan()
    for setting in FarCry2Catalog.settings where setting.isLauncher {
      let chosen = value(setting.id)
      switch setting.launch {
      case .none: break
      case .environment(let name): plan.environment[name] = chosen
      case .argument(let switchName): if chosen == "1" { plan.arguments.append(switchName) }
      case .console(let template):
        if !setting.isDefault(chosen) {
          plan.console.append(template.replacingOccurrences(of: "{value}", with: chosen))
        }
      }
    }
    return plan
  }

  /// The highest-quality preset the evidence supports: native resolution, 4× MSAA with alpha to
  /// coverage off (the two together draw foliage as opaque cards), the game's top texture level and top overall preset, Retina output, full-resolution
  /// rendering and synchronous pipelines.
  package mutating func maximumQuality(width: Int, height: Int) {
    values["resolution"] = "\(width)x\(height)"
    values["fullscreen"] = "1"
    values["vsync"] = "0"
    values["antialiasing"] = "4"
    values["alphaToCoverage"] = "0"
    values["skipTopMip"] = "0"
    values["quality"] = "ultrahigh"
    values["retina"] = "1"
    values["render.scale"] = "1"
    values["shader.asyncCompile"] = "false"
  }
}
