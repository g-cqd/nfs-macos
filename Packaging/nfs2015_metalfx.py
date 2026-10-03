"""What the Need for Speed (2015) MetalFX settings may hand to DXMT.

The MetalFX group turns the player's choice into environment variables for the game's executable.
Those variables are read by DXMT, a third-party layer, so a variable or option DXMT does not
document, or a feature it cannot give this game, must never be emitted by a later edit. This module
holds the reviewed list and the scanner; adding a name means adding it here, which is the review.

Source of the list: DXMT v0.80 `docs/CUSTOMIZATION.md` and `dxmt.conf` (MetalFX spatial upscaling),
checked against the strings of the shipped `d3d11.dll`. DXMT also reads variables that are not part
of this feature (the NVIDIA extension switch, the shader cache, logging, frame capture) and options
for other purposes (frame rate, shader version); none of them is emitted here.
"""
from pathlib import Path
import re

# The environment variable that switches the spatial upscaler on, and the one that carries
# `dxmt.conf` syntax into the process. Both are documented by DXMT.
DOCUMENTED_VARIABLES = frozenset({'DXMT_METALFX_SPATIAL_SWAPCHAIN', 'DXMT_CONFIG'})
# The only configuration option written into DXMT_CONFIG.
DOCUMENTED_OPTIONS = frozenset({'d3d11.metalSpatialUpscaleFactor'})
# DXMT documents 1.0 to 2.0 for the factor; 1.0 itself does nothing, so the offered ones are above it.
FACTOR_LOW, FACTOR_HIGH = 1.0, 2.0

# The one file that may name a DXMT variable or option.
OWNER = 'NFS2015MetalFX.swift'
TARGETS = ('NFS2015Core', 'NFS2015Launcher', 'NFS2015Session')
# The launch environment is global to every Windows process of the prefix; it must never carry DXMT.
GLOBAL_ENVIRONMENT = Path('Sources/LauncherCore/LaunchEnvironment.swift')

FORBIDDEN_CODE = [
    (re.compile(r'NVEXT|nvngx|nvapi', re.I), 'reaches the NVIDIA extension, which only a DLSS caller can use'),
    (re.compile(r'Temporal(?:Scaler|Upscal)|FrameInterpol|FrameGen|Denois', re.I),
     'offers a MetalFX feature DXMT cannot give this game'),
    (re.compile(r'MTLFX|MetalFX\.framework|import\s+MetalFX'), 'calls MetalFX directly instead of through DXMT'),
]
VARIABLE = re.compile(r'DXMT_[A-Za-z0-9_]*')
OPTION = re.compile(r'\b(?:d3d11|dxgi|dxmt)\.[A-Za-z0-9_]+')
FACTOR_CASE = re.compile(r'case\s+x\w+\s*=\s*"([^"]*)"')


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


def factor_problems(source):
    """Problems with the factor values an `NFS2015MetalFX.swift` offers."""
    values = FACTOR_CASE.findall(strip_comments(source))
    if not values:
        return ['no scale factors were found']
    problems = []
    for text in values:
        if not re.fullmatch(r'[0-9]+\.[0-9]+', text):
            problems.append(f'factor {text!r} is not a plain decimal that DXMT can read')
        elif not FACTOR_LOW < float(text) <= FACTOR_HIGH:
            problems.append(f'factor {text} is outside what DXMT documents (above 1.0, up to 2.0)')
    if len(set(values)) != len(values):
        problems.append('a factor is offered twice')
    return problems


def source_problems(files, global_environment=''):
    """Problems in `{name: source}` for the NFS2015 targets, and in the global launch environment."""
    problems = []
    for name, source in sorted(files.items()):
        code = strip_comments(source)
        for pattern, reason in FORBIDDEN_CODE:
            for match in pattern.finditer(code):
                problems.append(f'{name} {reason}: {match.group(0)}')
        for match in VARIABLE.finditer(code):
            if match.group(0) not in DOCUMENTED_VARIABLES:
                problems.append(f'{name} names a DXMT variable that is not part of this feature: {match.group(0)}')
            elif name != OWNER:
                problems.append(f'{name} names a DXMT variable outside {OWNER}: {match.group(0)}')
        for match in OPTION.finditer(code):
            if match.group(0) not in DOCUMENTED_OPTIONS:
                problems.append(f'{name} names a DXMT option that is not part of this feature: {match.group(0)}')
            elif name != OWNER:
                problems.append(f'{name} names a DXMT option outside {OWNER}: {match.group(0)}')
    if OWNER in files:
        problems += [f'{OWNER}: {text}' for text in factor_problems(files[OWNER])]
        code = strip_comments(files[OWNER])
        for needed in sorted(DOCUMENTED_VARIABLES | DOCUMENTED_OPTIONS):
            if f'"{needed}"' not in code:
                problems.append(f'{OWNER} no longer emits {needed}, so the reviewed list is stale')
    else:
        problems.append(f'{OWNER} was not found')
    if VARIABLE.search(strip_comments(global_environment)) or OPTION.search(strip_comments(global_environment)):
        problems.append('the launch environment, which every Windows process inherits, names a DXMT setting')
    return problems


def documentation_problems(text):
    """Problems in the documentation of the feature."""
    problems = []
    for needed in sorted(DOCUMENTED_VARIABLES | DOCUMENTED_OPTIONS):
        if f'`{needed}`' not in text:
            problems.append(f'docs/NFS2015.md does not document {needed}')
    for words in ('temporal upscaling', 'frame generation'):
        if words not in text.lower():
            problems.append(f'docs/NFS2015.md does not say why {words} is not offered')
    return problems


def tree_problems(root):
    """Problems in a checkout."""
    root = Path(root)
    files = {}
    for target in TARGETS:
        for path in sorted((root / 'Sources' / target).glob('*.swift')):
            files[path.name] = path.read_text()
    environment = root / GLOBAL_ENVIRONMENT
    return source_problems(files, environment.read_text() if environment.exists() else '')
