#!/bin/bash
# Builds Voilà.app (menu bar app + "Restore French Accents" service).
# With --install, copies it to ~/Applications and refreshes the Services menu.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product VoilaMenu
bin_dir=$(swift build -c release --show-bin-path)

app="build/Voilà.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp App/Info.plist "$app/Contents/"
cp "$bin_dir/VoilaMenu" "$app/Contents/MacOS/Voila"
cp Sources/Voila/Resources/fr_50k.txt "$app/Contents/Resources/"
# A real identity keeps the code signature stable across rebuilds, so the
# Accessibility permission the hotkey needs survives them; ad-hoc doesn't.
identity=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${identity:--}" "$app"
echo "Built $app (signed: ${identity:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    dest="$HOME/Applications/Voilà.app"
    mkdir -p "$HOME/Applications"
    pkill -x Voila || true
    rm -rf "$dest"
    cp -R "$app" "$dest"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
    /System/Library/CoreServices/pbs -update
    open "$dest"
    echo "Installed and launched $dest"
fi
