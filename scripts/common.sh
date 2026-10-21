#!/usr/bin/env bash
# Shared helpers for the native-deps build scripts.
# Kept bash 3.2 compatible so they also run on a stock macOS host.
#
# Manifest layout:
#   config/<platform>.toml        deployment target, architectures, and the
#                                 explicit `deps` list for the platform
#   deps/<name>/<platform>.toml   per-library pin: version, url, sha256,
#                                 build kind and flags
# Everything here reads both through a JSON view produced once per
# invocation by scripts/toml2json.py (python 3.11+ stdlib), so the rest of
# the pipeline stays jq-based.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${PLATFORM:-darwin}"
TARGET="${TARGET:-macos}"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/$PLATFORM.toml}"
DEPS_ROOT="${DEPS_ROOT:-$ROOT/deps}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH${2:+ — $2}"; }

dep_pin() { printf '%s/%s/%s.toml' "$DEPS_ROOT" "$1" "$PLATFORM"; } # deps/<name>/<platform>.toml
dep_patch_dir() { printf '%s/%s/patches' "$DEPS_ROOT" "$1"; }

# JSON view of the manifest: {"config": {...}, "deps": {name: {...}}}.
# Converted lazily, once per shell.
_manifest_json() {
  if [ -z "${__MANIFEST_JSON:-}" ]; then
    need jq "brew install jq"
    need python3
    [ -f "$CONFIG_FILE" ] || die "platform config not found at $CONFIG_FILE"
    __MANIFEST_JSON=$(mktemp)
    {
      printf '{"config":'
      python3 "$ROOT/scripts/toml2json.py" "$CONFIG_FILE" || die "failed to parse $CONFIG_FILE"
      printf ',"deps":{'
      sep=""
      for n in $(python3 "$ROOT/scripts/toml2json.py" "$CONFIG_FILE" | jq -r '(.deps // [])[]'); do
        pin=$(dep_pin "$n")
        [ -f "$pin" ] || die "config lists '$n' but there is no pin at $pin"
        printf '%s"%s":' "$sep" "$n"
        python3 "$ROOT/scripts/toml2json.py" "$pin" | jq -c --arg n "$n" '. + {name: $n}' || die "failed to parse $pin"
        sep=","
      done
      printf '}}'
    } >"$__MANIFEST_JSON"
  fi
  printf '%s\n' "$__MANIFEST_JSON"
}

config_get() { jq -r "$1" "$(_manifest_json)"; } # e.g. config_get '.config.deployment_target'

all_target_names() { jq -r '(.config.targets // {}) | keys_unsorted[]' "$(_manifest_json)"; }
target_exists() { [ "$(jq -r --arg t "$1" '(.config.targets // {}) | has($t)' "$(_manifest_json)")" = true ]; }
target_get() { jq -r --arg t "$TARGET" ".config.targets[\$t] | $1" "$(_manifest_json)"; }
pool_slug() { if [ "$2" = macos ]; then printf '%s\n' "$1"; else printf '%s-%s\n' "$1" "$2"; fi; }

all_dep_names() { jq -r '(.config.deps // [])[]' "$(_manifest_json)"; }

# The dep's JSON object; empty when the name is unknown.
dep_json() { jq -c --arg n "$1" '.deps[$n] // empty' "$(_manifest_json)"; }
dep_exists() { [ -n "$(dep_json "$1")" ]; }
dep_get() { dep_json "$1" | jq -r "$2"; }
dep_deps() { dep_json "$1" | jq -r '(.depends_on // [])[]?'; }
dep_is_git() { [ "$(dep_get "$1" 'has("repo")')" = true ]; }
dep_patches() { dep_json "$1" | jq -r '(.patches // [])[]'; }
dep_patches_json() {
  local name=$1 p
  for p in $(dep_patches "$name"); do
    jq -cn --arg file "$p" --arg sha256 "$(hash_file "$(dep_patch_dir "$name")/$p")" '{file: $file, sha256: $sha256}'
  done | jq -sc .
}
dep_target_flags() { dep_json "$1" | jq -r --arg t "$TARGET" '(.targets[$t].configure_flags // [])[]'; }
dep_target_cmake_options() {
  dep_json "$1" | jq -r --arg t "$TARGET" '.targets[$t].cmake_options // {} | to_entries[] | "\(.key)=\(.value)"'
}
dep_target_meson_options() {
  dep_json "$1" | jq -r --arg t "$TARGET" '.targets[$t].meson_options // {} | to_entries[] | "\(.key)=\(.value | if type == "array" then join(",") else tostring end)"'
}

