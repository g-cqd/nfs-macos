#!/bin/zsh
# Developer launcher for Far Cry 2 (Dunia, Direct3D 9) with the private Wine runtime, mtld3d and x87sidecar.
# Mirrors Play_CoD4.command and the app's LaunchEnvironment. UNTESTED: no game install was available
# when this was written. It never modifies the game folder, and stops only its own wineserver.
# It starts G:\bin\FarCry2.exe; the app starts C:\FarCry2\bin\FarCry2.exe (the CoD4 pattern) with the same
# G: working directory. Try the other form if one fails.
#
#   FARCRY2_GAME     installed game folder (contains bin and Data_Win32)        required
#   FARCRY2_TOOLS    working folder for the prefix and logs (default ~/Games/FarCry2-tools)
#   FARCRY2_WINE     Wine runtime root (default ~/Games/CoD4-tools/wine; pinned cod4-tested profile)
#   FARCRY2_SIDECAR  x87sidecar binary (default ~/Games/CoD4-tools/x87sidecar)
#   FARCRY2_X87=0    run without the sidecar, for an A/B comparison
set -eu
GAME="${FARCRY2_GAME:?Set FARCRY2_GAME to your installed Far Cry 2 folder}"
TOOLS="${FARCRY2_TOOLS:-$HOME/Games/FarCry2-tools}"
WINE_ROOT="${FARCRY2_WINE:-$HOME/Games/CoD4-tools/wine}"
SIDECAR="${FARCRY2_SIDECAR:-$HOME/Games/CoD4-tools/x87sidecar}"
PREFIX="$TOOLS/prefix"
[[ -f "$GAME/bin/FarCry2.exe" ]] || { print "No bin/FarCry2.exe in $GAME"; exit 2 }
mkdir -p "$PREFIX" "$TOOLS/diagnostics" "$TOOLS/home"

export HOME="$TOOLS/home" WINEPREFIX="$PREFIX" WINEMSYNC=1
export WINEDLLPATH="$WINE_ROOT/lib/wine/d3d9/mtld3d"
# Direct3D 10 libraries hidden: the game supported Windows XP, and mtld3d provides Direct3D 9 only.
export WINEDLLOVERRIDES="mscoree,mshtml=;d3d10,d3d10_1,d3d10core,dxgi="
export WINE_COMPATDB=$'v=3\nname=farcry2-dev;exe=*;d3d9=mtld3d;dxgi=wined3d'
export WINEDEBUG="${WINEDEBUG:--all}"
export RUST_LOG="${RUST_LOG:-info,mtld3d::perf=off}"
export MTL_HUD_ENABLED=0
if [[ "${FARCRY2_X87:-1}" == 1 ]]; then
    export ROSETTA_X87_PATH="$SIDECAR"
else
    unset ROSETTA_X87_PATH
fi

# The prefix must exist before the game drive can be mapped.
[[ -d "$PREFIX/drive_c" ]] || "$WINE_ROOT/bin/wine" wineboot --init > "$TOOLS/diagnostics/wineboot.log" 2>&1

# A native working directory cannot be mapped through a C: link, so map the game alone as G:.
# (Without it Wine starts in C:\windows; this was the CoD4 fileSysCheck failure.)
DRIVE="$PREFIX/dosdevices/g:"
[[ -e "$DRIVE" || -L "$DRIVE" ]] && { print "$DRIVE already exists; remove it if it is stale"; exit 3 }
ln -s "$GAME" "$DRIVE"
cleanup() { rm -f "$DRIVE"; "$WINE_ROOT/bin/wineserver" -k 2>/dev/null || true }
trap cleanup EXIT

LOG="$TOOLS/diagnostics/run-$(date +%Y%m%d-%H%M%S)-x87-${FARCRY2_X87:-1}.log"
print "Writing log: $LOG"
cd "$GAME/bin"
if "$WINE_ROOT/bin/wine" 'G:\bin\FarCry2.exe' "$@" > "$LOG" 2>&1; then
    CODE=0
else
    CODE=$?
fi
print "$CODE" > "${LOG%.log}.status"
print "Far Cry 2 exited with status $CODE"
exit "$CODE"
