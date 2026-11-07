#!/usr/bin/env python3
"""Check opt-in PS export evidence using the AI project's existing Pillow environment."""
import json
from pathlib import Path
import sys

from PIL import Image


def read_png(path):
    path = Path(path)
    with Image.open(path) as image:
        return {
            'size': image.size,
            'rgba': image.convert('RGBA').tobytes(),
            'icc': image.info.get('icc_profile'),
            'srgb': image.info.get('srgb'),
            'gamma': image.info.get('gamma'),
            'chromaticity': image.info.get('chromaticity'),
            'orientation': image.getexif().get(274, 1),
            'bitDepth': path.read_bytes()[24],
        }


def verify(directory):
    checks = []
    for record in sorted(Path(directory).glob('*/run-*.json')):
        pair = json.loads(record.read_text())
        before, after = (read_png(pair[mode]['png']) for mode in ('legacy', 'fast'))
        differences = [key for key in before if before[key] != after[key]]
        if not after['icc']:
            differences.append('missingICC')
        if record.parent.name.startswith('soft-alpha-'):
            if after['size'] != (5, 1) or list(after['rgba'][3::4]) != [0, 1, 64, 128, 255]:
                differences.append('softAlphaOrVisibleBlue')
        checks.append({'record': str(record), 'differences': differences})
    return {'passed': bool(checks) and all(not item['differences'] for item in checks), 'checks': checks}


if __name__ == '__main__':
    result = verify(sys.argv[1])
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['passed'] else 1)
