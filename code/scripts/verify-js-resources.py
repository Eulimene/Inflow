#!/usr/bin/env python3
"""Verify pinned offline JS resources without accessing the network."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / 'macos/Inflow/Resources/JavaScript'
manifest = json.loads((root / 'dependencies.json').read_text())
for entry in manifest['files']:
    path = root / entry['file']
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
        raise SystemExit(f'JavaScript resource checksum mismatch: {path}')
print(f"Verified {len(manifest['files'])} pinned JavaScript resources and licenses.")
