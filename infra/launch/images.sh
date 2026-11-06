#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Image review sheet for an exported tree (see images.py).
#
#   infra/launch/images.sh <dir> <out.html>
#
# Pillow (thumbnails) and RapidOCR (OCR when tesseract is not installed) live in a private venv
# in the tools folder beside the repo, created with uv on first use. Nothing is installed
# system-wide. If uv is missing, it falls back to the system python3 (thumbnails need Pillow).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
[[ $# == 2 && -d "$1" ]] || { echo "Usage: images.sh <dir> <out.html>" >&2; exit 2; }
tools=${AIRC_TOOLS_DIR:-$(dirname "$ROOT")/tools}
venv=$tools/imgtools
python=python3
if [[ -x "$venv/bin/python" ]]; then
  python=$venv/bin/python
elif command -v uv >/dev/null; then
  uv venv -q -p 3.12 "$venv"
  VIRTUAL_ENV=$venv uv pip install -q 'pillow==13.0.0' 'rapidocr-onnxruntime==1.4.4'
  python=$venv/bin/python
else
  echo "note: uv not found; using system python3 (no thumbnails without Pillow)" >&2
fi
patterns=${AIRC_PRIVATE_PATTERNS:-$(dirname "$ROOT")/private-patterns.txt}
exec "$python" -I "$HERE/images.py" "$1" "$2" --patterns "$patterns" --json "${2%.html}.json"
