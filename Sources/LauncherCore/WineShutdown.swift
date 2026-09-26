package enum WineShutdown {
  /// Wine returns 1 when -k finds no server; -w must still confirm the lock is released.
  package static func stop(run: (String) throws -> Int32) throws {
    let signal = try run("-k")
    guard signal == 0 || signal == 1 else {
      throw LauncherError.operation("Wine could not request server shutdown (\(signal)).")
    }
    guard try run("-w") == 0 else {
      throw LauncherError.operation("Wine did not finish shutting down.")
    }
  }
}