# Substitute {version}, {version_us} (dots -> underscores) and {name} in a URL template.
resolve_url() { # resolve_url <template> <version> <name>
  printf '%s\n' "$2" | tr . _ | { read -r vus
    printf '%s' "$1" \
      | sed -e "s/{version_us}/$vus/g" -e "s/{version}/$2/g" -e "s/{name}/$3/g"
  }
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

hash_file() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

download() { # download <dest> <url>...
  local dest=$1 url; shift
  for url in "$@"; do
    log "downloading $url"
    if curl -fSL --retry 3 --connect-timeout 15 -o "$dest" "$url"; then return 0; fi
    rm -f "$dest"
  done
  return 1
}

dep_source_name() {
  local name=$1 version url
  if dep_is_git "$name"; then
    printf '%s-%s\n' "$name" "$(dep_get "$name" '.commit')"
    return 0
  fi
  version=$(dep_get "$name" '.version')
  url=$(dep_get "$name" '.file // .url')
  basename "$(resolve_url "$url" "$version" "$name")"
}

fetch_source() {
  if dep_is_git "$1"; then
    fetch_git "$@"
  else
    fetch_archive "$@"
  fi
}

# Download a dep's archive from its pinned upstream URL and verify its SHA-256.
fetch_archive() { # fetch_archive <name> <srcs-dir>; echoes the archive path
  local name=$1 srcs=$2 version sha url file archive
  version=$(dep_get "$name" '.version')
  sha=$(dep_get "$name" '.sha256')
  url=$(resolve_url "$(dep_get "$name" '.url')" "$version" "$name")
  file=$(dep_source_name "$name")
  archive="$srcs/$file"
  if [ -f "$archive" ] && [ "$(hash_file "$archive")" = "$sha" ]; then
    log "$file: already downloaded, sha256 verified"
    printf '%s\n' "$archive"
    return 0
  fi
  download "$archive" "$url" || die "$name: failed to download $url"
  [ "$(hash_file "$archive")" = "$sha" ] || die "$name: sha256 mismatch for $file (expected $sha)"
  printf '%s\n' "$archive"
}

fetch_git() {
  local name=$1 srcs=$2 repo ref commit dir
  repo=$(dep_get "$name" '.repo')
  ref=$(dep_get "$name" '.ref')
  commit=$(dep_get "$name" '.commit')
  dir="$srcs/$(dep_source_name "$name")"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
    log "$name: $commit already checked out"
    printf '%s\n' "$dir"
    return 0
  fi
  need git
  rm -rf "$dir"
  mkdir -p "$srcs"
  git init -q "$dir" >&2
  git -C "$dir" remote add origin "$repo" >&2
  log "fetching $repo $ref at $commit"
  git -C "$dir" fetch -q --depth 1 origin "$commit" >&2 \
    || git -C "$dir" fetch -q origin "+$ref:refs/pin/ref" >&2 \
    || die "$name: failed to fetch $ref from $repo"
  git -C "$dir" -c advice.detachedHead=false checkout -q "$commit" >&2 \
    || die "$name: commit $commit is not reachable from $ref in $repo"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$name: checked out $(git -C "$dir" rev-parse HEAD), expected $commit"
  if [ "$(dep_get "$name" 'if has("submodules") then .submodules else true end')" = true ] && [ -f "$dir/.gitmodules" ]; then
    git -C "$dir" submodule update -q --init --recursive --depth 1 >&2 \
      || git -C "$dir" submodule update -q --init --recursive >&2 \
      || die "$name: failed to check out submodules of $commit"
  fi
  printf '%s\n' "$dir"
}

extract() { # extract <archive> <dest-dir>; echoes the directory containing the sources
  mkdir -p "$2"
  if [ -d "$1" ]; then
    cp -R "$1" "$2/"
    printf '%s/%s\n' "$2" "$(basename "$1")"
    return 0
  fi
  tar -xf "$1" -C "$2"
  local entries first
  entries=$(ls -A "$2")
  first=$(printf '%s\n' "$entries" | head -1)
  if [ "$(printf '%s\n' "$entries" | grep -c .)" -eq 1 ] && [ -d "$2/$first" ]; then
    printf '%s\n' "$2/$first"
  else
    printf '%s\n' "$2"
  fi
}

apply_patches() {
  local name=$1 srcdir=$2 p
  for p in $(dep_patches "$name"); do
    log "$name: applying $p"
    patch -p1 --forward --batch -d "$srcdir" <"$(dep_patch_dir "$name")/$p" >&2 || die "$name: patch $p does not apply"
  done
}

is_cross() { [ "$(uname -m)" != "$1" ] || [ "$TARGET" != macos ]; } # cross-compiling when target arch or SDK != host

njobs() { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4; }

# Entry hash: covers the dep's own entry, its transitive dependencies'
# entries, the platform config and the build scripts. Used as the CI cache
# key so that bumping e.g. openssl also rebuilds everything that links
# against it.
entry_hash() { # entry_hash <name> <memo-file>
  local name=$1 memo=$2 h d
  if h=$(awk -v n="$name" '$1 == n {print $2}' "$memo" 2>/dev/null) && [ -n "$h" ]; then
    printf '%s\n' "$h"
    return 0
  fi
  {
    dep_json "$name"
    for d in $(dep_patches "$name"); do cat "$(dep_patch_dir "$name")/$d"; done
    for d in $(dep_deps "$name"); do entry_hash "$d" "$memo"; done
    cat "$CONFIG_FILE"
    cat "$ROOT/scripts/common.sh" "$ROOT/scripts/build.sh" "$ROOT/scripts/recipes.sh"
  } | hash_stdin | { read -r h
    printf '%s %s\n' "$name" "$h" >>"$memo"
    printf '%s\n' "$h"
  }
}

# Print every dep name in dependency order; dies on cycles.
resolve_order() {
  local tmp remaining name d ready progressed pass total
  tmp=$(mktemp -d)
  all_dep_names >"$tmp/all"
  cp "$tmp/all" "$tmp/remaining"
  : >"$tmp/built"
  total=$(grep -c . "$tmp/all" || true)
  pass=0
  while [ -s "$tmp/remaining" ]; do
    pass=$((pass + 1))
    [ "$pass" -le $((total + 1)) ] || die "dependency cycle detected among: $(paste -s -d', ' "$tmp/remaining" 2>/dev/null)"
    progressed=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      ready=1
      for d in $(dep_deps "$name"); do
        grep -qx -- "$d" "$tmp/built" || ready=0
      done
      [ "$ready" -eq 1 ] || continue
      printf '%s\n' "$name"
      printf '%s\n' "$name" >>"$tmp/built"
      # grep exits 1 when this was the last remaining dep; that is success here.
      grep -vx -- "$name" "$tmp/remaining" >"$tmp/remaining.new" || true
      mv "$tmp/remaining.new" "$tmp/remaining"
      progressed=1
    done <"$tmp/remaining"
    [ "$progressed" -eq 1 ] || die "dependency cycle detected among: $(paste -s -d', ' "$tmp/remaining" 2>/dev/null)"
  done
  rm -rf "$tmp"
}
