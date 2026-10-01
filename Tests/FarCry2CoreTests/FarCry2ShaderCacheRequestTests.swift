import Foundation
import LauncherCore
import Testing

@testable import FarCry2Core

struct FarCry2ShaderCacheRequestTests {
  @Test
  func `reset takes no file and the others take a cache export`() throws {
    #expect(try FarCry2ShaderCacheRequest(action: .reset).file() == nil)
    let export = FarCry2ShaderCacheRequest(action: .export, path: "/Users/me/A B.fc2shadercache")
    #expect(try export.file()?.path == "/Users/me/A B.fc2shadercache")
    #expect(
      try FarCry2ShaderCacheRequest(action: .import, path: "/tmp/x.fc2shadercache").file() != nil)
  }

  @Test(arguments: [
    FarCry2ShaderCacheRequest(action: .reset, path: "/tmp/x.fc2shadercache"),
    FarCry2ShaderCacheRequest(action: .export),
    FarCry2ShaderCacheRequest(action: .import),
    FarCry2ShaderCacheRequest(action: .export, path: "relative.fc2shadercache"),
    FarCry2ShaderCacheRequest(action: .export, path: "/tmp/cache.bin"),
    FarCry2ShaderCacheRequest(action: .import, path: "/tmp/cache"),
    FarCry2ShaderCacheRequest(action: .import, path: "/tmp/a\0b.fc2shadercache"),
    FarCry2ShaderCacheRequest(
      action: .export, path: "/" + String(repeating: "a", count: 4100) + ".fc2shadercache"),
  ])
  func `an incomplete or unsafe request is rejected`(request: FarCry2ShaderCacheRequest) {
    #expect(throws: LauncherError.self) { try request.file() }
  }

  @Test
  func `a request survives the trip through the helper's request file`() throws {
    let request = FarCry2ShaderCacheRequest(action: .import, path: "/tmp/x.fc2shadercache")
    let decoded = try JSONDecoder().decode(
      FarCry2ShaderCacheRequest.self, from: JSONEncoder().encode(request))
    #expect(decoded == request)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        FarCry2ShaderCacheRequest.self, from: Data(#"{"action":"format"}"#.utf8))
    }
  }
}
