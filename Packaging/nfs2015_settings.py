"""What the Need for Speed (2015) settings page may reach, and the only way it may write.

The page edits the game's plain-text options file and nothing else. The binary blob beside it holds
choices the game may sync with the player's EA account, and cheats, trainers, memory patches and
launch flags are out of scope, so each of those is refused here as a property of the source rather
than left to review.
"""
from pathlib import Path
import re

# Every option key the catalog may name: the keys the installed game wrote in its text file, in the
# three plain families. Adding a key means adding it here too, which is the review.
ALLOWED_KEYS = frozenset({
    'GstRender.ResolutionWidth', 'GstRender.ResolutionHeight', 'GstRender.FullscreenEnabled',
    'GstRender.FullscreenRefreshRate', 'GstRender.VSyncEnabled', 'GstRender.PresentInterval',
    'GstRender.TextureQuality', 'GstRender.MeshQuality', 'GstRender.ShadowQuality',
    'GstRender.EffectsQuality', 'GstRender.TerrainQuality', 'GstRender.UndergrowthQuality',
    'GstRender.MotionBlurEnabled', 'GstRender.FilmGrain', 'GstRender.Brightness',
    'GstRender.AntiAliasingPost', 'GstRender.AmbientOcclusion', 'GstRender.ScreenSafeAreaWidth',
    'GstRender.ScreenSafeAreaHeight',
    'GstInput.DeadZonePadSteering', 'GstInput.DeadZonePadThrottle', 'GstInput.DeadZonePadBrake',
    'GstInput.SensitivityPadSteering', 'GstInput.SensitivityPadThrottle',
    'GstInput.SensitivityPadBrake', 'GstInput.Vibration', 'GstInput.AutoReverseForManualGears',
    'GstAudio.MusicVolume', 'GstAudio.SoundEffectVolume', 'GstAudio.SpeechVolume',
    'GstAudio.DisplaySubtitles', 'GstAudio.CopVoice', 'GstAudio.PursuitMusic',
})
FAMILIES = ('GstRender.', 'GstInput.', 'GstAudio.')
FORBIDDEN_KEY_WORDS = ('fov', 'fieldofview', 'cheat', 'trainer', 'telemetry', 'speedometer', 'minimap',
                       'camera', 'playalone', 'multiplayer', 'fbchunks', 'profileoptions', 'keybinding')

TARGETS = ('NFS2015Core', 'NFS2015Launcher', 'NFS2015Session')
# The only files that may build a PlayerFileEdit or name the options file's location: the store
# that validates and writes it, and the session that replays an interrupted edit before anything reads.
WRITERS = {'NFS2015SettingsStore.swift', 'NFS2015Session.swift', 'PlayerFileEdit.swift'}
OPTIONS_PATH_USERS = {'NFS2015SettingsStore.swift'}

FORBIDDEN_CODE = [
    (re.compile(r'FBCHUNKS', re.I), 'names the binary options blob format'),
    (re.compile(r'PROFILEOPTIONS(?!_profile)'), 'names the binary PROFILEOPTIONS blob'),
    (re.compile(r'["\']-(?:Render|GameTime)\.'), 'passes a command-line flag to the game'),
    (re.compile(r'\b(?:WriteProcessMemory|ReadProcessMemory|task_for_pid|vm_write|ptrace)\b'),
     'reads or writes another process\'s memory'),
    (re.compile(r'\b(?:trainer|cheat)s?\b', re.I), 'is a trainer or cheat'),
]


def strip_comments(source):
    """The code of a Swift file with `//` comments removed; string contents are kept."""
    lines = []
    for line in source.splitlines():
        out, quoted, escaped = [], False, False
        for index, char in enumerate(line):
            if quoted:
                out.append(char)
                if escaped:
                    escaped = False
                elif char == '\\':
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
                out.append(char)
            elif char == '/' and line[index:index + 2] == '//':
                break
            else:
                out.append(char)
        lines.append(''.join(out))
    return '\n'.join(lines)


def catalog_keys(source):
    """The option keys a catalog file names, from every `keys: [...]` argument."""
    keys = []
    for group in re.findall(r'keys:\s*\[([^\]]*)\]', strip_comments(source)):
        keys += re.findall(r'"([^"]*)"', group)
    return keys


def key_problems(keys):
    problems = []
    for key in keys:
        if not key.startswith(FAMILIES):
            problems.append(f'catalog key {key} is outside the three plain option families')
        if any(word in key.lower() for word in FORBIDDEN_KEY_WORDS):
            problems.append(f'catalog key {key} names something the page must not reach')
        elif key not in ALLOWED_KEYS:
            problems.append(f'catalog key {key} is not in the reviewed list of safe keys')
    if len(set(keys)) != len(keys):
        problems.append('a catalog key is named twice')
    return problems


def source_problems(files):
    """Problems in `{name: source}` for the NFS2015 targets."""
    problems = []
    for name, source in sorted(files.items()):
        code = strip_comments(source)
        for pattern, reason in FORBIDDEN_CODE:
            for match in pattern.finditer(code):
                problems.append(f'{name} {reason}: {match.group(0)}')
        if 'PlayerFileEdit(' in code and name not in WRITERS:
            problems.append(f'{name} writes the options file outside the store')
        if 'optionsPath' in code and name not in OPTIONS_PATH_USERS:
            problems.append(f'{name} names the options file\'s location outside the store')
    return problems


def tree_problems(root):
    """Problems in a checkout: its catalog keys, and every NFS2015 source file."""
    root = Path(root)
    files = {}
    for target in TARGETS:
        for path in sorted((root / 'Sources' / target).glob('*.swift')):
            files[path.name] = path.read_text()
    catalogs = [source for name, source in files.items() if name.startswith('NFS2015Catalog')]
    keys = [key for source in catalogs for key in catalog_keys(source)]
    problems = key_problems(keys) if keys else ['no catalog keys were found']
    return problems + source_problems(files)
