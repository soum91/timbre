#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p public/debs
cp Tweak/packages/*.deb public/debs/
cd public
# dpkg-scanpackages is bundled with dpkg on the CI runner.
dpkg-scanpackages --multiversion debs /dev/null > Packages
gzip -9c Packages > Packages.gz
python3 - <<'PY2'
from pathlib import Path
import hashlib,datetime
files=['Packages','Packages.gz']
lines=['Origin: Timbre','Label: Timbre Rootless','Suite: stable','Codename: ios','Version: 1.0','Architectures: iphoneos-arm64','Components: main','Description: Experimental Timbre packages for Dopamine rootless','Date: '+datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000'),'SHA256:']
for name in files:
 p=Path(name);lines.append(' '+hashlib.sha256(p.read_bytes()).hexdigest()+' '+str(p.stat().st_size)+' '+name)
Path('Release').write_text('\n'.join(lines)+'\n')
PY2
cat > index.html <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Timbre repo</title></head><body><h1>Timbre experimental rootless repo</h1><p>Add this page's URL to Sileo's Sources.</p><p>Experimental audio tweak. System-wide processing has not been verified on device. Do not assume stability.</p></body></html>
HTML
