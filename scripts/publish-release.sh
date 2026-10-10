#!/usr/bin/env bash
# Publishes into the release that triggered this build ($RELEASE_TAG, set
# by the workflow to the release's tag):
#   - the downloaded, SHA-verified upstream source archive per pinned dep
#   - one build.tar.gz with every compiled dependency (a directory per
#     library, plus an internal SHA256SUMS covering every library file)
#   - build.tar.gz.sha256 (checksum of the tarball) and build.json
# The release's notes are replaced with the generated description (its
# title stays whatever its author set). Sources are always downloaded
# from the pinned upstream URLs — nothing is ever fetched from this
# repository's own releases.
#
#   scripts/publish-release.sh <dist-dir> <srcs-dir> <pool-dir>
#   (needs gh with GH_TOKEN and RELEASE_TAG set; the pool is used for the
#   description table)

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[ $# -eq 3 ] || die "usage: publish-release.sh <dist-dir> <srcs-dir> <pool-dir>"
DISTDIR=$(cd "$1" && pwd)
SRCSDIR=$2
POOLDIR=$3
mkdir -p "$SRCSDIR"
shopt -s nullglob

need gh "https://cli.github.com/"
need jq "brew install jq"
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set"
[ -n "${RELEASE_TAG:-}" ] || die "RELEASE_TAG must be set to the tag of the release being published"

# --- verified source archives (downloaded from the pinned upstream URLs) ---
archives=""
for name in $(all_dep_names); do
  archives="$archives $(fetch_source "$name" "$SRCSDIR")"
done

# --- the build archive and its checksum sidecar ---
build_tarball="$DISTDIR/build.tar.gz"
[ -f "$build_tarball" ] || die "build.tar.gz not found in '$DISTDIR' — did assemble run?"
printf '%s  %s\n' "$(hash_file "$build_tarball")" "build.tar.gz" >"$DISTDIR/build.tar.gz.sha256"

# --- description table: library, compiled version, sha256 sums ---
# The table cell stays compact (file names, or a count for many-library
# deps like abseil); the full per-file checksums go into collapsible
# <details> blocks below the table, which GitHub renders.
rows=""
details=""
for d in "$POOLDIR"/*/; do
  info="$d/BUILD-INFO"
  [ -f "$info" ] || continue
  name=$(jq -r '.name' "$info")
  version=$(jq -r '.version' "$info")
  arch=$(jq -r '.arch' "$info")
  src_sha=$(jq -r '.sha256' "$info")
  src_file=$(basename "$(resolve_url "$(dep_get "$name" '.url')" "$version" "$name")")
  names=""
  sums=""
  nlibs=0
  for a in "$d"/lib/*.a "$d"/lib/*.dylib; do
    [ -e "$a" ] || continue
    [ -L "$a" ] && continue # skip unversioned/version symlinks; hash the real file
    nlibs=$((nlibs + 1))
    if [ "$nlibs" -le 6 ]; then
      [ -n "$names" ] && names="$names · "
      names="$names$(basename "$a")"
    fi
    sums="$sums$(hash_file "$a")  $(basename "$a")"$'\n'
  done
  [ "$nlibs" -gt 6 ] && names="$nlibs libraries"
  [ -n "$names" ] || names="<em>none</em>"
  rows="$rows| $name | $version | <code>$src_file</code><br><code>$src_sha</code> | $names"$'\n'
  if [ -n "$sums" ]; then
    details="$details<details><summary><code>$name</code> — $nlibs file(s)</summary>"$'\n\n'"$sums"$'\n'"</details>"$'\n'
  fi
done
[ -n "$rows" ] || die "no built dependencies found in pool '$POOLDIR'"

# --- build environment details for the notes ---
runner="local machine"
[ -n "${ImageOS:-}" ] && runner="GitHub Actions ($ImageOS${ImageVersion:+ image $ImageVersion})"
xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
sdk=$(xcrun --show-sdk-version 2>/dev/null)
clang=$(/usr/bin/clang --version 2>/dev/null | sed -n '1p')
cmake=$(cmake --version 2>/dev/null | sed -n '1p')
revision=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)
target_archs=$(for i in "$POOLDIR"/*/BUILD-INFO; do jq -r '.arch' "$i"; done | sort -u | tr '\n' ' ' | sed 's/ *$//')

# --- release description ---
notes=$(mktemp)
{
  echo "Pinned dependencies built from source, from the deps/ pins at revision \`$revision\`."
  echo
  echo "## Build environment"
  echo
  echo "| | |"
  echo "| --- | --- |"
  echo "| Revision | \`$revision\` |"
  echo "| Built on | $runner |"
  echo "| Xcode | $xcode |"
  echo "| macOS SDK | $sdk |"
  echo "| Compiler | $clang |"
  echo "| CMake | $cmake |"
  echo "| Architectures | $target_archs |"
  echo "| Minimum macOS | $(config_get '.config.deployment_target') |"
  echo
  echo "## Libraries"
  echo
  echo "All compiled dependencies ship as one \`build.tar.gz\` containing a directory per library (\`include/\` + \`lib/\` + \`bin/\` + \`BUILD-INFO\` provenance) and a root \`SHA256SUMS\` covering every library file — verify after extraction with \`sha256sum -c SHA256SUMS\`. The tarball's own checksum is published alongside it as \`build.tar.gz.sha256\`."
  echo
  echo "| Library | Compiled version | Source archive · sha256 | Libraries |"
  echo "| --- | --- | --- | --- |"
  printf '%s' "$rows"
  echo
  echo "### Per-file checksums"
  echo
  printf '%s' "$details"
  echo
  echo "Source archives match the SHA-256 pins in \`deps/\`; machine-readable build metadata (resolved versions, per-dependency toolchains) is in \`build.json\`."
} >"$notes"

gh release view "$RELEASE_TAG" >/dev/null 2>&1 \
  || die "release '$RELEASE_TAG' does not exist — publish is triggered by releasing it"
gh release edit "$RELEASE_TAG" --notes-file "$notes"
# shellcheck disable=SC2086
gh release upload "$RELEASE_TAG" $archives "$build_tarball" "$DISTDIR/build.tar.gz.sha256" "$DISTDIR/build.json" --clobber
log "release $RELEASE_TAG updated with sources, the build tarball, checksums and metadata"
