#!/usr/bin/env bash

toolchain_architectures() { printf '%s\n' x86_64; }

toolchain_check_config() {
  jq -e '.config.toolchain | (.msystem | type) == "string"
           and (.packages | type) == "array" and (.packages | all(type == "string"))' \
    "$(_manifest_json)" >/dev/null || die "config/$PLATFORM.toml: [toolchain] needs a string msystem and a packages list"
}

toolchain_id() {
  printf 'msys2 %s gcc %s cmake %s meson %s' \
    "${MSYSTEM:-none}" "$(gcc -dumpfullversion 2>/dev/null)" \
    "$(cmake --version 2>/dev/null | sed -n '1s/^cmake version //p')" "$(meson --version 2>/dev/null)"
}

toolchain_setup() {
  local tool msystem
  msystem=$(config_get '.config.toolchain.msystem')
  case "$(uname -s)" in
    MINGW* | MSYS*) ;;
    *) die "windows builds must run in an MSYS2 $msystem shell" ;;
  esac
  [ "${MSYSTEM:-}" = "$msystem" ] || die "MSYSTEM is '${MSYSTEM:-}', expected $msystem"
  [ "$(uname -m)" = "$ARCH" ] || die "windows builds are native: the host is $(uname -m) but $ARCH was requested"
  for tool in gcc g++ make cmake meson ninja pkg-config python3 perl patch git nasm; do need "$tool"; done

  MIN=""
  SDK_NAME=""
  SDK_PATH=""
  MIN_FLAG=""
  CC=gcc
  CXX=g++
  MESON_SYSTEM=windows
  MESON_CPU_FAMILY=$ARCH
  ARCH_FLAGS=""
  ARCH_LDFLAGS=""
  HOST_TRIPLE=$(gcc -dumpmachine)
  HOST_PKGCONFIG=""
  OPENSSL_TARGET=mingw64
}

toolchain_cross() { return 1; }

toolchain_cmake_args() { printf -- '-G Ninja'; }

toolchain_host_cmake_args() { :; }

toolchain_meson_args() { :; }

toolchain_dep_ldflags() { printf -- '-L%s' "$1"; }

toolchain_release_notes() {
  local pools=$1
  echo "| MSYS2 environment | $(config_get '.config.toolchain.msystem') |"
  echo "| Toolchain | $(for i in "$pools"/*/BUILD-INFO "$pools"/*/*/BUILD-INFO "$pools"/*/*/*/BUILD-INFO; do [ -f "$i" ] && jq -r '.toolchain' "$i"; done | sort -u | paste -s -d';' - | sed 's/;/<br>/g') |"
}
