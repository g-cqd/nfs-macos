#!/bin/zsh
set -eu
LAB_DIR=${0:A:h}
EA_EXE='C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EALauncher.exe'
if [[ ! -d "$LAB_DIR/Prefix/drive_c/Program Files/Electronic Arts/EA Desktop" ]]; then
    print -u2 'EA app is not installed in this isolated environment.'
    exit 1
fi
export WINEPREFIX="$LAB_DIR/Prefix"
export WINEDEBUG=-all
export WINEDLLOVERRIDES='winemenubuilder.exe=d'
export WINE_COMPATDB=$'v=3\nname=ea-ui;exe=EADesktop.exe;company=Electronic Arts;arguments=--in-process-gpu'
mkdir -p "$LAB_DIR/Logs"
cd "$LAB_DIR"
exec "$LAB_DIR/Wine/bin/wine" "$EA_EXE" > "$LAB_DIR/Logs/ea-launch.log" 2>&1
