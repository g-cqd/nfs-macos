import Foundation
import LauncherCore
import Testing

@testable import FarCry2Core

struct ShaderCacheFormatTests {
  private let current = ShaderCacheFormat.Header(format: 20, schema: 79)

  @Test
  func `a cache the real writers produced is read chunk by chunk`() throws {
    let layout = try #require(ShaderCacheFormat.scan(ShaderCacheGolden.singles))
    #expect(layout.header == current)
    #expect(layout.chunks == 3 && layout.bundles == 0)
    #expect(layout.validLength == ShaderCacheGolden.singles.count)
    #expect(!layout.discardedTail && layout.strayHeaders == 0 && layout.unknownKinds == 0)
    let bundle = try #require(ShaderCacheFormat.scan(ShaderCacheGolden.bundle))
    #expect(bundle.chunks == 1 && bundle.bundles == 1)
    let mixed = try #require(ShaderCacheFormat.scan(ShaderCacheGolden.mixed))
    #expect(mixed.chunks == 3 && mixed.bundles == 1)
  }

  @Test
  func `a header with no chunks has no records`() throws {
    let layout = try #require(ShaderCacheFormat.scan(ShaderCacheGolden.empty))
    #expect(layout.chunks == 0 && !layout.hasRecords)
    #expect(layout.validLength == ShaderCacheFormat.headerLength)
  }

  @Test
  func `the header round trips through its bytes`() {
    #expect(current.bytes == ShaderCacheGolden.empty)
    #expect(ShaderCacheFormat.header(of: ShaderCacheGolden.staleSchema)?.schema == 78)
  }

  @Test(arguments: [0, 1, 7, 8, 15])
  func `data without a complete header is not a cache`(length: Int) {
    #expect(ShaderCacheFormat.scan(ShaderCacheGolden.singles.prefix(length)) == nil)
    #expect(ShaderCacheFormat.header(of: ShaderCacheGolden.singles.prefix(length)) == nil)
  }

  @Test
  func `another file is not a cache`() {
    var data = ShaderCacheGolden.singles
    data[0] = 0x4e
    #expect(ShaderCacheFormat.scan(data) == nil)
    #expect(ShaderCacheFormat.scan(Data(repeating: 0, count: 64)) == nil)
  }

  @Test
  func `a torn write keeps the intact chunks and drops the tail`() throws {
    let layout = try #require(ShaderCacheFormat.scan(ShaderCacheGolden.torn))
    #expect(layout.chunks == 2 && layout.discardedTail)
    #expect(layout.validLength == ShaderCacheGolden.staleSchema.count)
    let kept = ShaderCacheFormat.trimmed(ShaderCacheGolden.torn, layout: layout)
    #expect(kept.count == layout.validLength)
    #expect(try #require(ShaderCacheFormat.scan(kept)).discardedTail == false)
  }

  @Test(arguments: [1, 5, 20, 23, 24, 30])
  func `every cut inside the last chunk is detected`(removed: Int) throws {
    let data = ShaderCacheGolden.singles.dropLast(removed)
    let layout = try #require(ShaderCacheFormat.scan(Data(data)))
    #expect(layout.chunks == 2 && layout.discardedTail)
  }

  @Test
  func `a damaged chunk ends the cache at the previous chunk`() throws {
    // The second chunk starts after the 16-byte header and one 71-byte chunk (24-byte header, 47-byte frame).
    for position in [16 + 71, 16 + 71 + 5, 16 + 71 + 13, 16 + 71 + 17, 16 + 71 + 30] {
      var data = ShaderCacheGolden.singles
      data[position] ^= 0x01
      let layout = try #require(ShaderCacheFormat.scan(data))
      #expect(layout.chunks == 1, "flip at \(position)")
      #expect(layout.validLength == 16 + 71)
    }
  }

