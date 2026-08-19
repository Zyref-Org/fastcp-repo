#!/usr/bin/env python3
"""Fail when a SPA /v1 request no longer has a registered REST operation."""
from __future__ import annotations

import re
import sys
import json
from pathlib import Path


def normalize(path: str) -> str:
    path = path.split("?", 1)[0]
    path = re.sub(r"\$\{[^}]+\}", "{}", path)
    path = re.sub(r"\{[^}]+\}", "{}", path)
    return path.rstrip("/") or "/"


if len(sys.argv) != 3:
    raise SystemExit("usage: spa-api-contract.py WEBAPP_ROOT SPA_ROOT")
_webapp, spa = map(Path, sys.argv[1:])
contract = json.loads((spa / "openapi.json").read_text())
api_paths = {normalize(value) for value in contract.get("paths", {})}

client_paths: set[str] = set()
for file in (spa / "src").rglob("*"):
    if file.suffix not in {".ts", ".vue"}:
        continue
    for value in re.findall(r'["`](\/v1\/[^"`\s]+)["`]', file.read_text()):
        client_paths.add(normalize(value))

# This endpoint intentionally sits outside Huma to preserve Stripe's raw body;
# the browser never calls it. All browser paths must be in the generated API.
missing = sorted(
    path for path in client_paths - api_paths
    if not any(candidate.startswith(path + "/") for candidate in client_paths)
)
if missing:
    print("SPA paths absent from the REST contract:")
    print("\n".join(f"  {path}" for path in missing))
    raise SystemExit(1)
print(f"SPA/API path contract passed ({len(client_paths)} browser paths)")
