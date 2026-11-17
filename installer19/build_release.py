"""Build the public, self-contained installer without internal files/credentials."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
payload = {'seed.py': (ROOT / 'seed.py').read_text()}
for folder in ('demo_addons', 'runtime'):
    for p in sorted((ROOT / folder).rglob('*.py')):
        if '__pycache__' not in p.parts:
            payload[str(p.relative_to(ROOT))] = p.read_text()
core = (ROOT / 'installer.py').read_text()
needle = 'FILES = None  # Replaced by build_release.py with the exact public source payload.'
assert core.count(needle) == 1
core = core.replace(needle, 'FILES = ' + repr(payload))
release = '#!/usr/bin/env bash\n# MORHON Odoo19 fresh installer v8.1; no automatic upgrade of existing databases.\nset -euo pipefail\nexec python3 - "$@" <<\'MORHON_ODOO19_PY\'\n' + core + '\nMORHON_ODOO19_PY\n'
(ROOT / 'morhon-odoo19.sh').write_text(release)
(ROOT / 'morhon-odoo19.sh').chmod(0o755)
print(json.dumps({'file': 'morhon-odoo19.sh', 'embedded_files': sorted(payload)}))
