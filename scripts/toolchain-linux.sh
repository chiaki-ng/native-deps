#!/usr/bin/env bash

toolchain_architectures() { printf '%s\n' x86_64 aarch64; }

toolchain_check_config() {
  jq -e '.config.toolchain | (.image | type) == "string" and (.glibc | type) == "string" and (.gcc | type) == "string"
           and (.packages | type) == "array" and (.packages | all(type == "string"))' \
    "$(_manifest_json)" >/dev/null || die "config/$PLATFORM.toml: [toolchain] needs string image, glibc and gcc and a packages list"
  config_get '.config.toolchain.glibc' | grep -qE '^[0-9]+\.[0-9]+$' \
    || die "config/$PLATFORM.toml: toolchain.glibc must look like 2.36"
  config_get '.config.toolchain.gcc' | grep -qE '^[0-9]+$' \
    || die "config/$PLATFORM.toml: toolchain.gcc must be a major version like 16"
}

toolchain_glibc() { getconf GNU_LIBC_VERSION 2>/dev/null | sed 's/^glibc //'; }

toolchain_id() {
  printf 'debian %s glibc %s gcc %s cmake %s meson %s' \
    "$(cat /etc/debian_version 2>/dev/null || echo none)" "$(toolchain_glibc)" "$(gcc -dumpfullversion 2>/dev/null)" \
    "$(cmake --version 2>/dev/null | sed -n '1s/^cmake version //p')" "$(meson --version 2>/dev/null)"
}

toolchain_setup() {
  local tool floor host
  [ "$(uname -s)" = Linux ] || die "linux builds must run on Linux, inside $(config_get '.config.toolchain.image')"
  [ "$(uname -m)" = "$ARCH" ] || die "linux builds are native: the host is $(uname -m) but $ARCH was requested"
  for tool in gcc g++ make cmake meson ninja pkg-config python3 perl patch git; do need "$tool"; done
  [ "$ARCH" != x86_64 ] || need nasm
  local wanted_gcc
  wanted_gcc=$(config_get '.config.toolchain.gcc')
  [ "$(gcc -dumpversion | cut -d. -f1)" = "$wanted_gcc" ] \
    || die "gcc $(gcc -dumpfullversion) found but the pin is gcc $wanted_gcc; build inside $(config_get '.config.toolchain.image')"
  floor=$(config_get '.config.toolchain.glibc')
  host=$(toolchain_glibc)
  [ -n "$host" ] || die "cannot read the host glibc version"
  [ "$(printf '%s\n%s\n' "$host" "$floor" | sort -V | tail -1)" = "$floor" ] \
    || die "host glibc $host is newer than the $floor floor; build inside $(config_get '.config.toolchain.image')"

  MIN=$floor
  SDK_NAME=""
  SDK_PATH=""
  MIN_FLAG=""
  CC=gcc
  CXX=g++
  MESON_SYSTEM=linux
  MESON_CPU_FAMILY=$ARCH
  ARCH_FLAGS=""
  ARCH_LDFLAGS=""
  HOST_TRIPLE=$(gcc -dumpmachine)
  HOST_PKGCONFIG="/usr/lib/$HOST_TRIPLE/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
  OPENSSL_TARGET="linux-$ARCH"
  OPENSSL_FLAGS=""
}

toolchain_cross() { return 1; }

toolchain_cmake_args() { :; }


toolchain_meson_args() { printf -- '-Db_staticpic=true'; }

toolchain_dep_ldflags() { printf -- '-L%s -Wl,-rpath-link,%s' "$1" "$1"; }

toolchain_release_notes() {
  local pools=$1
  echo "| Container | \`$(config_get '.config.toolchain.image')\` |"
  echo "| glibc floor | $(config_get '.config.toolchain.glibc') |"
  echo "| GCC | $(config_get '.config.toolchain.gcc') |"
  echo "| Toolchain | $(for i in "$pools"/*/BUILD-INFO "$pools"/*/*/BUILD-INFO "$pools"/*/*/*/BUILD-INFO; do [ -f "$i" ] && jq -r '.toolchain' "$i"; done | sort -u | paste -s -d';' - | sed 's/;/<br>/g') |"
}
