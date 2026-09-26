import Testing

@testable import LauncherCore

struct WineShutdownTests {
  @Test(arguments: [Int32(0), Int32(1)])
  func `waits for server exit even when the stop signal found no server`(signalStatus: Int32) throws
  {
    var arguments: [String] = []
    try WineShutdown.stop { argument in
      arguments.append(argument)
      return argument == "-k" ? signalStatus : 0
    }
    #expect(arguments == ["-k", "-w"])
  }

  @Test func `failed wait prevents offline registry edits`() {
    #expect(throws: LauncherError.self) {
      try WineShutdown.stop { $0 == "-k" ? 0 : 2 }
    }
  }
}