  @Test
  func `a file header inside the file is skipped as the renderer skips it`() throws {
    let layout = try #require(ShaderCacheFormat.scan(ShaderCacheGolden.concatWhole))
    #expect(layout.strayHeaders == 1 && layout.chunks == 4 && layout.bundles == 1)
    #expect(layout.validLength == ShaderCacheGolden.concatWhole.count)
  }

  @Test
  func `joining two caches matches the file the real parser accepted`() throws {
    let joined = try ShaderCacheFormat.joined(
      ShaderCacheGolden.singles, ShaderCacheGolden.bundle, limit: 1_000_000)
    #expect(joined == ShaderCacheGolden.concatChunks)
    let layout = try #require(ShaderCacheFormat.scan(joined))
    #expect(layout.chunks == 4 && layout.strayHeaders == 0)
  }

  @Test
  func `joining drops a torn tail instead of hiding the second cache behind it`() throws {
    let joined = try ShaderCacheFormat.joined(
      ShaderCacheGolden.torn, ShaderCacheGolden.bundle, limit: 1_000_000)
    let layout = try #require(ShaderCacheFormat.scan(joined))
    #expect(layout.chunks == 3 && !layout.discardedTail)
  }

  @Test
  func `joining refuses different renderer versions and anything that is not a cache`() {
    #expect(throws: LauncherError.self) {
      try ShaderCacheFormat.joined(
        ShaderCacheGolden.singles, ShaderCacheGolden.staleSchema, limit: 1_000_000)
    }
    #expect(throws: LauncherError.self) {
      try ShaderCacheFormat.joined(Data("nope".utf8), ShaderCacheGolden.bundle, limit: 1_000_000)
    }
    #expect(throws: LauncherError.self) {
      try ShaderCacheFormat.joined(ShaderCacheGolden.singles, Data(), limit: 1_000_000)
    }
  }

  @Test
  func `joining honours the size limit exactly`() throws {
    let size = ShaderCacheGolden.concatChunks.count
    _ = try ShaderCacheFormat.joined(
      ShaderCacheGolden.singles, ShaderCacheGolden.bundle, limit: size)
    #expect(throws: LauncherError.self) {
      try ShaderCacheFormat.joined(
        ShaderCacheGolden.singles, ShaderCacheGolden.bundle, limit: size - 1)
    }
  }

  @Test
  func `a chunk of a kind this version does not know is kept and counted`() throws {
    var data = ShaderCacheGolden.singles
    // Rewrite the kind of chunk 1, then recompute its checksum so only the kind differs.
    data[16] = 0x42
    var hashed = Array(data[16..<32])
    hashed.append(contentsOf: data[40..<(40 + 0x2f)])
    let checksum = XXH3.hash64(hashed)
    for index in 0..<8 {
      data[32 + index] = UInt8(truncatingIfNeeded: checksum >> (8 * UInt64(index)))
    }
    let layout = try #require(ShaderCacheFormat.scan(data))
    #expect(layout.chunks == 3 && layout.unknownKinds == 1)
  }

  @Test
  func `a chunk that claims more bytes than exist cannot overflow the walk`() throws {
    var data = ShaderCacheGolden.singles
    for index in 12..<16 { data[16 + index] = 0xff }
    let layout = try #require(ShaderCacheFormat.scan(data))
    #expect(layout.chunks == 0 && layout.discardedTail)
  }

  @Test
  func `a slice with a nonzero start index is read correctly`() throws {
    let padded = Data(repeating: 9, count: 5) + ShaderCacheGolden.singles
    let slice = padded.dropFirst(5)
    #expect(slice.startIndex == 5)
    let layout = try #require(ShaderCacheFormat.scan(slice))
    #expect(layout.chunks == 3)
    let joined = try ShaderCacheFormat.joined(
      slice, ShaderCacheGolden.bundle.dropFirst(0), limit: 1 << 20)
    #expect(joined == ShaderCacheGolden.concatChunks)
  }
}
