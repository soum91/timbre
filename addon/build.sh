#!/usr/bin/env bash
# Builds the Firefox add-on: copies the shared engine in and zips an .xpi.
# Usage: addon/build.sh [version]   (from the repo root)
set -euo pipefail
VERSION=${1:-$(python3 -c "import json;print(json.load(open('addon/manifest.json'))['version'])")}
OUT=${OUT:-dist}
rm -rf "$OUT/addon" && mkdir -p "$OUT/addon"
cp -R addon/manifest.json addon/*.js addon/icons addon/popup "$OUT/addon/"
rm -f "$OUT/addon/build.sh"
cp Timbre/Engine/engine.js "$OUT/addon/engine.js"
python3 - "$OUT/addon/manifest.json" "$VERSION" <<'PY'
import json, sys
p, v = sys.argv[1], sys.argv[2]
m = json.load(open(p)); m["version"] = v
json.dump(m, open(p, "w"), indent=2)
PY
(cd "$OUT/addon" && zip -qr -X "../Timbre-EQ-$VERSION.xpi" .)
echo "$OUT/Timbre-EQ-$VERSION.xpi"
