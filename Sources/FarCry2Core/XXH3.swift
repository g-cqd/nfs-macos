/// XXH3 64-bit with seed 0 and the default secret, as the `xxhash-rust` crate computes it.
///
/// mtld3d stamps every shader-cache chunk with this hash; reproducing it lets the starter keep only
/// chunks the renderer itself would accept. Every length class and the multi-block path are pinned by
/// vectors taken from the crate (`XXH3Tests`).
package enum XXH3 {
  private static let prime32: [UInt64] = [0x9E37_79B1, 0x85EB_CA77, 0xC2B2_AE3D]
  private static let prime64: [UInt64] = [
    0x9E37_79B1_85EB_CA87, 0xC2B2_AE3D_27D4_EB4F, 0x1656_67B1_9E37_79F9,
    0x85EB_CA77_C2B2_AE63, 0x27D4_EB2F_1656_67C5,
  ]
  private static let mixPrime1: UInt64 = 0x1656_6791_9E37_79F9
  private static let mixPrime2: UInt64 = 0x9FB2_1C65_1E98_DF25
  private static let stripe = 64
  private static let secretSize = 192
  private static let secret: [UInt8] = [
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
  ]

  /// - Complexity: O(n) time, O(1) extra space.
  package static func hash64(_ input: [UInt8]) -> UInt64 {
    switch input.count {
    case 0: return avalanche64(read64(secret, 56) ^ read64(secret, 64))
    case 1...3: return hash1to3(input)
    case 4...8: return hash4to8(input)
    case 9...16: return hash9to16(input)
    case 17...128: return hash17to128(input)
    case 129...240: return hash129to240(input)
    default: return hashLong(input)
    }
  }

  private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    UInt64(bytes[offset]) | UInt64(bytes[offset + 1]) << 8 | UInt64(bytes[offset + 2]) << 16
      | UInt64(bytes[offset + 3]) << 24
  }

  private static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    read32(bytes, offset) | read32(bytes, offset + 4) << 32
  }

  private static func rotate(_ value: UInt64, _ bits: UInt64) -> UInt64 {
    (value << bits) | (value >> (64 - bits))
  }

  private static func foldedProduct(_ left: UInt64, _ right: UInt64) -> UInt64 {
    let product = left.multipliedFullWidth(by: right)
    return product.low ^ product.high
  }

  private static func avalanche64(_ value: UInt64) -> UInt64 {
    var hash = value
    hash ^= hash >> 33
    hash = hash &* prime64[1]
    hash ^= hash >> 29
    hash = hash &* prime64[2]
    return hash ^ (hash >> 32)
  }

  private static func avalanche(_ value: UInt64) -> UInt64 {
    var hash = value
    hash ^= hash >> 37
    hash = hash &* mixPrime1
    return hash ^ (hash >> 32)
  }

  private static func hash1to3(_ input: [UInt8]) -> UInt64 {
    let count = input.count
    let combined =
      UInt64(input[0]) << 16 | UInt64(input[count >> 1]) << 24 | UInt64(input[count - 1])
      | UInt64(count) << 8
    let flip = (read32(secret, 0) ^ read32(secret, 4))
    return avalanche64(combined ^ flip)
  }

  private static func hash4to8(_ input: [UInt8]) -> UInt64 {
    let count = input.count
    let first = read32(input, 0)
    let last = read32(input, count - 4)
    let flip = read64(secret, 8) ^ read64(secret, 16)
    var hash = (last &+ (first << 32)) ^ flip
    hash ^= rotate(hash, 49) ^ rotate(hash, 24)
    hash = hash &* mixPrime2
    hash ^= (hash >> 35) &+ UInt64(count)
    hash = hash &* mixPrime2
    return hash ^ (hash >> 28)
  }

  private static func hash9to16(_ input: [UInt8]) -> UInt64 {
    let count = input.count
    let low = read64(input, 0) ^ (read64(secret, 24) ^ read64(secret, 32))
    let high = read64(input, count - 8) ^ (read64(secret, 40) ^ read64(secret, 48))
    let accumulator =
      UInt64(count) &+ low.byteSwapped &+ high &+ foldedProduct(low, high)
    return avalanche(accumulator)
  }

  private static func mix16(_ input: [UInt8], _ offset: Int, _ secretOffset: Int) -> UInt64 {
    foldedProduct(
      read64(input, offset) ^ read64(secret, secretOffset),
      read64(input, offset + 8) ^ read64(secret, secretOffset + 8))
  }

  private static func hash17to128(_ input: [UInt8]) -> UInt64 {
    let count = input.count
    var accumulator = UInt64(count) &* prime64[0]
    if count > 32 {
      if count > 64 {
        if count > 96 {
          accumulator = accumulator &+ mix16(input, 48, 96) &+ mix16(input, count - 64, 112)
        }
        accumulator = accumulator &+ mix16(input, 32, 64) &+ mix16(input, count - 48, 80)
      }
      accumulator = accumulator &+ mix16(input, 16, 32) &+ mix16(input, count - 32, 48)
    }
    accumulator = accumulator &+ mix16(input, 0, 0) &+ mix16(input, count - 16, 16)
    return avalanche(accumulator)
  }

  private static func hash129to240(_ input: [UInt8]) -> UInt64 {
    let count = input.count
    var accumulator = UInt64(count) &* prime64[0]
    for round in 0..<8 { accumulator = accumulator &+ mix16(input, 16 * round, 16 * round) }
    accumulator = avalanche(accumulator)
    for round in 8..<(count / 16) {
      accumulator = accumulator &+ mix16(input, 16 * round, 16 * (round - 8) + 3)
    }
    accumulator = accumulator &+ mix16(input, count - 16, 136 - 17)
    return avalanche(accumulator)
  }

  private static func accumulate(
    _ lanes: inout [UInt64], _ input: [UInt8], _ offset: Int, _ secretOffset: Int
  ) {
    for lane in 0..<8 {
      let value = read64(input, offset + 8 * lane)
      let key = value ^ read64(secret, secretOffset + 8 * lane)
      lanes[lane ^ 1] = lanes[lane ^ 1] &+ value
      lanes[lane] = lanes[lane] &+ (key & 0xFFFF_FFFF) &* (key >> 32)
    }
  }

  private static func scramble(_ lanes: inout [UInt64]) {
    for lane in 0..<8 {
      var value = lanes[lane]
      value ^= value >> 47
      value ^= read64(secret, secretSize - stripe + 8 * lane)
      lanes[lane] = value &* prime32[0]
    }
  }

  private static func hashLong(_ input: [UInt8]) -> UInt64 {
    let count = input.count
    var lanes: [UInt64] = [
      prime32[2], prime64[0], prime64[1], prime64[2], prime64[3], prime32[1], prime64[4],
      prime32[0],
    ]
    let stripesPerBlock = (secretSize - stripe) / 8
    let blockLength = stripe * stripesPerBlock
    let blocks = (count - 1) / blockLength
    for block in 0..<blocks {
      for index in 0..<stripesPerBlock {
        accumulate(&lanes, input, block * blockLength + index * stripe, index * 8)
      }
      scramble(&lanes)
    }
    let stripes = ((count - 1) - blockLength * blocks) / stripe
    for index in 0..<stripes {
      accumulate(&lanes, input, blocks * blockLength + index * stripe, index * 8)
    }
    accumulate(&lanes, input, count - stripe, secretSize - stripe - 7)
    var result = UInt64(count) &* prime64[0]
    for pair in 0..<4 {
      result =
        result
        &+ foldedProduct(
          lanes[2 * pair] ^ read64(secret, 11 + 16 * pair),
          lanes[2 * pair + 1] ^ read64(secret, 11 + 16 * pair + 8))
    }
    return avalanche(result)
  }
}
