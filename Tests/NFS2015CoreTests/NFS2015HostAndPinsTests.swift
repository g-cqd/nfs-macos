import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015HostAndPinsTests {
  // MARK: Build pins

  private func bundle(_ scratch: Scratch, provenance: String?, plist: Bool = true) throws -> URL {
    let app = scratch.url("Synthetic.app")
    if let provenance {
      try scratch.write("Synthetic.app/Contents/Resources/runtime-provenance.json", provenance)
    }
    if plist {
      let data = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleVersion": "20261003"], format: .xml, options: 0)
      try FileManager.default.createDirectory(
        at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
      try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
    return app
  }

  @Test
  func `reads the pins from the files the app carries`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let app = try bundle(
      scratch,
      provenance: """
        {"runtimeProfile":"nfs2015-tf-cx11","sources":{"mtld3d":"7d108a4","x87sidecar":"c396937"},
         "inputRuntimeHashes":{"bin/wine":"aa"},"inputSidecarSHA256":"bb",
         "runtimeTuning":{"WINE_TF_EMULATION":"1"},"unrelated":{"a":[1,2]}}
        """)
    let pins = NFS2015BuildPins(bundle: app, manifest: nil)
    #expect(pins.bundleVersion == "20261003" && pins.runtimeProfile == "nfs2015-tf-cx11")
    #expect(pins.sources == ["mtld3d": "7d108a4", "x87sidecar": "c396937"])
    #expect(pins.runtimeHashes == ["bin/wine": "aa"] && pins.sidecarSHA256 == "bb")
    #expect(pins.runtimeTuning == ["WINE_TF_EMULATION": "1"])
    #expect(pins.lines.contains("runtime file bin/wine sha256 aa"))
    #expect(pins.lines.contains("sources: mtld3d=7d108a4 x87sidecar=c396937"))
  }

  @Test
  func `missing or damaged files leave the pins empty and never fail`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let none = NFS2015BuildPins(
      bundle: try bundle(scratch, provenance: nil, plist: false), manifest: nil)
    #expect(none == NFS2015BuildPins())
    #expect(none.lines.contains("app build: unknown, game manifest unknown"))
    #expect(
      none.lines.contains("sources: none recorded")
        && none.lines.contains("client layer sha256: none"))
    let damaged = NFS2015BuildPins(
      bundle: try bundle(scratch, provenance: "{not json"), manifest: nil)
    #expect(damaged.runtimeProfile == nil && damaged.bundleVersion == "20261003")
    let wrongTypes = NFS2015BuildPins(
      bundle: try bundle(scratch, provenance: #"{"sources":["a"],"runtimeProfile":3}"#),
      manifest: nil)
    #expect(wrongTypes.sources.isEmpty)
  }

  // MARK: Host

  @Test
  func `summarises the Mac without anything that names its owner`() {
    #expect(
      CrashFixtures.host.summary
        == "MacBookAir10,1, Apple M1, 16 GB, Version 27.2 (Build 99X1), 8 CPUs")
    #expect(
      NFS2015LoadSample(loadAverages: [], swapUsed: nil, swapTotal: nil).summary
        == "load average unknown, swap unknown")
  }

  @Test
  func `the system host answers with printable text and real numbers`() {
    let host = NFS2015SystemHost().host()
    for text in [host.model, host.chip, host.osVersion] {
      #expect(!text.isEmpty && text.unicodeScalars.allSatisfy { (32...126).contains($0.value) })
    }
    #expect(host.memoryBytes >= 1_073_741_824 && host.cpuCount >= 1)
    let load = NFS2015SystemHost().load()
    #expect(load.loadAverages.count == 3 && load.loadAverages.allSatisfy { $0 >= 0 })
  }

  @Test
  func `the sysctl text reader returns unknown for a name that does not exist`() {
    #expect(NFS2015SystemHost.text("not.a.real.sysctl") == "unknown")
  }
}

struct NFS2015ExperimentOverridesTests {
  @Test
  func `does nothing when the helper's environment names no experiment`() throws {
    let none = try NFS2015ExperimentOverrides(environment: ["PATH": "/usr/bin", "HOME": "/x"])
    #expect(!none.isActive && none.summary == "none")
    #expect(
      try none.applied(to: RuntimeTuning(["WINE_TF_EMULATION": "1"]))
        == RuntimeTuning(["WINE_TF_EMULATION": "1"]))
  }

  @Test
  func `turns the sidecar off and replaces only the switches it names`() throws {
    let overrides = try NFS2015ExperimentOverrides(environment: [
      "NFS2015_AB_SIDECAR": "off", "NFS2015_AB_WINE_TF_MAX_STEPS": "250000",
    ])
    #expect(overrides.isActive && overrides.sidecar == false)
    #expect(overrides.summary == "x87 sidecar off, WINE_TF_MAX_STEPS=250000")
    let applied = try overrides.applied(
      to: RuntimeTuning(["WINE_TF_EMULATION": "1", "WINE_TF_MAX_STEPS": "0", "WINE_TF_MAX_NS": "0"])
    )
    #expect(
      try applied.environment()
        == ["WINE_TF_EMULATION": "1", "WINE_TF_MAX_STEPS": "250000", "WINE_TF_MAX_NS": "0"])
  }

  @Test
  func `forces the sidecar on, which is no longer the default, and says so`() throws {
    let on = try NFS2015ExperimentOverrides(environment: ["NFS2015_AB_SIDECAR": "on"])
    #expect(on.sidecar == true && on.isActive && on.summary == "x87 sidecar on")
    let unset = try NFS2015ExperimentOverrides(environment: [:])
    #expect(unset.sidecar == nil && !unset.isActive)
  }

  @Test(arguments: [
    ["NFS2015_AB_SIDECAR": "maybe"], ["NFS2015_AB_SIDECAR": "OFF"],
    ["NFS2015_AB_WINE_TF_MAX_NS": "-1"], ["NFS2015_AB_WINE_TF_MAX_NS": "5e9"],
    ["NFS2015_AB_WINE_TF_MAX_STEPS": ""], ["NFS2015_AB_WINE_TF_MAX_STEPS": "1;2"],
    ["NFS2015_AB_WINE_TF_EMULATION": String(repeating: "9", count: 21)],
  ])
  func `refuses a value that is a typo rather than run a different experiment`(
    environment: [String: String]
  ) {
    #expect(throws: LauncherError.self) { try NFS2015ExperimentOverrides(environment: environment) }
  }

  @Test
  func `ignores names that are not experiments`() throws {
    let overrides = try NFS2015ExperimentOverrides(environment: [
      "NFS2015_AB_UNKNOWN": "1", "WINE_TF_MAX_STEPS": "5", "NFS2015_AB_WINEDEBUG": "+all",
    ])
    #expect(!overrides.isActive)
  }
}
