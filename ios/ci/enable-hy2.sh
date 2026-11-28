#!/usr/bin/env bash
# Adds the Hy2bridge framework to the Xcode project spec, but only if the core was built successfully.
set -euo pipefail
cd "$(dirname "$0")/.."
FW=Frameworks/Hy2bridge.xcframework
if [ ! -d "$FW" ]; then echo "::warning title=Hysteria2::core was NOT built, the app is built without it"; echo "Hysteria2 core not built: building the app without it"; exit 0; fi
BIN=$(ls "$FW"/ios-arm64/Hy2bridge.framework/Hy2bridge 2>/dev/null | head -1)
if file "$BIN" | grep -q "ar archive"; then EMBED=false; else EMBED=true; fi   # static archive -> link only; dynamic -> must be embedded
echo "Hy2bridge: embed=$EMBED ($(file "$BIN" | cut -d: -f2 | cut -c1-60))"
python3 - "$EMBED" <<'PY'
import sys
embed = sys.argv[1]
s = open('project.yml').read()
marker = "    sources: [LunoX]\n"
block = marker + "    dependencies:\n      - framework: Frameworks/Hy2bridge.xcframework\n        embed: %s\n      - sdk: libresolv.tbd\n" % embed
if "Hy2bridge" not in s:
    assert marker in s
    s = s.replace(marker, block, 1)
    open('project.yml', 'w').write(s)
print("project.yml patched")
PY
