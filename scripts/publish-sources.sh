#!/usr/bin/env bash
# Construct the `sources` release: download every pinned archive from its
# upstream URL, verify the pinned SHA-256, and upload the verified files to
# the rolling `sources` release so consumers have a stable mirror.
#
#   scripts/publish-sources.sh <dir>   (needs gh, GH_TOKEN set)

set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

[ $# -eq 1 ] || die "usage: publish-sources.sh <dir>"
dir=$1
mkdir -p "$dir"

need gh "https://cli.github.com/"
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set"

archives=""
for name in $(all_dep_names); do
  archives="$archives $(fetch_source "$name" "$dir")"
done

log "creating sources release if missing"
gh release view sources >/dev/null 2>&1 \
  || gh release create sources --title "Pinned dependency sources" \
    --notes "Source archives pinned by the manifest in the main branch. Every file is verified against the SHA-256 pinned in deps/ before upload."

# shellcheck disable=SC2086
gh release upload sources $archives --clobber
log "sources release updated: $archives"
