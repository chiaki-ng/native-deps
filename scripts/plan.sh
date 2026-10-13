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

RUNNER_IMAGE="${RUNNER_IMAGE:-macos-26}"
ARCH="${ARCH:-all}"
ONLY="${ONLY:-}"
ONLY_TARGET="${ONLY_TARGET:-all}"

validate() {
  local f a orphans
  config_get '.config.deployment_target' | grep -qE '^[0-9]+\.[0-9]+$' \
    || die "config/$PLATFORM.toml: deployment_target must look like 26.0"
  archs=$(config_get '.config.architectures[]?')
  [ -n "$archs" ] || die "config/$PLATFORM.toml: architectures must not be empty"
  for a in $archs; do
    case "$a" in arm64 | x86_64) ;; *) die "config/$PLATFORM.toml: unsupported architecture '$a'" ;; esac
  done
  [ -n "$(all_target_names)" ] || die "config/$PLATFORM.toml: targets must not be empty"
  jq -e '.config.targets | to_entries | all((.value.sdk | type) == "string" and (.value.minimum_flag | type) == "string")' \
    "$(_manifest_json)" >/dev/null || die "config/$PLATFORM.toml: every target needs string sdk and minimum_flag"
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
    dep_json "$f" | jq -e '(.version|type) == "string" and (.url|type) == "string"
                           and (.sha256|type) == "string"
                           and (.kind | IN("cmake","configure","openssl"))' \
      >/dev/null || die "deps/$f/$PLATFORM.toml: needs string version/url/sha256 and kind of cmake|configure|openssl"
    dep_get "$f" '.sha256' | grep -qE '^[0-9a-f]{64}$' || die "deps/$f/$PLATFORM.toml: sha256 must be 64 lowercase hex chars"
    if [ "$(dep_get "$f" '.kind')" = cmake ]; then
      dep_json "$f" | jq -e '(.cmake_options // {} | type) == "object"' >/dev/null \
        || die "deps/$f/$PLATFORM.toml: cmake_options must be a table"
    fi
    for d in $(dep_deps "$f"); do
      dep_exists "$d" || die "deps/$f/$PLATFORM.toml: depends on unknown dep '$d'"
      [ "$d" != "$f" ] || die "deps/$f/$PLATFORM.toml: depends on itself"
    done
  done

  resolve_order >/dev/null # cycle check
}

validate

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
if [ "$ARCH" != all ]; then
  case " $archs " in *" $ARCH "*) archs=$ARCH ;; *) die "architecture '$ARCH' not enabled for $PLATFORM in config/$PLATFORM.toml" ;; esac
fi

targets=$(all_target_names | tr '\n' ' ')
if [ "$ONLY_TARGET" != all ]; then
  target_exists "$ONLY_TARGET" || die "target '$ONLY_TARGET' not enabled for $PLATFORM in config/$PLATFORM.toml"
  targets=$ONLY_TARGET
fi

# Content hash per dep (recursive over depends_on) -> cache keys.
memo=$(mktemp)
includes=""
for n in $names; do
  h=$(entry_hash "$n" "$memo")
  first_dep=$(dep_deps "$n" | head -1)
  for a in $archs; do
    for t in $targets; do
      slug=$(pool_slug "$a" "$t")
      needs_key=""
      [ -n "$first_dep" ] && needs_key="dep-$first_dep-$slug-$RUNNER_IMAGE-$(entry_hash "$first_dep" "$memo")"
      includes="$includes$(jq -cn --arg name "$n" --arg arch "$a" --arg target "$t" --arg slug "$slug" \
        --arg image "$RUNNER_IMAGE" --arg entryhash "$h" --arg needs_key "$needs_key" \
        '{name: $name, arch: $arch, target: $target, slug: $slug, image: $image, entryhash: $entryhash, needs_key: $needs_key}')"$'\n'
    done
  done
done
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
