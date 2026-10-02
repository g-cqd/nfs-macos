import FarCry2Core
import Foundation
import LauncherCore

/// A player folder shaped like a freshly initialised Wine prefix, with invented profile contents.
struct FarCry2Fixture {
  /// Attribute names and sample values come from public reports of the game's profile; the file is
  /// otherwise invented. It is not game data.
  static let profileXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <GamerProfile>
      <!-- <RenderProfile Platform="d3d10"> inside a comment must be ignored -->
      <RenderProfile MultiSampleMode="0" AlphaToCoverage="0" ResolutionX="1440" ResolutionY="900" Quality="customd3d10" Fullscreen="0" Maximized="0" VSync="1" RefreshRate="0" DisableMip0Loading="1" Platform="d3d10a" ShowFPS="0" AllowAsynchShaderLoading="1">
        <CustomQuality>
          <quality id="custom" ResolutionX="800" ResolutionY="600" EnvironmentQuality="2" TextureQuality="2"/>
          <quality id="customd3d10" ResolutionX="800" ResolutionY="600" EnvironmentQuality="2"/>
        </CustomQuality>
      </RenderProfile>
      <Audio Volume="0.8"/>
    </GamerProfile>

    """

  /// The profile Far Cry 2 wrote on its first launch under the bundled Wine and mtld3d, unedited.
  static let realProfileXML = """
    <GamerProfile>
    	<SoundProfile MusicEnabled="1" MasterVolume="100" />
    	<RenderProfile MultiSampleMode="0" AlphaToCoverage="0" ResolutionX="1280" ResolutionY="800" Quality="optimal" Fullscreen="1" Maximized="0" ForceWidescreen="0" WidescreenFOV="0" AspectRatio="0" VSync="0" RefreshRate="0" DisableMip0Loading="0" MaxDriverBufferedFrames="0" Platform="d3d9" ShowFPS="0" ClustersZPassMaxLOD="1" Brightness="1" Contrast="1" GammaRamp="1" GammaRampR="1" GammaRampG="1" GammaRampB="1" AllowAsynchShaderLoading="1">
    		<CustomQuality>
    			<quality ResolutionX="800" ResolutionY="600" EnvironmentQuality="medium" AntiPortalQuality="high" PostFxQuality="medium" TextureQuality="medium" TextureResolutionQuality="medium" WaterQuality="medium" DepthPassQuality="medium" VegetationQuality="medium" TerrainQuality="medium" GeometryQuality="medium" AmbientQuality="medium" ShadowQuality="medium" Hdr="0" HdrFP32="0" Bloom="1" id="custom" />
    			<quality ResolutionX="800" ResolutionY="600" EnvironmentQuality="high" AntiPortalQuality="high" PostFxQuality="high" TextureQuality="high" TextureResolutionQuality="high" WaterQuality="high" DepthPassQuality="high" VegetationQuality="high" TerrainQuality="high" GeometryQuality="high" AmbientQuality="high" ShadowQuality="high" Hdr="1" HdrFP32="1" Bloom="1" id="customd3d10" />
    		</CustomQuality>
    	</RenderProfile>
    	<NetworkProfile CustomMapMaxUploadRateOnline="10240" OnlineEnginePort="9000" OnlineServicePort="9001" FileTransferHostPort="9002" FileTransferClientPort="9003" LanBroadcastPort="9004" ScanFreePorts="1" ScanPortRange="1000" ScanPortStart="9000" SessionProvider="" DetectPublicAddress="1" MaxUploadOnline="768">
    		<Accounts />
    	</NetworkProfile>
    	<GameProfile Sensitivity="0.9" Invert_y="0" UseMouseSmooth="0" Smoothness="1" Smoothness_Ironsight="1" HelpCrosshair="0" UseCompassMiniMap="1" UseRoadSignHilight="1" UseSubtitles="1" UseAmbx="0" Autosave="1" Machete="0" DifficultyLevel="1" ClanTag="">
    		<FireConfig QualitySetting="Low" />
    	</GameProfile>
    	<RealTreeProfile Quality="Low">
    		<CustomQuality />
    	</RealTreeProfile>
    	<EngineProfile>
    		<PhysicConfig QualitySetting="Low" />
    		<QcConfig GatherFPS="1" GatherAICnt="1" IsQcTester="0" />
    		<InputConfig />
    	</EngineProfile>
    </GamerProfile>
    """

  /// The same profile after choosing 1680 x 1050, 60 Hz, 4X, the High overall preset and High fire, real tree and physics in the game's own Video options.
  static let usedProfileXML = """
    <GamerProfile>
    	<SoundProfile MusicEnabled="1" MasterVolume="100" />
    	<RenderProfile MultiSampleMode="4" AlphaToCoverage="1" ResolutionX="1680" ResolutionY="1050" Quality="high" Fullscreen="1" Maximized="0" ForceWidescreen="0" WidescreenFOV="0" AspectRatio="0" VSync="0" RefreshRate="60" DisableMip0Loading="0" MaxDriverBufferedFrames="0" Platform="d3d9" ShowFPS="0" ClustersZPassMaxLOD="1" Brightness="1" Contrast="1" GammaRamp="1" GammaRampR="1" GammaRampG="1" GammaRampB="1" AllowAsynchShaderLoading="1">
    		<CustomQuality>
    			<quality ResolutionX="800" ResolutionY="600" EnvironmentQuality="medium" AntiPortalQuality="high" PostFxQuality="medium" TextureQuality="medium" TextureResolutionQuality="medium" WaterQuality="medium" DepthPassQuality="medium" VegetationQuality="medium" TerrainQuality="medium" GeometryQuality="medium" AmbientQuality="medium" ShadowQuality="medium" Hdr="0" HdrFP32="0" Bloom="1" id="custom" />
    			<quality ResolutionX="800" ResolutionY="600" EnvironmentQuality="high" AntiPortalQuality="high" PostFxQuality="high" TextureQuality="high" TextureResolutionQuality="high" WaterQuality="high" DepthPassQuality="high" VegetationQuality="high" TerrainQuality="high" GeometryQuality="high" AmbientQuality="high" ShadowQuality="high" Hdr="1" HdrFP32="1" Bloom="1" id="customd3d10" />
    		</CustomQuality>
    	</RenderProfile>
    	<NetworkProfile CustomMapMaxUploadRateOnline="10240" OnlineEnginePort="9000" OnlineServicePort="9001" FileTransferHostPort="9002" FileTransferClientPort="9003" LanBroadcastPort="9004" ScanFreePorts="1" ScanPortRange="1000" ScanPortStart="9000" SessionProvider="" DetectPublicAddress="1" MaxUploadOnline="768">
    		<Accounts />
    	</NetworkProfile>
    	<GameProfile Sensitivity="0.9" Invert_y="0" UseMouseSmooth="0" Smoothness="1" Smoothness_Ironsight="1" HelpCrosshair="0" UseCompassMiniMap="1" UseRoadSignHilight="1" UseSubtitles="1" UseAmbx="1" Autosave="1" Machete="0" DifficultyLevel="1" ClanTag="">
    		<FireConfig QualitySetting="High" />
    	</GameProfile>
    	<RealTreeProfile Quality="High">
    		<CustomQuality />
    	</RealTreeProfile>
    	<EngineProfile>
    		<PhysicConfig QualitySetting="High" />
    		<QcConfig GatherFPS="1" GatherAICnt="1" IsQcTester="0" />
    		<InputConfig />
    	</EngineProfile>
    </GamerProfile>
    """

  /// A prefix registry reduced to the section the starter edits.
  static let registryText = """
    WINE REGISTRY Version 2
    ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

