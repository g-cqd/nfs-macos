import CryptoKit
import Foundation
import Testing

@testable import LauncherCore

struct CareerSaveTests {
  static func fixture() throws -> Data {
    let url = try #require(
      Bundle.module.url(
        forResource: "editor-synthetic", withExtension: "save", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  @Test func `reads the independent synthetic fixture`() throws {
    let sut = try CareerSave(Self.fixture())
    #expect(sut.cash == 1000)
    #expect(sut.alias == "TestDriver")
    #expect(try sut.cars().map(\.id) == [81])
  }

  @Test(arguments: [0, 4, 0x10, 0x14, 0x18, 0x4039, 63595])
  func `rejects damage to header cash and integrity fields`(offset: Int) throws {
    var bytes = try Self.fixture()
    bytes[offset] ^= 1
    #expect(throws: LauncherError.self) { try CareerSave(bytes) }
  }

  @Test func `cash changes affect only cash and integrity fields`() throws {
    let original = try Self.fixture()
    let sut = try CareerSave(original).applying(.money(operation: .multiply, amount: 100))
    #expect(sut.cash == 100_000)
    let digest = SHA256.hash(data: sut.data).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "229074e5638246381d24764178ca98d26892ab949b85cb8ec021e284d4091821")
    for offset in original.indices where original[offset] != sut.data[offset] {
      #expect(
        (0x4039..<0x403d).contains(offset) || (0x10..<0x1c).contains(offset) || offset >= 63580)
    }
    _ = try CareerSave(sut.data)
  }

  @Test func `rejects cash overflow and subtraction below zero`() throws {
    let sut = try CareerSave(Self.fixture())
    #expect(throws: LauncherError.self) {
      try sut.applying(.money(operation: .set, amount: UInt64.max))
    }
    #expect(throws: LauncherError.self) {
      try sut.applying(.money(operation: .multiply, amount: UInt64.max))
    }
    #expect(throws: LauncherError.self) {
      try sut.applying(.money(operation: .subtract, amount: 1001))
    }
    #expect(
      try sut.applying(.money(operation: .set, amount: UInt64(UInt32.max))).cash == UInt32.max)
  }

  @Test func `duplicates a car into independent garage and parts records`() throws {
    let sut = try CareerSave(Self.fixture()).applying(.duplicate(car: 81, count: 2))
    let cars = try sut.cars()
    #expect(cars.map(\.id) == [81, 82, 83])
    #expect(Set(cars.map(\.partsSlot)).count == 3)
    #expect(Set(cars.map(\.careerSlot)).count == 3)
    #expect(sut.cash == 1000)
    #expect(sut.data[0x4034] == 81)
    #expect(throws: LauncherError.self) { try sut.applying(.duplicate(car: 81, count: 25)) }
  }

  @Test func `rejects upgrades beyond the models real ladder`() throws {
    let sut = try CareerSave(Self.fixture())
    #expect(throws: LauncherError.self) {
      try sut.applying(
        .car(car: 81, levels: [1, 0, 0, 0, 0, 0, 0], junkman: 0, heat: 1, bounty: 0))
    }
    let edited = try sut.applying(
      .car(car: 81, levels: [0, 0, 0, 0, 0, 0, 3], junkman: 64, heat: 2.5, bounty: 987))
    let car = try #require(edited.cars().first)
    #expect(car.levels.last == 3)
    #expect(car.heat == 2.5)
    #expect(car.bounty == 987)
  }
}
