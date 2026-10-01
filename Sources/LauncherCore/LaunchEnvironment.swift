import Foundation

/// Creates an explicit environment without inheriting diagnostic or library injection settings.
package enum LaunchEnvironment {
  package static func make(paths: AppPaths, prefix: URL, home: URL, temporary: URL) -> [String:
    String]
  {
    var environment = [
      "HOME": home.path,
      "USER": home.lastPathComponent,
      "LOGNAME": home.lastPathComponent,
      "TMPDIR": temporary.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "en_US.UTF-8",
      "WINEPREFIX": prefix.path,
      "WINEDEBUG": "-all",
      "WINEDLLOVERRIDES": overrides(for: paths.kind),
      "ROSETTA_X87_PATH": paths.sidecar.path,
      "WINEMSYNC": "1",
      "WINE_COMPATDB": "v=3\nname=\(paths.kind.rawValue)-bundle;exe=*;d3d9=mtld3d;dxgi=wined3d",
      "MTL_HUD_ENABLED": "0",
      "RUST_LOG": "warn,mtld3d::perf=off",
    ]
    if paths.kind != .nfsmw {
      environment["WINEDLLPATH"] =
        paths.wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
          "lib/wine/d3d9/mtld3d"
        ).path
    }
    return environment
  }

  /// Far Cry 2 also ships a Direct3D 10 renderer that mtld3d does not provide. The game supported
  /// Windows XP, which has none of these libraries, so hiding them leaves only its Direct3D 9 path.
  private static func overrides(for kind: GameKind) -> String {
    switch kind {
    case .nfsmw: "dinput8=n,b;mscoree,mshtml="
    case .cod4: "mscoree,mshtml="
    case .farcry2: "mscoree,mshtml=;d3d10,d3d10_1,d3d10core,dxgi="
    }
  }
}
