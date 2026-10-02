import Foundation
import LauncherCore

/// Validated, portable settings. Anything the starter does not manage stays exactly as the game wrote it.
package struct FarCry2Settings: Codable, Equatable, Sendable {
  package var values: [String: String]

  package init() { values = [:] }

  /// Reads the managed options that are present and valid in the game's profile and renderer file.
  /// Unknown or out-of-range values are left alone rather than imported.
  package init(profile: GamerProfileDocument?, renderer: String?) throws(LauncherError) {
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
        changed = try profile.set(chosen, for: targets[0])
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

  /// The highest-quality preset that public evidence supports: native resolution, 4× MSAA with alpha
  /// to coverage, the game's top texture level, full-resolution rendering and synchronous pipelines.
  /// Detail levels are not touched; select Ultra High in the game's Video options.
  package mutating func maximumQuality(width: Int, height: Int) {
    values["resolution"] = "\(width)x\(height)"
    values["fullscreen"] = "1"
    values["vsync"] = "0"
    values["antialiasing"] = "4"
    values["alphaToCoverage"] = "1"
    values["skipTopMip"] = "0"
    values["render.scale"] = "1"
    values["shader.asyncCompile"] = "false"
  }
}
