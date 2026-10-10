#!/usr/bin/env python3
"""Convert the TOML manifest to JSON on stdout (stdlib only).

Lets the bash build scripts keep using jq for everything. Needs python 3.11+
(tomllib) or the tomli backport.
"""
import json
import sys

try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        sys.exit("error: python3 with tomllib (3.11+) required, or: pip3 install tomli")

if len(sys.argv) != 2:
    sys.exit(f"usage: {sys.argv[0]} <file.toml>")

with open(sys.argv[1], "rb") as f:
    print(json.dumps(tomllib.load(f)))
