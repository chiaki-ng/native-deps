#!/usr/bin/env bash
# Pin a new version of a dependency — the PR-ready bump.
#
#   scripts/bump.sh <name> <version> [sha256]
#
# Downloads the archive from the upstream URL template in
# deps/<name>/<platform>.toml, verifies (or computes) the SHA-256 and
# rewrites the pin in place through tomlkit, preserving comments. Commit
# the result to a branch and open a PR:
#
#   scripts/bump.sh openssl 3.6.5
#   git checkout -b bump-openssl-3.6.5
#   git add deps/openssl && git commit -m "openssl 3.6.5" && gh pr create
#
# Requires python3 with tomlkit for the rewrite: pip3 install tomlkit

set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

[ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: bump.sh <name> <version> [sha256]"
name=$1
version=$2
provided_sha=${3:-}
pin=$(dep_pin "$name")
[ -f "$pin" ] || die "no pin at $pin (and '$name' must be listed in config/$PLATFORM.toml)"

url=$(resolve_url "$(dep_get "$name" '.url')" "$version" "$name")
log "downloading $url"
tmp=$(mktemp -d)
archive="$tmp/$(basename "$url")"
download "$archive" "$url" || die "download failed — check the URL template in $pin"
sha=$(hash_file "$archive")
if [ -n "$provided_sha" ] && [ "$provided_sha" != "$sha" ]; then
  die "sha256 mismatch: you passed $provided_sha but the archive hashes to $sha"
fi

python3 "$ROOT/scripts/set_pin.py" "$pin" "$version" "$sha"
rm -rf "$tmp"

log "pinned $name $version (sha256 $sha)"
log "next: commit $pin and open a pull request"
