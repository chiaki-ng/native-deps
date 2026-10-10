#!/usr/bin/env python3
"""Set a dependency's version and sha256 pin in the TOML manifest.

Rewrites the file through tomlkit so comments and layout survive; this is
what scripts/bump.sh uses. Requires: pip3 install tomlkit
"""
import sys

try:
    import tomlkit
except ModuleNotFoundError:
    sys.exit("error: tomlkit required for bumping pins — pip3 install tomlkit")

if len(sys.argv) != 6:
    sys.exit(f"usage: {sys.argv[0]} <manifest.toml> <platform> <name> <version> <sha256>")

path, platform, name, version, sha = sys.argv[1:6]
with open(path) as f:
    doc = tomlkit.parse(f.read())

entries = doc.get(platform)
if entries is None:
    sys.exit(f"error: no [[{platform}]] entries in {path}")

for entry in entries:
    if entry.get("name") == name:
        entry["version"] = version
        entry["sha256"] = sha
        break
else:
    sys.exit(f"error: [[{platform}]] has no dep named '{name}'")

with open(path, "w") as f:
    f.write(tomlkit.dumps(doc))
