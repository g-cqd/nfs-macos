import Foundation
import LauncherCore

/// What the EA client's own log says about the instance that is running now.
package enum ClientPhase: Equatable, Sendable {
  /// The client has not written its start line yet, or only an earlier run has.
  case notStarted
  /// The client started, and has not reported a completed sign-in and boot.
  case signedOut
  /// The client reported its sign-in and that it finished booting.
  case ready
}

/// Reads the client's own diagnostic log to learn whether it is signed in and booted.
///
/// A client that is signed in prints, after its start line, the telemetry events `login` and
/// `client.boot.ready` (measured in every signed-in start of two prefixes, with the first of them
/// appearing only after the player typed their credentials). Neither the `authenticated` flag EA
/// stamps on each event, which flips within one signed-in run, nor the modification time of a
/// file proves that, so the event names are the evidence.
///
/// Only the presence of those names after the last start line is learned. Nothing else in the log
/// is kept, shown, copied or interpreted, and no credential, cookie or token file is opened. The
/// read is bounded to the end of the file.
package struct ClientLogProbe: Equatable, Sendable {
  package let log: URL
  package let startMarker: String
  package let readyEvents: [String]
  /// The most this reads from the end of the log.
  package static let window = 4 * 1_024 * 1_024
  /// How much earlier than the moment the client was started its start line may be stamped.
  package static let tolerance: TimeInterval = 2

  package init(log: URL, startMarker: String, readyEvents: [String]) {
    self.log = log
    self.startMarker = startMarker
    self.readyEvents = readyEvents
  }

  /// - Parameter since: When this client was started. A start line stamped before it belongs to
  ///   an earlier run and does not count. Pass nil for a client that was already running.
  package func phase(since: Date?) -> ClientPhase {
    guard let (text, truncated) = tail() else { return .notStarted }
    guard let start = text.range(of: startMarker, options: .backwards) else {
      // A client that has run longer than the window holds has no start line left in it, and the
      // window is then all of that run; a client that was just started always has one.
      return truncated && since == nil && hasReadyEvents(in: text[...]) ? .ready : .notStarted
    }
    if let since {
      guard let stamp = Self.timestamp(of: text, at: start.lowerBound),
        stamp >= since.addingTimeInterval(-Self.tolerance)
      else { return .notStarted }
    }
    return hasReadyEvents(in: text[start.upperBound...]) ? .ready : .signedOut
  }

  private func hasReadyEvents(in segment: Substring) -> Bool {
    readyEvents.allSatisfy { segment.contains("Telemetry Event [\($0)]") }
  }

  /// The end of the log as text, and whether earlier text was left out; nil when it is absent,
  /// empty or unreadable.
  private func tail() -> (String, truncated: Bool)? {
    guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
    let start = size > UInt64(Self.window) ? size - UInt64(Self.window) : 0
    guard (try? handle.seek(toOffset: start)) != nil,
      let data = try? handle.read(upToCount: Self.window)
    else { return nil }
    return (String(decoding: data, as: UTF8.self), start > 0)
  }

  /// The ISO-8601 stamp at the front of the line that holds `index`, such as
  /// `[2026-10-02T13:25:56.046Z]`.
  static func timestamp(of text: String, at index: String.Index) -> Date? {
    // The real log ends its lines with CRLF, which Swift reads as one character that is not "\n".
    let lineStart =
      text[..<index].lastIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
      .map { text.index(after: $0) } ?? text.startIndex
    let line = text[lineStart..<index]
    guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]")
    else { return nil }
    let value = String(line[line.index(after: open)..<close])
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

/// How a wait for the client ended when the client itself kept running.
package enum ClientWaitResult: Equatable, Sendable {
  case ready(seconds: Int)
  /// The bound passed with the client alive. The client is left running.
  case timedOut(ClientPhase)

  /// What to tell the player when the wait ended without the client being ready.
  package var notice: String? {
    guard case .timedOut(let phase) = self else { return nil }
    switch phase {
    case .signedOut:
      return """
        The EA app is open but not signed in. Sign in to it, then press Play again. It stays \
        running; Play reuses it.
        """
    case .notStarted, .ready:
      return """
        The EA app is running but has not reported that it finished starting. Leave it open and \
        give it a moment, sign in if it asks, then press Play again. Play reuses it.
        """
    }
  }
}

/// Waits for a running client to report that it is signed in and booted.
///
/// It never ends the client. A client that is still alive when the bound passes stays running for
/// the player and for the next attempt; only a client that has already exited is an error.
package struct ClientWait {
  package let deadline: Int

  package init(deadline: Int) { self.deadline = deadline }

  /// - Parameter phase: The client's state now, from its own log.
  /// - Parameter isRunning: Whether the client process is still alive.
  /// - Parameter wait: Sleeps for one poll interval; injected so tests never sleep.
  /// - Throws: A failure when the client exits before it is ready.
  package func run(
    phase: () -> ClientPhase, isRunning: () -> Bool, wait: (Int) throws -> Void
  ) throws(LauncherError) -> ClientWaitResult {
    var waited = 0
    var last = ClientPhase.notStarted
    while waited <= deadline {
      last = phase()
      if last == .ready { return .ready(seconds: waited) }
      guard isRunning() else {
        throw .operation(
          """
          The EA app stopped before it was ready. Press Open EA App, sign in, quit it, then \
          press Play again.
          """)
      }
      do { try wait(1) } catch {
        throw LauncherError.operation("The wait for the EA app was interrupted.")
      }
      waited += 1
    }
    return .timedOut(last)
  }
}
