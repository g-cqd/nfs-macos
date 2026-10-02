import AppKit
import FarCry2Core
import Foundation
import UniformTypeIdentifiers

extension FarCry2Model {
  var canResetShaderCache: Bool {
    !isBusy && hasGameData && (shaderCache.state == .warm || shaderCache.otherBuilds > 0)
  }
  var canExportShaderCache: Bool { !isBusy && hasGameData && shaderCache.state == .warm }
  var canImportShaderCache: Bool { !isBusy && hasGameData && shaderCache.state != .unavailable }

  /// Explains the one-time pause while there is no cache to start from.
  var shaderCacheNotice: String? { hasGameData ? shaderCache.firstRunNotice : nil }

  /// One line for the Play page and the cache page.
  var shaderCacheSummary: String {
    switch shaderCache.state {
    case .unavailable:
      "This build keeps the cache in the game folder only, so it is not saved across updates."
    case .empty: "No shader cache yet."
    case .warm:
      "\(shaderCache.bytes.formatted(.byteCount(style: .file))) saved"
        + (shaderCache.saved.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" }
          ?? "")
    }
  }

  /// Where the cache was last written, as a sentence; nil when nothing is recorded.
  var shaderCacheOrigin: String? {
    guard let origin = shaderCache.origin else { return nil }
    let parts = [origin.gpu, origin.system].compactMap { $0 }
    return parts.isEmpty ? nil : "Last written on " + parts.joined(separator: ", ")
  }

  func resetShaderCache() {
    shaderResetConfirmation = false
    guard canResetShaderCache else { return }
    enqueue(.helper(.shaderCache(.init(action: .reset))))
  }
  func exportShaderCache() {
    guard canExportShaderCache else { return }
    enqueue(.exportShaderCache)
  }
  func importShaderCache() {
    guard canImportShaderCache else { return }
    enqueue(.importShaderCache)
  }

  func exportShaderCacheFile() async throws {
    let panel = NSSavePanel()
    panel.title = "Export Far Cry 2 shader cache"
    panel.message =
      "The file holds shader data the game generated on this Mac. Keep it for your own use; it is not meant to be shared."
    panel.allowedContentTypes = Self.shaderCacheTypes
    panel.nameFieldStringValue = "Far Cry 2 Shader Cache.\(ShaderCacheExport.fileExtension)"
    guard await panel.begin() == .OK, let url = panel.url else { return }
    try Task.checkCancellation()
    updateShaderCache(
      try await service.perform(
        .shaderCache(.init(action: .export, path: url.standardizedFileURL.path))))
  }

  func importShaderCacheFile() async throws {
    let panel = NSOpenPanel()
    panel.title = "Import Far Cry 2 shader cache"
    panel.message = "Choose a shader cache exported by this version of the starter."
    panel.allowedContentTypes = Self.shaderCacheTypes
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard await panel.begin() == .OK, let url = panel.url else { return }
    try Task.checkCancellation()
    updateShaderCache(
      try await service.perform(
        .shaderCache(.init(action: .import, path: url.standardizedFileURL.path))))
  }

  private static var shaderCacheTypes: [UTType] {
    [UTType(filenameExtension: ShaderCacheExport.fileExtension) ?? .data]
  }
}