    [Software\\\\Wine] 1759391234
    "Version"="win10"

    [Software\\\\Wine\\\\Mac Driver] 1759391234
    "RetinaMode"="Y"

    """

  let root: URL
  let paths: AppPaths
  var user: FarCry2UserData { FarCry2UserData(paths: paths) }
  var wineProfile: URL { paths.prefix.appendingPathComponent("drive_c/users/crossover") }

  init(profileName: String = "crossover", extraProfiles: [String] = []) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    paths = try AppPaths(
      bundle: root.appendingPathComponent("Far Cry 2.app"),
      support: root.appendingPathComponent("Support"), game: .farcry2)
    try buildPrefix(profileName: profileName, extraProfiles: extraProfiles)
    try FileManager.default.createDirectory(
      at: paths.saves, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: paths.currentGame.deletingLastPathComponent(), withIntermediateDirectories: true)
  }

  /// Wine 11 creates real `Documents` and `AppData/Local` folders inside the prefix.
  func buildPrefix(profileName: String = "crossover", extraProfiles: [String] = []) throws {
    let files = FileManager.default
    for name in [profileName, "Public"] + extraProfiles {
      for folder in ["Documents", "AppData/Local", "Saved Games"] {
        try files.createDirectory(
          at: paths.prefix.appendingPathComponent("drive_c/users/\(name)/\(folder)"),
          withIntermediateDirectories: true)
      }
    }
  }

  /// Installs a game generation whose `bin` can hold `mtld3d.conf`.
  func installGameFolder(renderer: String? = nil) throws {
    let game = paths.game(version: "test").appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    if let renderer {
      try Data(renderer.utf8).write(to: game.appendingPathComponent("mtld3d.conf"))
    }
    try? FileManager.default.removeItem(at: paths.data.appendingPathComponent("Current"))
    try FileManager.default.createSymbolicLink(
      atPath: paths.data.appendingPathComponent("Current").path,
      withDestinationPath: "Versions/test")
  }

  func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  func remove() {
    do { try FileManager.default.removeItem(at: root) } catch { print("Cleanup failed: \(error)") }
  }
}
