import Foundation

/// A throwaway directory tree shaped like an installed PC game. Every file holds invented bytes.
package struct SyntheticInstall {
  package let root: URL
  package let install: URL

  /// Creates `<root>/Far Cry 2` with `bin`, `Data_Win32` and installer leftovers the rules must skip.
  package init(executable: [UInt8]? = nil) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    install = root.appendingPathComponent("Far Cry 2")
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try write("bin/FarCry2.exe", executable ?? PEFixture.make())
    try write("bin/Dunia.dll", Array("synthetic engine library".utf8))
    try write("bin/binkw32.dll", Array("synthetic video library".utf8))
    try write("Data_Win32/common.fat", Array("fat table".utf8))
    try write("Data_Win32/common.dat", Array("archive payload".utf8))
    try write("Data_Win32/worlds.fat", Array("worlds table".utf8))
    try write("Data_Win32/worlds.dat", Array("worlds payload".utf8))
    try write("Data_Win32/sound_english.fat", Array("sound table".utf8))
    try write("Data_Win32/sound_english.dat", Array("sound payload".utf8))
    // Items that must never reach the private copy.
    try write("unins000.exe", Array("uninstaller".utf8))
    try write("goggame-0000000000.info", Array("{}".utf8))
    try write("Support/vcredist_x86.exe", Array("redistributable".utf8))
    try write("bin/mtld3d.conf", Array("render.scale = 1\n".utf8))
    try write("bin/mtld3d_shaders.bin", Array("cache".utf8))
    try write("bin/mtld3d-logs/FarCry2-1.log", Array("log".utf8))
    try write("bin/.DS_Store", Array("finder".utf8))
  }

  package func url(_ relative: String) -> URL { install.appendingPathComponent(relative) }

  package func write(_ relative: String, _ bytes: [UInt8]) throws {
    let target = url(relative)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: target)
  }

  package func remove(_ relative: String) throws {
    try FileManager.default.removeItem(at: url(relative))
  }

  package func cleanup() {
    do { try FileManager.default.removeItem(at: root) } catch {
      print("Fixture cleanup failed: \(error)")
    }
  }
}
