import Testing

@testable import NFS2015Core

struct MemoryPressureTests {
  private let gigabyte: UInt64 = 1_073_741_824

  @Test
  func `swap nearly full and large is heavy and says so`() throws {
    let sut = MemoryPressure(swapUsed: 17 * gigabyte, swapTotal: 18 * gigabyte)
    #expect(sut.isHeavy)
    let notice = try #require(sut.notice)
    #expect(notice.contains("short of memory"))
    #expect(notice.contains("17.0 GB"))
  }

  @Test
  func `a little swap, or a large swap with room left, is not heavy`() {
    #expect(MemoryPressure(swapUsed: 2 * gigabyte, swapTotal: 2 * gigabyte).notice == nil)
    #expect(MemoryPressure(swapUsed: 6 * gigabyte, swapTotal: 18 * gigabyte).notice == nil)
    #expect(MemoryPressure(swapUsed: 0, swapTotal: 0).notice == nil)
  }

  @Test
  func `the live reading never fails the caller`() {
    // Present on every macOS; the value itself is the machine's, so only its shape is checked.
    if let live = MemoryPressure.current() { #expect(live.swapUsed <= live.swapTotal) }
  }
}
