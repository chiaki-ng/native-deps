#!/usr/bin/env bash
# Validate the manifest and derive the CI build plan from it.
#
# Manifest layout: config/<platform>.toml holds the explicit deps list and
# platform settings; deps/<name>/<platform>.toml holds each pin.
#
# Inputs (env):
#   ONLY          comma/space separated dep names to build (default: all)
#   ARCH          all | arm64 | x86_64 (default: all)
#   ONLY_TARGET   all | macos | ios | ios-simulator (default: all)
#   PLATFORM      platform (default: darwin)
#   RUNNER_IMAGE  GitHub runner label for build jobs (default: macos-26)
#
# With --check, only validates. Otherwise writes to $GITHUB_OUTPUT (CI):
#   matrix         {include: [{name, arch, target, slug, image, entryhash, needs_key}]}
#   architectures  ["arm64", ...]
#   revision       short git sha
# Locally it prints the plan for inspection.

set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

RUNNER_IMAGE="${RUNNER_IMAGE:-}"
ARCH_FILTER="${ARCH:-all}"
ARCH=all
ONLY="${ONLY:-}"
ONLY_TARGET="${ONLY_TARGET:-all}"

validate() {
  local f a d p orphans
  archs=$(config_get '.config.architectures[]?')
  [ -n "$archs" ] || die "config/$PLATFORM.toml: architectures must not be empty"
  for a in $archs; do
    toolchain_architectures | grep -qx -- "$a" || die "config/$PLATFORM.toml: unsupported architecture '$a'"
    [ "$(config_get --arg a "$a" '.config.toolchain.runners[$a] | type')" = string ] \
      || die "config/$PLATFORM.toml: toolchain.runners needs a runner label for $a"
  done
  [ -n "$(all_target_names)" ] || die "config/$PLATFORM.toml: targets must not be empty"
  target_exists "$(primary_target)" || die "config/$PLATFORM.toml: primary_target must name one of its targets"
  toolchain_check_config
  [ -n "$(all_dep_names)" ] || die "config/$PLATFORM.toml: deps list must not be empty"

  # Every pin on disk must be listed, every listed entry must exist on disk.
  orphans=""
  for f in "$DEPS_ROOT"/*/"$PLATFORM.toml"; do
    [ -f "$f" ] || continue
    n=$(basename "$(dirname "$f")")
    dep_exists "$n" || orphans="$orphans $n"
  done
  [ -z "$orphans" ] || die "pins not listed in config/$PLATFORM.toml deps:$orphans"

  for f in $(all_dep_names); do
    dep_json "$f" | jq -e '(.version|type) == "string" and (.kind | IN("cmake","configure","openssl","meson","make"))' \
      >/dev/null || die "deps/$f/$PLATFORM.toml: needs string version and kind of cmake|configure|openssl|meson|make"
    if dep_is_git "$f"; then
      dep_json "$f" | jq -e '(.repo|type) == "string" and (.ref|type) == "string"
                             and (has("url") or has("sha256") or has("file") | not)
                             and ((.submodules // false) | type) == "boolean"' \
        >/dev/null || die "deps/$f/$PLATFORM.toml: git pins need string repo and ref, an optional boolean submodules, and no url, file or sha256"
      dep_get "$f" '.commit' | grep -qE '^[0-9a-f]{40}$' \
        || die "deps/$f/$PLATFORM.toml: commit must be the full 40-hex SHA that ref resolves to (scripts/bump.sh --git $f)"
    else
      dep_json "$f" | jq -e '(.url|type) == "string" and (.sha256|type) == "string"
                             and ((.file // "") | type) == "string"' \
        >/dev/null || die "deps/$f/$PLATFORM.toml: archive pins need string url and sha256 (or repo, ref and commit for a git pin)"
      dep_get "$f" '.sha256' | grep -qE '^[0-9a-f]{64}$' || die "deps/$f/$PLATFORM.toml: sha256 must be 64 lowercase hex chars"
    fi
    dep_json "$f" | jq -e '(.architectures // []) | type == "array" and all(type == "string")' >/dev/null \
      || die "deps/$f/$PLATFORM.toml: architectures must be a list of architecture names"
    for a in $(dep_get "$f" '(.architectures // [])[]') $(dep_get "$f" '(.arch // {}) | keys[]'); do
      printf '%s\n' $archs | grep -qx -- "$a" || die "deps/$f/$PLATFORM.toml: architecture '$a' is not enabled in config/$PLATFORM.toml"
    done
    dep_json "$f" | jq -e '(.patches // []) | type == "array" and all(type == "string")' >/dev/null \
      || die "deps/$f/$PLATFORM.toml: patches must be a list of file names"
    for p in $(dep_patches "$f"); do
      printf '%s\n' "$p" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._+-]*$' \
        || die "deps/$f/$PLATFORM.toml: patch '$p' must be a plain file name under deps/$f/patches/"
      [ -f "$(dep_patch_dir "$f")/$p" ] || die "deps/$f/$PLATFORM.toml: listed patch deps/$f/patches/$p does not exist"
    done
    if [ "$(dep_get "$f" '.kind')" = cmake ]; then
      dep_json "$f" | jq -e '(.cmake_options // {} | type) == "object"' >/dev/null \
        || die "deps/$f/$PLATFORM.toml: cmake_options must be a table"
    fi
    dep_json "$f" | jq -e '[.configure_flags, .cross_configure_flags, .make_flags, .host_cmake_targets] | all(. == null or (type == "array" and all(type == "string")))' >/dev/null \
      || die "deps/$f/$PLATFORM.toml: configure_flags, cross_configure_flags, make_flags and host_cmake_targets must be lists of strings"
    if [ "$(dep_get "$f" '.kind')" = meson ]; then
      dep_json "$f" | jq -e '(.meson_options // {} | type) == "object"' >/dev/null \
        || die "deps/$f/$PLATFORM.toml: meson_options must be a table"
    fi
  done

  for ARCH in $archs; do
    for f in $(all_dep_names); do
      dep_enabled "$f" || continue
      for d in $(dep_deps "$f"); do
        dep_exists "$d" || die "deps/$f/$PLATFORM.toml: depends on unknown dep '$d'"
        [ "$d" != "$f" ] || die "deps/$f/$PLATFORM.toml: depends on itself"
        dep_enabled "$d" || die "deps/$f/$PLATFORM.toml: depends on '$d', which is not built for $ARCH"
      done
    done
    resolve_order >/dev/null # cycle check
  done
  ARCH=all
}

validate

if [ "${1:-}" = "--packages" ]; then
  config_get '(.config.toolchain.packages // [])[]'
  exit 0
fi

if [ "${1:-}" = "--dkp-packages" ]; then
  config_get '(.config.toolchain.dkp_packages // [])[]'
  exit 0
fi

if [ "${1:-}" = "--image" ]; then
  config_get '.config.toolchain.image // empty'
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  log "manifest OK: platform $PLATFORM, $(all_dep_names | wc -l | tr -d ' ') deps, architectures: $(config_get '.config.architectures | join(", ")'), targets: $(all_target_names | paste -s -d, - | sed 's/,/, /g')"
  exit 0
fi

# Select deps: ONLY literal, or the full list from the platform config.
names=$(all_dep_names | tr '\n' ' ')
if [ -n "$ONLY" ]; then
  names=""
  for n in $(printf '%s' "$ONLY" | tr ',' ' '); do
    dep_exists "$n" || die "unknown dependency '$n' (not in the deps list of config/$PLATFORM.toml)"
    names="$names $n"
  done
fi

# Filter architectures.
archs=$(config_get '.config.architectures[]' | tr '\n' ' ')
if [ "$ARCH_FILTER" != all ]; then
  case " $archs " in *" $ARCH_FILTER "*) archs=$ARCH_FILTER ;; *) die "architecture '$ARCH_FILTER' not enabled for $PLATFORM in config/$PLATFORM.toml" ;; esac
fi

targets=$(all_target_names | tr '\n' ' ')
if [ "$ONLY_TARGET" != all ]; then
  target_exists "$ONLY_TARGET" || die "target '$ONLY_TARGET' not enabled for $PLATFORM in config/$PLATFORM.toml"
  targets=$ONLY_TARGET
fi

# Content hash per dep (recursive over depends_on) -> cache keys.
memo=$(mktemp)
includes=""
container=$(config_get '.config.toolchain.image // ""')
for ARCH in $archs; do
  image=${RUNNER_IMAGE:-$(config_get --arg a "$ARCH" '.config.toolchain.runners[$a]')}
  for n in $names; do
    dep_enabled "$n" || continue
    h=$(entry_hash "$n" "$memo")
    first_dep=$(dep_deps "$n" | head -1)
    for t in $targets; do
      slug=$(pool_slug "$ARCH" "$t")
      needs_key=""
      [ -n "$first_dep" ] && needs_key="dep-$first_dep-$slug-$image-$(entry_hash "$first_dep" "$memo")"
      includes="$includes$(jq -cn --arg name "$n" --arg arch "$ARCH" --arg target "$t" --arg slug "$slug" \
        --arg image "$image" --arg container "$container" --arg entryhash "$h" --arg needs_key "$needs_key" \
        '{name: $name, arch: $arch, target: $target, slug: $slug, image: $image, container: $container, entryhash: $entryhash, needs_key: $needs_key}')"$'\n'
    done
  done
done
ARCH=all
rm -f "$memo"

matrix=$(printf '%s' "$includes" | jq -s '{include: .}')
archs_json=$(printf '%s\n' $archs | jq -R . | jq -sc .)
revision=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)

emit() { # emit <key> <value>
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  else
    printf '%-14s %s\n' "$1:" "$2"
  fi
}
emit matrix "$(printf '%s' "$matrix" | jq -c .)"
emit architectures "$archs_json"
emit revision "$revision"

if [ -z "${GITHUB_OUTPUT:-}" ]; then
  printf '%s' "$matrix" | jq -r '.include[] | "  \(.name) \(.arch) \(.target) @\(.image) key=\(.entryhash[0:12])…"'
fi
