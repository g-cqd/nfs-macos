import Foundation

/// The few facts about a Windows executable that identify a game build.
///
/// Every offset comes from an untrusted file, so each read is bounds-checked and a malformed image
/// yields an error instead of a trap. Only PE32/PE32+ headers and the `RT_VERSION` resource are read.
package struct PortableExecutable: Equatable, Sendable {
  package static let machineI386: UInt16 = 0x14c
  package static let machineAMD64: UInt16 = 0x8664
  static let sizeLimit = 128 * 1024 * 1024
  static let versionResource: UInt32 = 16

  package let machine: UInt16
  package let isDynamicLibrary: Bool
  /// `major.minor.build.revision` from `VS_FIXEDFILEINFO`, when the image carries a version resource.
  package let fileVersion: String?
  /// `CompanyName`, `ProductName`, `OriginalFilename` and similar string-table entries.
  package let strings: [String: String]

  /// Reads at most 128 MiB.
  package static func read(_ url: URL) throws(LauncherError) -> PortableExecutable {
    try parse(Array(try BoundedFile.read(url, limit: sizeLimit)), name: url.lastPathComponent)
  }

  package static func parse(_ bytes: [UInt8], name: String = "executable") throws(LauncherError)
    -> PortableExecutable
  {
    let invalid = LauncherError.operation("\(name) is not a valid Windows executable.")
    guard bytes.count >= 64, bytes[0] == 0x4D, bytes[1] == 0x5A,
      let headerOffset = bytes.le32(0x3C).map(Int.init), headerOffset >= 64,
      headerOffset <= 1_048_576, headerOffset + 24 <= bytes.count,
      bytes[headerOffset] == 0x50, bytes[headerOffset + 1] == 0x45,
      bytes[headerOffset + 2] == 0, bytes[headerOffset + 3] == 0,
      let machine = bytes.le16(headerOffset + 4),
      let sectionCount = bytes.le16(headerOffset + 6).map(Int.init), sectionCount <= 96,
      let optionalSize = bytes.le16(headerOffset + 20).map(Int.init),
      let characteristics = bytes.le16(headerOffset + 22)
    else { throw invalid }
    let optional = headerOffset + 24
    guard optional + optionalSize <= bytes.count, let magic = bytes.le16(optional) else {
      throw invalid
    }
    let directoryTable: Int
    switch magic {
    case 0x10B: directoryTable = optional + 96
    case 0x20B: directoryTable = optional + 112
    default: throw invalid
    }
    let sectionTable = optional + optionalSize
    guard sectionTable + sectionCount * 40 <= bytes.count else { throw invalid }
    var sections: [Section] = []
    for index in 0..<sectionCount {
      let base = sectionTable + index * 40
      guard let virtualSize = bytes.le32(base + 8), let address = bytes.le32(base + 12),
        let rawSize = bytes.le32(base + 16), let rawOffset = bytes.le32(base + 20)
      else { throw invalid }
      sections.append(
        Section(
          address: Int(address), size: Int(max(virtualSize, rawSize)), rawOffset: Int(rawOffset),
          rawSize: Int(rawSize)))
    }
    var version: String?
    var strings: [String: String] = [:]
    // Resource directory is data directory 2; the table may be absent in stripped images.
    let directoryCount = bytes.le32(directoryTable - 4).map(Int.init) ?? 0
    if directoryCount > 2, let rva = bytes.le32(directoryTable + 16), rva != 0,
      let blob = versionBlob(bytes, resourceRVA: Int(rva), sections: sections)
    {
      version = fixedFileVersion(blob)
      strings = stringTable(blob)
    }
    return PortableExecutable(
      machine: machine, isDynamicLibrary: characteristics & 0x2000 != 0, fileVersion: version,
      strings: strings)
  }

  private struct Section {
    let address: Int
    let size: Int
    let rawOffset: Int
    let rawSize: Int
  }

  private static func offset(of rva: Int, in sections: [Section], count: Int) -> Int? {
    for section in sections where rva >= section.address && rva - section.address < section.size {
      let delta = rva - section.address
      guard delta < section.rawSize else { return nil }
      let result = section.rawOffset + delta
      return result < count ? result : nil
    }
    return nil
  }

  /// Walks type → name → language for `RT_VERSION` and returns its first data blob.
  private static func versionBlob(_ bytes: [UInt8], resourceRVA: Int, sections: [Section])
    -> [UInt8]?
  {
    guard let base = offset(of: resourceRVA, in: sections, count: bytes.count) else { return nil }
    func entries(_ directory: Int) -> [(id: UInt32, target: UInt32)]? {
      guard directory >= base, directory + 16 <= bytes.count,
        let named = bytes.le16(directory + 12).map(Int.init),
        let ids = bytes.le16(directory + 14).map(Int.init), named + ids <= 64
      else { return nil }
      var result: [(UInt32, UInt32)] = []
      for index in 0..<(named + ids) {
        let entry = directory + 16 + index * 8
        guard let id = bytes.le32(entry), let target = bytes.le32(entry + 4) else { return nil }
        result.append((id, target))
      }
      return result
    }
    guard let types = entries(base),
      let typeEntry = types.first(where: {
        $0.id == versionResource && $0.target & 0x8000_0000 != 0
      }),
      let names = entries(base + Int(typeEntry.target & 0x7FFF_FFFF)),
      let nameEntry = names.first, nameEntry.target & 0x8000_0000 != 0,
      let languages = entries(base + Int(nameEntry.target & 0x7FFF_FFFF)),
      let languageEntry = languages.first, languageEntry.target & 0x8000_0000 == 0
    else { return nil }
    let leaf = base + Int(languageEntry.target)
    guard let dataRVA = bytes.le32(leaf).map(Int.init),
      let size = bytes.le32(leaf + 4).map(Int.init),
      size >= 64, size <= 65_536,
      let start = offset(of: dataRVA, in: sections, count: bytes.count),
      start + size <= bytes.count
    else { return nil }
    return Array(bytes[start..<(start + size)])
  }

  private static func fixedFileVersion(_ blob: [UInt8]) -> String? {
    // VS_FIXEDFILEINFO follows the 32-byte key; locate its signature near the header.
    for offset in stride(from: 0, through: min(blob.count - 20, 128), by: 4)
    where blob.le32(offset) == 0xFEEF_04BD {
      guard let high = blob.le32(offset + 8), let low = blob.le32(offset + 12) else { return nil }
      return "\(high >> 16).\(high & 0xFFFF).\(low >> 16).\(low & 0xFFFF)"
    }
    return nil
  }

  /// Cuts at a scalar boundary so one letter with thousands of combining marks cannot exceed the bound.
  private static func bounded(_ text: String, bytes limit: Int) -> String {
    var result = String.UnicodeScalarView()
    var used = 0
    for scalar in text.unicodeScalars {
      let width = String(scalar).utf8.count
      guard used + width <= limit else { break }
      result.append(scalar)
      used += width
    }
    return String(result)
  }

  /// A string-table entry stores its key and then its value as NUL-separated UTF-16 runs.
  private static func stringTable(_ blob: [UInt8]) -> [String: String] {
    var units: [UInt16] = []
    units.reserveCapacity(blob.count / 2)
    var index = 0
    while index + 1 < blob.count {
      units.append(UInt16(blob[index]) | UInt16(blob[index + 1]) << 8)
      index += 2
    }
    let runs = units.split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
    var result: [String: String] = [:]
    for key in [
      "CompanyName", "FileDescription", "FileVersion", "InternalName", "OriginalFilename",
      "ProductName", "ProductVersion",
    ] {
      guard let position = runs.firstIndex(where: { $0.hasSuffix(key) }), position + 1 < runs.count
      else { continue }
      result[key] = bounded(runs[position + 1], bytes: 128)
    }
    return result
  }
}

extension Array where Element == UInt8 {
  fileprivate func le16(_ offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= count else { return nil }
    return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func le32(_ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= count else { return nil }
    return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16
      | UInt32(self[offset + 3]) << 24
  }
}
