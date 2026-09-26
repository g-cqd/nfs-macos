package struct ResolutionPreset: Identifiable, Sendable {
  package let ratio: AspectRatio
  package let width: Int
  package let height: Int
  package var id: String { "\(width)x\(height)" }
  package var title: String { "\(width) × \(height)" }

  private init(_ ratio: AspectRatio, _ width: Int, _ height: Int) {
    self.ratio = ratio
    self.width = width
    self.height = height
  }

  /// Accepts a complete display mode within the renderer's configured resolution limits.
  package init?(width: Int, height: Int) {
    guard (640...7680).contains(width), (480...4320).contains(height) else { return nil }
    let ratio: AspectRatio
    if let known = Self.all.first(where: { $0.width == width && $0.height == height }) {
      ratio = known.ratio
    } else if width * 10 == height * 16 {
      ratio = .wide16to10
    } else if width * 9 == height * 16 {
      ratio = .wide16to9
    } else if width * 3 == height * 4 {
      ratio = .classic
    } else if width * 9 == height * 32 {
      ratio = .superwide
    } else {
      ratio = .display
    }
    self.init(ratio, width, height)
  }

  package static func nearest(ratio: AspectRatio, height: Int) -> Self? {
    guard (480...4320).contains(height) else { return nil }
    return all.filter { $0.ratio == ratio }.min {
      abs($0.height - height) < abs($1.height - height)
    }
  }

  package static let all: [Self] = [
    .init(.wide16to10, 1280, 800), .init(.wide16to10, 1440, 900), .init(.wide16to10, 1680, 1050),
    .init(.wide16to10, 1920, 1200), .init(.wide16to10, 2560, 1600), .init(.wide16to10, 3072, 1920),
    .init(.wide16to10, 3360, 2100), .init(.wide16to10, 3840, 2400),
    .init(.wide16to9, 1280, 720), .init(.wide16to9, 1600, 900), .init(.wide16to9, 1920, 1080),
    .init(.wide16to9, 2560, 1440), .init(.wide16to9, 3200, 1800), .init(.wide16to9, 3840, 2160),
    .init(.classic, 800, 600), .init(.classic, 1024, 768), .init(.classic, 1280, 960),
    .init(.classic, 1600, 1200), .init(.classic, 1920, 1440), .init(.classic, 2048, 1536),
    .init(.ultrawide, 2560, 1080), .init(.ultrawide, 3440, 1440), .init(.ultrawide, 5120, 2160),
    .init(.superwide, 3840, 1080), .init(.superwide, 5120, 1440), .init(.superwide, 7680, 2160),
  ]
}
