import Foundation

@testable import NFS2015Core

/// A session log shaped like the ones from the two Macs, built from invented text: Wine's own
/// messages, a few of the EA app's, and lines that carry credentials and must never get out.
enum CrashFixtures {
  static let secrets = [
    "A1b2C3d4E5f6G7h8I9j0K1l2M3n4", "sessionId=77", "hunter2", "eyJhbGciOiJIUzI1NiJ9.payload.sig",
    "someone@example.com", "refresh_token", "Bearer",
  ]

  static let log = """
    msync: up and running.
    compatdb: EADesktop.exe [x86_64] company="Electronic Arts" product="EA"
    info:  EALauncher authCode=A1b2C3d4E5f6G7h8I9j0K1l2M3n4 sessionId=77
    [1007/211844.212:ERROR:device_event_log_impl.cc(215)] FIDO: webauthn_api.cc:57 hunter2
    [1007/211845.000:INFO:cookie_manager_impl.cc(53)] Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig
    info:  signed in as someone@example.com with refresh_token
    compatdb: NFS16.exe [x86_64] company="Electronic Arts" product="Need for Speed"
    info:  Maximum supported feature level: D3D_FEATURE_LEVEL_11_1
    info:  Setting display mode: 3360x2100@60
    info:  Setting display mode: 1920x1200@60
    \(NFS2015FaultAnalysisTests.textPointer)
    compatdb: winedbg.exe [x86_64]
    compatdb: NFS16.exe [x86_64] company="Electronic Arts" product="Need for Speed"
    info:  Setting display mode: 3360x2100@60
    info:  Setting display mode: 1920x1200@60
    \(NFS2015FaultAnalysisTests.nullRead)
    \(NFS2015FaultAnalysisTests.textPointer)
    wineserver crashed, please enable coredumps (ulimit -c unlimited) and restart.

    """

  static let host = NFS2015HostFacts(
    model: "MacBookAir10,1", chip: "Apple M1", memoryBytes: 17_179_869_184,
    osVersion: "Version 27.2 (Build 99X1)", cpuCount: 8)

  static let load = NFS2015LoadSample(
    loadAverages: [3.5, 2.25, 1.0], swapUsed: 2_147_483_648, swapTotal: 4_294_967_296)

  static var pins: NFS2015BuildPins {
    var pins = NFS2015BuildPins()
    pins.bundleVersion = "20261003"
    pins.gameManifestVersion = "1-synthetic"
    pins.runtimeProfile = "nfs2015-tf-cx11"
    pins.sources = ["mtld3d": "7d108a4", "x87sidecar": "c396937"]
    pins.sidecarSHA256 = String(repeating: "ab12", count: 16)
    pins.runtimeTuning = [
      "WINE_TF_EMULATION": "1", "WINE_TF_MAX_NS": "0", "WINE_TF_MAX_STEPS": "0",
    ]
    pins.runtimeHashes = ["bin/wine": String(repeating: "cd34", count: 16)]
    pins.clientLayerSHA256 = String(repeating: "ef56", count: 16)
    return pins
  }

  static func context(
    display: NFS2015DisplayFacts? = NFS2015DisplaySafetyTests.macBookAir,
    experiment: NFS2015ExperimentOverrides = NFS2015ExperimentOverrides(), logging: Bool = false
  ) -> NFS2015CrashContext {
    var settings = NFS2015Settings()
    settings.values = ["render.resolution": "1920x1200", "render.fullscreen": "1"]
    return NFS2015CrashContext(
      pins: pins, host: host, display: display,
      displayPlan: NFS2015DisplaySafety.plan(
        facts: display, hasOptionsFile: true, preference: .standard),
      seed: .skipped("the game's settings folder already holds files."),
      metalFX: NFS2015MetalFXPreference(spatialUpscaling: true, factor: .x150),
      diagnostics: .standard, diagnosticLog: logging, settings: settings,
      tuning: ["WINE_TF_EMULATION": "1", "WINE_TF_MAX_NS": "0", "WINE_TF_MAX_STEPS": "0"],
      experiment: experiment)
  }

  static let now = Date(timeIntervalSince1970: 1_791_000_000)
}
