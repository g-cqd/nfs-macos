"""The Need for Speed (2015) settings page cannot reach the binary options blob or anything unsafe.

The real source tree is scanned, then the scanner is proven against synthetic hazards so that a
gate that quietly stopped matching would fail here rather than pass for ever. No game data is read.
"""
from pathlib import Path

from nfs2015_settings import (ALLOWED_KEYS, catalog_keys, key_problems, source_problems,
                              strip_comments, tree_problems)

ROOT = Path(__file__).resolve().parent.parent

# 1. The real tree is clean, and the scan sees the whole catalog.
assert tree_problems(ROOT) == [], tree_problems(ROOT)
found = {key for path in (ROOT / 'Sources/NFS2015Core').glob('NFS2015Catalog*.swift')
         for key in catalog_keys(path.read_text())}
assert found == ALLOWED_KEYS, (sorted(found ^ ALLOWED_KEYS))

# The documentation lists every key the catalog can write, so a new key cannot be added unannounced.
documentation = (ROOT / 'docs/NFS2015.md').read_text()
assert not [key for key in sorted(ALLOWED_KEYS) if f'`{key}`' not in documentation], 'Document every catalog key'

# 2. Comments are ignored and string contents are not.
assert strip_comments('let a = 1 // FBCHUNKS\n/// PROFILEOPTIONS\nlet b = "x // y"') == 'let a = 1 \n\nlet b = "x // y"'
assert catalog_keys('// keys: ["GstRender.Nothing"]\nkeys: ["GstRender.VSyncEnabled"]') == ['GstRender.VSyncEnabled']

# 3. Each kind of hazard in a catalog is reported, and a clean one is not.
assert key_problems(['GstRender.VSyncEnabled', 'GstInput.Vibration']) == []
for key in ['GstKeyBinding.default.ConceptActivate.0.axis', 'FBCHUNKS.Speedometer', 'GstRender.Fov',
            'GstRender.FieldOfView', 'GstRender.NewThing', 'GstGameplay.Telemetry', 'Other.Key',
            'GstRender.PlayAlone', 'GstRender.CameraShake']:
    assert key_problems([key]), key
assert key_problems(['GstRender.VSyncEnabled', 'GstRender.VSyncEnabled']) == ['a catalog key is named twice']
# Each rule is checked on its own, so removing one is not hidden by the others.
assert any('outside the three plain' in text for text in key_problems(['GstKeyBinding.default.A.0.axis']))
assert any('outside the three plain' in text for text in key_problems(['Other.Key']))
assert any('must not reach' in text for text in key_problems(['GstRender.FieldOfView']))
assert any('must not reach' in text for text in key_problems(['GstInput.PlayAloneChoice']))
assert any('reviewed list' in text for text in key_problems(['GstRender.NewThing']))

# 4. Each kind of hazard in the source is reported.
clean = {'NFS2015SettingsStore.swift': 'let url = optionsPath\nlet edit = PlayerFileEdit(support: s)\n',
         'NFS2015Model.swift': '// the PROFILEOPTIONS blob is never touched\nlet x = 1\n',
         'NFS2015Setting.swift': '/// cheats and trainers are not offered\nlet y = "PROFILEOPTIONS_profile"\n'}
assert source_problems(clean) == []
hazards = {
    'reads the blob': 'let blob = "PROFILEOPTIONS"',
    'names the format': 'let magic = "FBCHUNKS"',
    'passes a flag': 'let flag = "-Render.ResolutionScale"',
    'another frame rate flag': 'let flag = "-GameTime.MaxVariableFps"',
    'touches memory': 'WriteProcessMemory(handle, address)',
    'a trainer': 'let name = "Trainer"',
    'a second writer': 'let edit = PlayerFileEdit(support: s)',
    'a second location': 'let p = NFS2015SettingsStore.optionsPath + "2"',
}
for name, line in hazards.items():
    assert source_problems({'NFS2015Other.swift': line + '\n'}), name
print('NFS2015 settings reach regressions passed')
