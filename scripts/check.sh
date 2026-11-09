#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

python3 - <<'PY'
import os
import plistlib
import re
from pathlib import Path

with Path('Resources/Info.plist').open('rb') as file:
    info = plistlib.load(file)
version = info['CFBundleShortVersionString']
build = info['CFBundleVersion']
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
    raise SystemExit('App version must use MAJOR.MINOR.PATCH.')
if not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Build number must be a positive integer.')
if not re.search(r'^## \[' + re.escape(version) + r'\] - \d{4}-\d{2}-\d{2}$', Path('CHANGELOG.md').read_text(), re.MULTILINE):
    raise SystemExit('App version is missing from CHANGELOG.md.')
if os.environ.get('GITHUB_REF_TYPE') == 'tag' and os.environ.get('GITHUB_REF_NAME') != 'v' + version:
    raise SystemExit('Release tag does not match the app version.')
print(f'Version {version}, build {build}: OK', flush=True)
PY

git diff --check
swift run NewlineChecks
swift run Newline --check
swift run Newline --lifecycle-check
./scripts/build-app.sh
