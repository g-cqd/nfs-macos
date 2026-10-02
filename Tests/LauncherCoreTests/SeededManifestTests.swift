import Foundation
import GameFixtures
import Testing

@testable import LauncherCore

struct SeededManifestTests {
  private let digest = String(repeating: "a", count: 64)

  private func file(_ path: String, size: Int = 1) -> ManifestFile {
    ManifestFile(path: path, size: size, sha256: digest)
  }

  private func seeded(
    files: [ManifestFile], client: StoreClientPlan? = SeededFixture.plan,
    renderers: [RendererSelection] = SeededFixture.renderers, rules: ImportRules? = nil,
    referencing: Bool? = nil
  ) -> BundleManifest {
    BundleManifest(
      version: "abc123", gameFiles: files, gameID: .nfs2015, importRules: rules,
      referencesInstallation: referencing, storeClient: client, renderers: renderers)
  }

  @Test
  func `accepts a bundled manifest that lists the game's files and names its store client`() throws
  {
    let manifest = seeded(files: [
      file("NFS16.exe"), file("Core/Activation64.dll"), file("Data/cas_01.cas"),
    ])
    try manifest.validate()
    #expect(manifest.seedsPrefix)
    #expect(!manifest.references)
    #expect(manifest.client == SeededFixture.plan)
  }

  @Test
  func `an import manifest and a copying game do not seed a prefix`() throws {
    #expect(
      !BundleManifest(
        version: "abc123", gameFiles: [], gameID: .nfs2015, referencesInstallation: true,
        storeClient: SeededFixture.plan, renderers: SeededFixture.renderers
      ).seedsPrefix)
    #expect(
      !BundleManifest(version: "abc123", gameFiles: [file("speed.exe")], gameID: .nfsmw)
        .seedsPrefix)
  }

  @Test
  func `rejects a bundled manifest that is incomplete`() {
    let exe = file("NFS16.exe")
    for manifest in [
      seeded(files: []),
      seeded(files: [exe], client: nil),
      seeded(files: [file("Core/Activation64.dll")]),
      seeded(files: [exe, file("nfs16.EXE")]),
      seeded(files: [exe], renderers: []),
      seeded(files: [exe, file("Data/huge.cas", size: GameKind.nfs2015.fileByteLimit + 1)]),
      seeded(files: [exe, ManifestFile(path: "Data/short.cas", size: 1, sha256: "abc")]),
      seeded(files: [exe], renderers: [RendererSelection(api: "dxgi", backend: "gptk")]),
    ] {
      #expect(throws: LauncherError.self) { try manifest.validate() }
    }
  }

  @Test
  func `rejects a bundled manifest that is also an import manifest`() {
    #expect(throws: LauncherError.self) {
      try seeded(files: [file("NFS16.exe")], referencing: true).validate()
    }
  }

  @Test
  func `rejects a store-client manifest that carries recognition rules`() throws {
    let rules = try RecipeRules.farCry2()
    #expect(throws: LauncherError.self) {
      try seeded(files: [file("NFS16.exe")], rules: rules).validate()
    }
  }

  @Test(arguments: [
    "../outside.dll", "/absolute.dll", "Data//double.cas", "Core\\back.dll", "Data/./dot.cas", "",
  ])
  func `rejects an unsafe game file path`(path: String) {
    #expect(throws: LauncherError.self) {
      try seeded(files: [file("NFS16.exe"), file(path)]).validate()
    }
  }

  @Test(arguments: [
    "machine.ini", "Core/Machine.INI", "Data/user.reg", "Data/system.reg", "Core/cookies",
    "Core/Cookies.sqlite", "Core/Login Data", "Data/session.json", "Data/auth.json",
    "NFS16.dxvk-cache", "Data/PROFILEOPTIONS_profile", "Core/state.log", "Core/archive.zip",
    "Core/archive.7z", "Core/AppData/Local/x.bin", "Users/player/state.bin",
    "Core/Electronic Arts/EA Desktop/state", "ProgramData/Origin/token.bin", "Documents/save.dat",
    "Data/Cache/shaders.bin", "Core/hashes.sha256",
  ])
  func `rejects account, machine and archive state among the game files`(path: String) {
    #expect(ManifestFile.isAccountState(path: path))
    #expect(throws: LauncherError.self) {
      try seeded(files: [file("NFS16.exe"), file(path)]).validate()
    }
  }

  @Test(arguments: [
    "NFS16_trial.exe", "Core/Activation64.dll", "Core/codecs/qcncodecs4.dll",
    "Data/Win32/loc/en.toc", "Data/cas_01.cas", "Update/Patch/package.mft",
    "__Installer/installerdata.xml", "__Installer/InstallLog.txt", "Support/mnfst.txt",
    "Support/EA Help/Technical Support.en_US.rtf",
  ])
  func `accepts the files an installation of the game actually holds`(path: String) throws {
    #expect(!ManifestFile.isAccountState(path: path))
    try seeded(files: [file("NFS16.exe"), file(path)]).validate()
  }
}

struct WindowsPathRegistryTests {
  private func setting(_ value: String, kind: RegistrySetting.Kind = .windowsPath)
    -> RegistrySetting
  {
    RegistrySetting(
      hive: .localMachine, path: #"Software\Wow6432Node\EA Games\Need for Speed"#,
      name: "Install Dir", value: value, kind: kind)
  }

  private static let installDir = #"C:\Program Files\EA Games\Need for Speed\"#

  @Test
  func `writes a guest path with doubled backslashes, as a registry script requires`() throws {
    let script = try #require(try RegistrySetting.script([setting(Self.installDir)]))
    #expect(
      script
        == """
        REGEDIT4

        [HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\EA Games\\Need for Speed]
        "Install Dir"="C:\\\\Program Files\\\\EA Games\\\\Need for Speed\\\\"

        """)
  }

  @Test
  func `recognises the value in the form Wine writes it into its hive`() {
    let hive = """
      WINE REGISTRY Version 2

      [Software\\\\Wow6432Node\\\\EA Games\\\\Need for Speed] 1790449979
      #time=1dd4deb0b40400c
      "Install Dir"="C:\\\\Program Files\\\\EA Games\\\\Need for Speed\\\\"
      "Locale"="en_US"

      """
    #expect(setting(Self.installDir).isRecorded(in: hive))
    #expect(!setting(#"C:\Program Files\Other\"#).isRecorded(in: hive))
    #expect(!setting(Self.installDir).isRecorded(in: ""))
  }

  @Test(arguments: [
    #"C:\Program Files\EA Games\Need for Speed"#, #"D:\Games\NFS\"#, #"c:\games"#,
    #"C:\Program Files (x86)\Common Files\EAInstaller\"#,
  ])
  func `accepts a plain drive-letter folder`(value: String) throws {
    try setting(value).validate()
  }

  @Test(arguments: [
    "", "C:", #"C:\"#, "C:/Games", #"\Games"#, #"CC:\Games"#, #"C:\..\Windows"#, #"C:\a\.\b"#,
    #"C:\a\\b"#, #"C:\a"b"#, #"C:\a;b"#, "C:\\a\nb", #"\\server\share"#, #"C:\a[b]"#,
    "C:\\" + String(repeating: "a", count: 260),
  ])
  func `rejects anything that is not a plain drive-letter folder`(value: String) {
    #expect(throws: LauncherError.self) { try setting(value).validate() }
  }

  @Test
  func `a plain string value still cannot carry a backslash`() {
    #expect(throws: LauncherError.self) {
      try setting(Self.installDir, kind: .string).validate()
    }
  }
}
