import Foundation
import LauncherCore
import Testing

@testable import FarCry2Core

struct ShaderCacheExportTests {
  private let key = ShaderCacheKeys.make()
  private let origin = ShaderCacheOrigin(gpu: "Apple M1", system: "macOS 27")
  private let created = Date(timeIntervalSince1970: 1_790_000_000)

  private func container(payload: Data = ShaderCacheGolden.singles) throws -> Data {
    try ShaderCacheExport.encode(payload: payload, key: key, created: created, origin: origin)
      .container
  }

  @Test
  func `an export decodes to the payload and the key it was made for`() throws {
    let (data, written) = try ShaderCacheExport.encode(
      payload: ShaderCacheGolden.singles, key: key, created: created, origin: origin)
    let (manifest, payload) = try ShaderCacheExport.decode(data, limit: 1_000_000)
    #expect(payload == ShaderCacheGolden.singles)
    #expect(manifest == written)
    #expect(manifest.key == key && manifest.origin == origin)
    #expect(manifest.created == created)
    #expect(manifest.payloadBytes == ShaderCacheGolden.singles.count)
    #expect(manifest.payloadSHA256 == ShaderCacheExport.digest(ShaderCacheGolden.singles))
  }

  @Test
  func `an origin is optional`() throws {
    let data = try ShaderCacheExport.encode(
      payload: ShaderCacheGolden.bundle, key: key, created: created,
      origin: .init(gpu: nil, system: nil)
    ).container
    #expect(try ShaderCacheExport.decode(data, limit: 1_000_000).manifest.origin.gpu == nil)
  }

  @Test
  func `every truncation of an export is refused`() throws {
    let data = try container()
    for length in stride(from: 0, to: data.count, by: 7) {
      #expect(throws: LauncherError.self, "length \(length)") {
        try ShaderCacheExport.decode(data.prefix(length), limit: 1_000_000)
      }
    }
  }

  @Test
  func `a changed payload byte fails the checksum`() throws {
    var data = try container()
    data[data.count - 5] ^= 0xff
    #expect(throws: LauncherError.self) { try ShaderCacheExport.decode(data, limit: 1_000_000) }
  }

  @Test
  func `extra bytes after the payload are refused`() throws {
    var data = try container()
    data.append(0)
    #expect(throws: LauncherError.self) { try ShaderCacheExport.decode(data, limit: 1_000_000) }
  }

  @Test
  func `another file type is refused`() {
    #expect(throws: LauncherError.self) {
      try ShaderCacheExport.decode(ShaderCacheGolden.singles, limit: 1_000_000)
    }
    #expect(throws: LauncherError.self) {
      try ShaderCacheExport.decode(Data("FC2SHCEX".utf8), limit: 1_000_000)
    }
  }

  @Test
  func `a manifest length that lies is refused`() throws {
    for length: UInt32 in [0, 16_385, UInt32.max, 100_000] {
      var data = try container()
      for index in 0..<4 {
        data[8 + index] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(index)))
      }
      #expect(throws: LauncherError.self, "length \(length)") {
        try ShaderCacheExport.decode(data, limit: 1_000_000)
      }
    }
  }

  @Test
  func `a payload over the limit is refused`() throws {
    let data = try container()
    #expect(throws: LauncherError.self) {
      try ShaderCacheExport.decode(data, limit: ShaderCacheGolden.singles.count - 1)
    }
    _ = try ShaderCacheExport.decode(data, limit: ShaderCacheGolden.singles.count)
  }

  @Test
  func `descriptions with control characters or excess length are refused`() throws {
    for bad in ["line\nbreak", String(repeating: "x", count: 257), "tab\there"] {
      let data = try ShaderCacheExport.encode(
        payload: ShaderCacheGolden.singles, key: key, created: created,
        origin: .init(gpu: bad, system: nil)
      ).container
      #expect(throws: LauncherError.self, "\(bad.count)") {
        try ShaderCacheExport.decode(data, limit: 1_000_000)
      }
    }
  }

  @Test
  func `a newer export format asks for a newer starter`() throws {
    let manifest = ShaderCacheExport.Manifest(
      formatVersion: 2, created: created, key: key, payloadBytes: ShaderCacheGolden.singles.count,
      payloadSHA256: ShaderCacheExport.digest(ShaderCacheGolden.singles), origin: origin)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try encoder.encode(manifest)
    var data = Data("FC2SHCEX".utf8)
    data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: json.count >> (8 * $0)) })
    data.append(json)
    data.append(ShaderCacheGolden.singles)
    #expect(throws: LauncherError.self) { try ShaderCacheExport.decode(data, limit: 1_000_000) }
    // The same bytes with the supported version are accepted, so the version alone was refused.
    let supported = ShaderCacheExport.Manifest(
      formatVersion: 1, created: created, key: key, payloadBytes: manifest.payloadBytes,
      payloadSHA256: manifest.payloadSHA256, origin: origin)
    let body = try encoder.encode(supported)
    var accepted = Data("FC2SHCEX".utf8)
    accepted.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: body.count >> (8 * $0)) })
    accepted.append(body)
    accepted.append(ShaderCacheGolden.singles)
    _ = try ShaderCacheExport.decode(accepted, limit: 1_000_000)
  }

  @Test
  func `a newer export is reported as newer even if its key no longer validates here`() throws {
    let manifest = ShaderCacheExport.Manifest(
      formatVersion: 2, created: created, key: key, payloadBytes: 3, payloadSHA256: "x",
      origin: origin)
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    var future = try #require(object["key"] as? [String: Any])
    future["schemaVersion"] = 2
    object["key"] = future
    object["created"] = "2026-10-02T00:00:00Z"
    let json = try JSONSerialization.data(withJSONObject: object)
    var data = Data("FC2SHCEX".utf8)
    data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: json.count >> (8 * $0)) })
    data.append(json)
    data.append(Data("abc".utf8))
    do {
      _ = try ShaderCacheExport.decode(data, limit: 1_000)
      Issue.record("A newer export was accepted")
    } catch {
      #expect(error.localizedDescription.contains("newer version"))
    }
  }
}
