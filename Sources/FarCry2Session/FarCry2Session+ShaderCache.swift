import FarCry2Core
import Foundation
import LauncherCore
import Metal

extension FarCry2Session {
  /// The saved shader cache for this build, or one that does nothing when the build carries no key.
  func shaderCache() -> FarCry2ShaderCache {
    var key: ShaderCacheKey?
    do { key = try ShaderCacheKey.read(from: paths.resources) } catch {
      print("Shader cache is not kept between sessions: \(error.localizedDescription)")
    }
    return FarCry2ShaderCache(
      paths: paths, key: key,
      origin: ShaderCacheOrigin(
        gpu: MTLCreateSystemDefaultDevice()?.name,
        system: ProcessInfo.processInfo.operatingSystemVersionString))
  }

  /// The cache is an optimisation: a failure is logged and the game still starts or ends normally.
  func attempt(_ action: String, _ body: () throws -> Void) {
    do { try body() } catch {
      print("Shader cache: could not \(action): \(error.localizedDescription)")
    }
  }

  func report(launch: ShaderCacheLaunch) {
    switch launch {
    case .unavailable:
      print("Shader cache: this build keeps it in the game folder only.")
    case .cold:
      print(
        "Shader cache: none yet for this renderer build. The first launch compiles shaders and may pause; the result is saved."
      )
    case .warm(let bytes):
      print("Shader cache: starting from \(bytes) saved bytes for this renderer build.")
    }
  }

  func report(harvest: ShaderCacheHarvest) {
    switch harvest {
    case .none, .unchanged: break
    case .saved(let bytes): print("Shader cache: saved \(bytes) bytes.")
    case .discarded: print("Shader cache: removed a cache in the game folder that was not usable.")
    case .tooLarge:
      print("Shader cache: the game's cache is too large to keep; the saved one is unchanged.")
    }
  }

  func perform(_ request: FarCry2ShaderCacheRequest, _ cache: FarCry2ShaderCache, game: URL) throws
  {
    switch request.action {
    case .reset:
      let bytes = try cache.reset(game: game)
      print("Shader cache: removed \(bytes) saved bytes. The next launch compiles shaders again.")
    case .export:
      guard let file = try request.file() else { throw LauncherError.operation("Choose a file.") }
      let manifest = try cache.export(to: file, game: game)
      print("Shader cache: exported \(manifest.payloadBytes) bytes for \(manifest.key.summary).")
    case .import:
      guard let file = try request.file() else { throw LauncherError.operation("Choose a file.") }
      switch try cache.importCache(from: file, game: game) {
      case .installed(let bytes): print("Shader cache: imported; now \(bytes) bytes.")
      case .merged(let bytes):
        print("Shader cache: merged into the saved cache; now \(bytes) bytes.")
      case .alreadyPresent: print("Shader cache: that cache was already imported; nothing changed.")
      }
    }
  }
}
