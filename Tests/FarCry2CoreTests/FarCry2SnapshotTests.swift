import Foundation
import Testing

@testable import FarCry2Core

struct FarCry2SnapshotTests {
  @Test
  func `the cache status round trips through the state file the helper writes`() throws {
    let status = ShaderCacheStatus(
      state: .warm, bytes: 2_097_152, saved: Date(timeIntervalSince1970: 1_790_000_000),
      origin: .init(gpu: "Apple M1", system: "macOS 27"), otherBuilds: 1,
      renderer: "mtld3d 5f5331a2")
    let snapshot = FarCry2Snapshot(
      settings: .init(), profile: .ready, installation: nil, backups: [], shaderCache: status)
    let decoded = try JSONDecoder().decode(
      FarCry2Snapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot && decoded.shaderCache == status)
  }

  @Test
  func `a state file from before the cache existed still decodes`() throws {
    let snapshot = FarCry2Snapshot(
      settings: .init(), profile: .missing, installation: nil, backups: [])
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    #expect(object.removeValue(forKey: "shaderCache") == nil, "a nil status is not written")
    let old = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(FarCry2Snapshot.self, from: old).shaderCache == nil)
  }

  @Test
  func `only an empty cache shows the first launch notice`() {
    #expect(ShaderCacheStatus(state: .empty).firstRunNotice?.contains("first launch") == true)
    #expect(ShaderCacheStatus(state: .warm, bytes: 1).firstRunNotice == nil)
    #expect(ShaderCacheStatus(state: .unavailable).firstRunNotice == nil)
  }
}
