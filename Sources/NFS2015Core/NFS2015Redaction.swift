import Foundation

/// Keeps account, session and token data, and the player's name, out of anything this app writes
/// for the player to send to someone else.
///
/// Three layers apply to every line that may come from Wine's output, which also carries the EA
/// app's own messages: only lines of a few known diagnostic shapes are admitted at all
/// (`isDiagnostic`); a line that mentions a secret-bearing word is dropped whole; and what is
/// left has long machine-looking strings masked and the home folder's name replaced. The final
/// report is passed through the drop and the home-folder mask a second time (`scrubReport`).
package enum NFS2015Redaction {
  /// Words that mark a line as possibly carrying a credential or an identity. Matched without
  /// regard to case. The report's own labels avoid these words.
  static let markers = [
    "token", "authcode", "auth_code", "bearer", "cookie", "password", "passwd", "secret", "jwt",
    "nucleus", "authorization", "signin", "sign-in", "login", "email", "e-mail", "persona",
    "account", "sessionid", "session_id", "sid=", "apikey", "api_key", "credential", "oauth",
    "access_key", "x-ea", "set-cookie",
  ]

  /// Line shapes worth keeping from Wine's output: Wine's own unhandled-fault messages, the
  /// Direct3D layer's `info:` and `warn:` lines, the x87 sidecar's lines, `err:` lines and the
  /// `seh` trace of the diagnostic log.
  static let diagnosticPrefixes = [
    "wine: ", "info:  ", "warn:  ", "[rosettax87]", "err:", "fixme:",
  ]

  /// Whether a log line is one of the shapes worth keeping, before any scrubbing.
  package static func isDiagnostic(_ line: String) -> Bool {
    diagnosticPrefixes.contains { line.hasPrefix($0) } || line.contains(":trace:seh:")
      || line.contains(":err:")
  }

  /// Whether a line mentions a word that can mark a credential or an identity.
  package static func carriesMarker(_ line: String) -> Bool {
    let folded = line.lowercased()
    return markers.contains { folded.contains($0) } || containsAddress(line)
  }

  /// Whether the line has something shaped like `name@host.tld`. A bare `@` is not one: display
  /// modes are written `1920x1200@60`.
  static func containsAddress(_ line: String) -> Bool {
    var rest = Substring(line)
    while let at = rest.firstIndex(of: "@") {
      let after = rest[rest.index(after: at)...].prefix { !$0.isWhitespace && $0 != "\"" }
      let before = rest[..<at].last
      if before?.isLetter == true || before?.isNumber == true, after.first?.isLetter == true,
        let dot = after.firstIndex(of: "."), dot > after.startIndex,
        after.index(after: dot) < after.endIndex
      {
        return true
      }
      rest = rest[rest.index(after: at)...]
    }
    return false
  }

  /// The line with long machine-looking strings masked and the home folder's name replaced; nil
  /// when the line mentions a secret-bearing word and must go whole.
  /// - Complexity: O(line length).
  package static func scrub(_ line: String) -> String? {
    guard !carriesMarker(line) else { return nil }
    return maskLongStrings(maskHome(String(line.prefix(400))))
  }

  /// Applies the drop and the home-folder mask to a whole text that this app composed itself, so
  /// the hashes and revisions it records are kept. A line that must go is replaced with a note.
  package static func scrubReport(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      carriesMarker(String(line))
        ? "<line removed: it mentions a credential-related word>" : maskHome(String(line))
    }.joined(separator: "\n")
  }

  /// `/Users/name/...` becomes `/Users/<user>/...`.
  static func maskHome(_ line: String) -> String {
    var result = ""
    var rest = Substring(line)
    while let range = rest.range(of: "/Users/") {
      result += rest[..<range.upperBound]
      rest = rest[range.upperBound...]
      let name = rest.prefix { $0 != "/" && $0 != " " && $0 != "\"" && $0 != "'" }
      result += name.isEmpty ? "" : "<user>"
      rest = rest.dropFirst(name.count)
    }
    return result + rest
  }

  /// Runs of 24 or more characters from the base64, hexadecimal and identifier alphabets that
  /// hold both a letter and a digit become `<masked>`: they are keys, hashes or ids, never words.
  static func maskLongStrings(_ line: String) -> String {
    func isTokenCharacter(_ character: Character) -> Bool {
      character.isASCII && (character.isLetter || character.isNumber || "+/_-".contains(character))
    }
    var result = ""
    var run = ""
    func flush() {
      let mixed = run.contains(where: \.isLetter) && run.contains(where: \.isNumber)
      result += run.count >= 24 && mixed ? "<masked>" : run
      run = ""
    }
    for character in line {
      if isTokenCharacter(character) {
        run.append(character)
      } else {
        flush()
        result.append(character)
      }
    }
    flush()
    return result
  }
}
