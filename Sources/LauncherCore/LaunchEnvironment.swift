import Foundation

/// Creates an explicit environment without inheriting diagnostic or library injection settings.
package enum LaunchEnvironment {
  /// The DLL override list each game needs, and nothing more.
  ///
  /// Need for Speed (2015) is launched by EA's client, whose 32-bit in-game overlay faults in
  /// wined3d, so `IGOProxy32.exe` is disabled. `winemenubuilder.exe` is disabled as well so the
  /// client cannot write menu entries into the player's host session.
  static func overrides(_ kind: GameKind) -> String {
    switch kind {
    case .nfsmw: "dinput8=n,b;mscoree,mshtml="
    case .cod4: "mscoree,mshtml="
    case .nfs2015: "IGOProxy32.exe=d;winemenubuilder.exe=d;mscoree,mshtml="
    }
  }

  /// The renderer selection rules for this game's runtime.
  ///
  /// Most Wanted and Call of Duty 4 are Direct3D 9 titles served by mtld3d, and their rule is
  /// fixed here. A recipe may instead declare its own selections, which is how a Direct3D 11
  /// title picks a DXGI backend that implements what its engine needs, and how one runtime can
  /// serve a store client and its game differently.
  static func compatibilityRules(_ kind: GameKind, renderers: [RendererSelection])
    throws(LauncherError) -> String
  {
    guard !renderers.isEmpty else {
      return "v=3\nname=\(kind.rawValue)-bundle;exe=*;d3d9=mtld3d;dxgi=wined3d"
    }
    return try RendererSelection.compatibilityDatabase(renderers, kind: kind)
  }

  package static func make(
    paths: AppPaths, prefix: URL, home: URL, temporary: URL,
    tuning: RuntimeTuning = RuntimeTuning(), renderers: [RendererSelection] = []
  ) throws(LauncherError) -> [String: String] {
    var environment = [
      "HOME": home.path,
      "USER": home.lastPathComponent,
      "LOGNAME": home.lastPathComponent,
      "TMPDIR": temporary.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "en_US.UTF-8",
      "WINEPREFIX": prefix.path,
      "WINEDEBUG": "-all",
      "WINEDLLOVERRIDES": overrides(paths.kind),
      "ROSETTA_X87_PATH": paths.sidecar.path,
      "WINEMSYNC": "1",
      "WINE_COMPATDB": try compatibilityRules(paths.kind, renderers: renderers),
      "MTL_HUD_ENABLED": "0",
      "RUST_LOG": "warn,mtld3d::perf=off",
    ]
    if paths.kind == .cod4 {
      environment["WINEDLLPATH"] =
        paths.wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
          "lib/wine/d3d9/mtld3d"
        ).path
    }
    for (name, value) in try tuning.environment() { environment[name] = value }
    return environment
  }
}
