"""The Need for Speed (2015) MetalFX settings can emit only options DXMT documents, and only for the game.

The real source tree is scanned, then the scanner is proven against synthetic hazards so that a gate
that quietly stopped matching would fail here rather than pass for ever. No game data is read.
"""
from pathlib import Path

from nfs2015_metalfx import (DOCUMENTED_OPTIONS, DOCUMENTED_VARIABLES, OWNER, documentation_problems,
                             factor_problems, source_problems, strip_comments, tree_problems)

ROOT = Path(__file__).resolve().parent.parent

# 1. The real tree is clean, and the scan sees the file that owns the names.
assert tree_problems(ROOT) == [], tree_problems(ROOT)
owner = (ROOT / 'Sources/NFS2015Core' / OWNER).read_text()
for name in DOCUMENTED_VARIABLES | DOCUMENTED_OPTIONS:
    assert f'"{name}"' in strip_comments(owner), name
assert DOCUMENTED_VARIABLES == {'DXMT_METALFX_SPATIAL_SWAPCHAIN', 'DXMT_CONFIG'}
assert DOCUMENTED_OPTIONS == {'d3d11.metalSpatialUpscaleFactor'}

# The documentation says what is exposed and why the rest is not.
documentation = (ROOT / 'docs/NFS2015.md').read_text()
assert documentation_problems(documentation) == [], documentation_problems(documentation)
assert len(documentation_problems('')) == 5

# 2. A clean tree of synthetic files is accepted, comments included.
clean = {
    OWNER: '''
        // DXMT_ENABLE_NVEXT is not used, nor is MTLFXTemporalScaler
        static let a = "DXMT_METALFX_SPATIAL_SWAPCHAIN"
        static let b = "DXMT_CONFIG"
        static let c = "d3d11.metalSpatialUpscaleFactor"
        case x125 = "1.25"
        case x200 = "2.0"
    ''',
    'NFS2015MetalFXView.swift': '// DXMT_CONFIG is described here\nlet title = "MetalFX"\n',
}
assert source_problems(clean, 'let environment = ["WINEDEBUG": "-all"]') == []

# 3. Each hazard is reported, each on its own so that removing one rule is not hidden by another.
def problems(**added):
    return source_problems({**clean, **added})

hazards = {
    'another DXMT variable': ('NFS2015Other.swift', 'let v = "DXMT_ENABLE_NVEXT"', 'not part of this feature'),
    'the shader cache': ('NFS2015Other.swift', 'let v = "DXMT_SHADER_CACHE"', 'not part of this feature'),
    'the log path': ('NFS2015Other.swift', 'let v = "DXMT_LOG_PATH"', 'not part of this feature'),
    'a documented variable elsewhere': ('NFS2015Other.swift', 'let v = "DXMT_CONFIG"', 'outside'),
    'the switch elsewhere': ('NFS2015Other.swift', 'let v = "DXMT_METALFX_SPATIAL_SWAPCHAIN"', 'outside'),
    'another option': ('NFS2015Other.swift', 'let o = "d3d11.preferredMaxFrameRate"', 'not part of this feature'),
    'a shader option': ('NFS2015Other.swift', 'let o = "dxmt.shaderMetalVersion"', 'not part of this feature'),
    'a dxgi option': ('NFS2015Other.swift', 'let o = "dxgi.customVendorId"', 'not part of this feature'),
    'the option elsewhere': ('NFS2015Other.swift', 'let o = "d3d11.metalSpatialUpscaleFactor"', 'outside'),
    'the NVIDIA extension': ('NFS2015Other.swift', 'let n = "nvngx.dll"', 'NVIDIA'),
    'a temporal scaler': ('NFS2015Other.swift', 'let t = TemporalScaler()', 'cannot give'),
    'frame generation': ('NFS2015Other.swift', 'let f = "FrameGeneration"', 'cannot give'),
    'a denoiser': ('NFS2015Other.swift', 'let d = "MetalFX denoise"', 'cannot give'),
    'MetalFX called directly': ('NFS2015Other.swift', 'import MetalFX', 'directly'),
}
for name, (file, line, reason) in hazards.items():
    found = problems(**{file: line + '\n'})
    assert any(reason in text for text in found), (name, found)

# The names are matched even when written in a longer string.
assert any('not part of this feature' in text
           for text in problems(**{'NFS2015Other.swift': 'let s = "export DXMT_LOG_LEVEL=debug"'}))

# 4. The global launch environment must not carry a DXMT setting.
for line in ['"DXMT_METALFX_SPATIAL_SWAPCHAIN": "1"', '"DXMT_CONFIG": "x"', '"d3d11.metalSpatialUpscaleFactor"']:
    assert any('launch environment' in text for text in source_problems(clean, line)), line
assert source_problems(clean, '// DXMT_CONFIG is applied per program instead') == []

# 5. The factors are checked: a value DXMT cannot read or does not document is refused.
assert factor_problems('case x125 = "1.25"\ncase x200 = "2.0"') == []
for bad in ['"1.0"', '"0.5"', '"2.5"', '"3"', '"1,5"', '"1.5x"', '"-1.5"', '"1.5;d3d11.other=1"', '""', '"nan"']:
    found = factor_problems(f'case x1 = {bad}')
    assert found and 'no scale factors' not in found[0], (bad, found)
assert factor_problems('case x1 = "1.5"\ncase x2 = "1.5"') == ['a factor is offered twice']
assert factor_problems('let nothing = 1') == ['no scale factors were found']

# 6. The owner must keep emitting what the reviewed list says, and must exist.
assert any('stale' in text for text in source_problems({OWNER: 'case x150 = "1.5"'}))
assert source_problems({}) == [f'{OWNER} was not found']
print('NFS2015 MetalFX option regressions passed')
