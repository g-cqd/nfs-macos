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
      "WINEDLLOVERRIDES": paths.kind == .nfsmw ? "dinput8=n,b;mscoree,mshtml=" : "mscoree,mshtml=",
      "ROSETTA_X87_PATH": paths.sidecar.path,
      "WINEMSYNC": "1",
      "WINE_COMPATDB": "v=3\nname=\(paths.kind.rawValue)-bundle;exe=*;d3d9=mtld3d;dxgi=wined3d",
      "MTL_HUD_ENABLED": "0",
      "RUST_LOG": "warn,mtld3d::perf=off",
    ]
    if paths.kind == .cod4 {
      environment["WINEDLLPATH"] =
        paths.wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
          "lib/wine/d3d9/mtld3d"
        ).path
    }
    return environment
  }
}
