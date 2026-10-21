#!/usr/bin/env python3
"""Set a dependency pin's version and sha256 in its TOML file.

Rewrites the file through tomlkit so comments and layout survive; this is
what scripts/bump.sh uses. Requires: pip3 install tomlkit
"""
import sys

try:
    import tomlkit
except ModuleNotFoundError:
    sys.exit("error: tomlkit required for bumping pins — pip3 install tomlkit")

if len(sys.argv) < 3 or not all("=" in a for a in sys.argv[2:]):
    sys.exit(f"usage: {sys.argv[0]} <deps/<name>/<platform>.toml> <key>=<value>...")

path = sys.argv[1]
with open(path) as f:
    doc = tomlkit.parse(f.read())

for assignment in sys.argv[2:]:
    key, value = assignment.split("=", 1)
    doc[key] = value

with open(path, "w") as f:
    f.write(tomlkit.dumps(doc))
