#!/usr/bin/env python3
"""Compare public JSON wire structs across the agent and control plane."""
from __future__ import annotations

import re
import sys
from pathlib import Path

STRUCTS = {
    "SystemMetrics", "Heartbeat", "CertInfo", "CertReport", "OSInfo", "MySQLInfo",
    "Hello", "HelloAck", "Assign", "Result", "ResultAck",
}


def contracts(path: Path) -> dict[str, list[tuple[str, str, str]]]:
    source = path.read_text()
    result: dict[str, list[tuple[str, str, str]]] = {}
    for name in STRUCTS:
        match = re.search(rf"type\s+{name}\s+struct\s*\{{(.*?)\n\}}", source, re.S)
        if not match:
            raise SystemExit(f"{path}: missing {name}")
        fields: list[tuple[str, str, str]] = []
        for line in match.group(1).splitlines():
            field = re.match(r"\s*(\w+)\s+(.+?)\s+`json:\"([^\"]+)\"`", line)
            if field:
                fields.append((field.group(1), " ".join(field.group(2).split()), field.group(3)))
        result[name] = fields
    return result


if len(sys.argv) != 3:
    raise SystemExit("usage: wire-contract.py AGENT_WIRE WEBAPP_WIRE")

left, right = map(Path, sys.argv[1:])
left_contract, right_contract = contracts(left), contracts(right)
if left_contract != right_contract:
    for name in sorted(STRUCTS):
        if left_contract[name] != right_contract[name]:
            print(f"{name} differs:\n  agent={left_contract[name]}\n  webapp={right_contract[name]}")
    raise SystemExit(1)
print("wire contracts match")
