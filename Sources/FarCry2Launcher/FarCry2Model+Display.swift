import LauncherCore

extension FarCry2Model {
  var resolutions: [ResolutionPreset] {
    var result = ResolutionPreset.all
    let parts = settings.value("resolution").split(separator: "x")
    if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
      let current = ResolutionPreset(width: width, height: height),
      !result.contains(where: { $0.id == current.id })
    {
      result.append(current)
    }
    return result.sorted { $0.width * $0.height < $1.width * $1.height }
  }
  var selectedResolution: String {
    get { settings.value("resolution") }
    set {
      if resolutions.contains(where: { $0.id == newValue }) {
        settings.values["resolution"] = newValue
      }
    }
  }
  var aspectRatio: AspectRatio {
    get { resolutions.first { $0.id == selectedResolution }?.ratio ?? .wide16to10 }
    set {
      let currentHeight = resolutions.first { $0.id == selectedResolution }?.height ?? 1600
      guard
        let nearest = resolutions.filter({ $0.ratio == newValue }).min(by: {
          abs($0.height - currentHeight) < abs($1.height - currentHeight)
        })
      else { return }
      selectedResolution = nearest.id
    }
  }
  var aspectRatios: [AspectRatio] {
    AspectRatio.allCases.filter { ratio in resolutions.contains { $0.ratio == ratio } }
  }
  var filteredResolutions: [ResolutionPreset] { resolutions.filter { $0.ratio == aspectRatio } }
}
