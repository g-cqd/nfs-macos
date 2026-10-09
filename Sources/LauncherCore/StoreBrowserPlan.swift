import Darwin
import Foundation

/// A store web page that starts the game, opened in a browser of the player's own.
///
/// Battlefield 3 is started by Battlelog, not by the EA app: EA's Play button only opens the
/// page, and the page asks EA's local service (`POST http://127.0.0.1:3215/game/launch`) to start
/// the game. That needs a browser the page accepts, which is a 32-bit Windows one, and one that
/// lets an HTTPS page call plain HTTP on the loopback address. Chromium-family browsers allow it;
/// WebKit (Safari, and `WKWebView`, which has no public setting for it) blocks it as mixed
/// content. The app therefore starts an installed Chromium-family browser with its own profile
/// folder inside the player's folder and the identity the page needs. It never reads the profile.
package struct StoreBrowserPlan: Codable, Equatable, Sendable {
  /// One page the player can open, such as the campaign or the multiplayer home.
  package struct Page: Codable, Equatable, Sendable {
    package let name: String
    package let title: String
    package let url: String

    package init(name: String, title: String, url: String) {
      self.name = name
      self.title = title
      self.url = url
    }
  }

  /// The store's name, shown to the player.
  package let name: String
  package let pages: [Page]
  /// The browser identity the page accepts.
  package let userAgent: String
  /// Bundle identifiers of browsers that allow the loopback request, in order of preference.
  package let browsers: [String]
  /// The profile folder, relative to the player's folder.
  package let profileFolder: String
  /// The local service the page calls, and how to tell it is up.
  package let service: LocalServiceProbe

  package init(
    name: String, pages: [Page], userAgent: String, browsers: [String], profileFolder: String,
    service: LocalServiceProbe
  ) {
    self.name = name
    self.pages = pages
    self.userAgent = userAgent
    self.browsers = browsers
    self.profileFolder = profileFolder
    self.service = service
  }

  /// Rejects a page that is not HTTPS, an identity a command line could misread, an unbounded
  /// list or a profile folder that is not one plain name.
  package func validate() throws(LauncherError) {
    guard !name.isEmpty, name.utf8.count <= 64, (1...8).contains(pages.count),
      (1...8).contains(browsers.count)
    else {
      throw .operation("The store browser needs a name, 1-8 pages and 1-8 browsers.")
    }
    var names = Set<String>()
    for page in pages {
      guard (1...32).contains(page.name.utf8.count),
        page.name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
        (1...64).contains(page.title.utf8.count), names.insert(page.name).inserted,
        page.url.utf8.count <= 256, let url = URL(string: page.url), url.scheme == "https",
        url.host?.isEmpty == false, url.user == nil, url.password == nil,
        !page.url.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 })
      else {
        throw .operation("A store page must be a plain HTTPS address with a short name.")
      }
    }
    guard (16...256).contains(userAgent.utf8.count),
      userAgent.unicodeScalars.allSatisfy({ (32...126).contains($0.value) && $0 != "\"" })
    else {
      throw .operation("The store browser identity must be plain printable text.")
    }
    guard
      browsers.allSatisfy({ id in
        (3...128).contains(id.utf8.count)
          && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46
              || $0 == 45
          }
      }), Set(browsers).count == browsers.count
    else {
      throw .operation("The store browsers must be distinct bundle identifiers.")
    }
    guard (1...64).contains(profileFolder.utf8.count), !profileFolder.hasPrefix("."),
      profileFolder.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 95
      })
    else {
      throw .operation("The store browser profile must be one plain folder name.")
    }
    try service.validate()
  }

  /// The page with this name, or the first page when no name is given.
  package func page(named name: String?) throws(LauncherError) -> Page {
    guard let name else { return pages[0] }
    guard let page = pages.first(where: { $0.name == name }) else {
      throw .operation("This app has no store page named \(name).")
    }
    return page
  }

  /// The arguments the browser is started with: its own profile, the identity, no first-run
  /// prompts, and the page. A new instance is required so the arguments are not dropped by an
  /// already running copy of the same browser.
  package func arguments(profile: URL, page: Page) -> [String] {
    [
      "--user-data-dir=\(profile.path)", "--user-agent=\(userAgent)", "--no-first-run",
      "--no-default-browser-check", page.url,
    ]
  }

  /// The first preferred browser that is installed, as the lookup reports it.
  package func browser(installed: (String) -> URL?) -> (identifier: String, url: URL)? {
    for identifier in browsers {
      if let url = installed(identifier) { return (identifier, url) }
    }
    return nil
  }
}

/// A loopback HTTP service and the reply that means it is up.
package struct LocalServiceProbe: Codable, Equatable, Sendable {
  /// A `http://127.0.0.1:<port>/…` address.
  package let url: String
  /// The `Origin` header the service expects from its web page.
  package let origin: String
  /// Text the reply contains when the service is up.
  package let reply: String
  /// How long one start waits for the service.
  package let seconds: Int

  package init(url: String, origin: String, reply: String, seconds: Int) {
    self.url = url
    self.origin = origin
    self.reply = reply
    self.seconds = seconds
  }

  package var port: Int? { URL(string: url)?.port }

  package func validate() throws(LauncherError) {
    guard let address = URL(string: url), address.scheme == "http", address.host == "127.0.0.1",
      let port = address.port, (1024...65535).contains(port), url.utf8.count <= 128
    else {
      throw .operation("A local service must be plain HTTP on 127.0.0.1 and an unprivileged port.")
    }
    guard let origin = URL(string: origin), origin.scheme == "https", self.origin.utf8.count <= 128,
      (1...64).contains(reply.utf8.count), (5...600).contains(seconds)
    else {
      throw .operation("A local service needs an HTTPS origin, a reply and a bounded wait.")
    }
  }

  /// One plain HTTP/1.1 request over a loopback socket with a short timeout; true when the reply
  /// contains the expected text. A socket rather than `URLSession`: the address is fixed to
  /// 127.0.0.1, so no proxy, cache or transport policy can apply or answer instead.
  package func answers(timeout: Int = 3) -> Bool {
    guard let address = URL(string: url), let port = address.port, address.host == "127.0.0.1"
    else { return false }
    let path = address.path.isEmpty ? "/" : address.path
    let query = address.query.map { "?" + $0 } ?? ""
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var limit = timeval(tv_sec: timeout, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, size)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, size)
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = in_port_t(UInt16(port).bigEndian)
    target.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
    let connected = withUnsafePointer(to: &target) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { return false }
    let request =
      "GET \(path)\(query) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: \(origin)\r\n"
      + "Connection: close\r\n\r\n"
    let sent = request.utf8CString.withUnsafeBufferPointer {
      send(descriptor, $0.baseAddress, $0.count - 1, 0)
    }
    guard sent > 0 else { return false }
    var reply = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while reply.count < 16_384 {
      let count = recv(descriptor, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      reply.append(contentsOf: buffer[0..<count])
    }
    return String(decoding: reply, as: UTF8.self).contains(self.reply)
  }

  /// Polls until the service answers or the bounded wait ends.
  /// - Returns: The seconds it took, or nil when it never answered.
  package func wait(
    pollEvery interval: UInt32 = 3, stillStarting: () -> Bool = { true }
  ) -> Int? {
    let start = Date()
    while Date().timeIntervalSince(start) < Double(seconds) {
      if answers() { return Int(Date().timeIntervalSince(start)) }
      guard stillStarting() else { return nil }
      sleep(interval)
    }
    return nil
  }
}
