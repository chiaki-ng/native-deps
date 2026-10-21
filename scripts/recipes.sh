#!/usr/bin/env bash
# Per-kind build recipes. Sourced by build.sh, which sets:
#   ARCH ARCH_FLAGS ARCH_LDFLAGS MIN PREFIX POOL WORK
#   DEP_CPPFLAGS DEP_LDFLAGS DEP_PKGCONFIG DEP_PREFIX_PATH  (from depends_on)
# Expects common.sh to already be sourced.
#
# The cmake recipe mirrors the hermetic setup of chiaki-native-main's
# Tools/Dependencies/build.py: PIC static libs, libdir=lib, and package
# lookup fenced off from Homebrew and the cmake registry so builds only
# ever see the pinned pool.

# Expand tokens in manifest flags: @ARCH@ -> target arch, @POOL@ -> dep pool root,
# @SDK@ -> target SDK path, @MINFLAG@ -> the target's minimum-OS compiler flag.
expand_tokens() {
  printf '%s' "$1" | sed -e "s/@ARCH@/$ARCH/g" -e "s|@POOL@|$POOL|g" -e "s|@SDK@|$SDK_PATH|g" -e "s|@MINFLAG@|$MIN_FLAG=$MIN|g" -e "s|@HOSTBUILD@|${HOST_BUILD:-}|g" -e "s|@PREFIX@|$PREFIX|g"
}

pkgconfig_libdir() { printf '%s' "${DEP_PKGCONFIG#:}${HOST_PKGCONFIG:+:$HOST_PKGCONFIG}" | sed 's/^://'; }

recipe_cmake() { # recipe_cmake <name> <srcdir>
  local name=$1 srcdir=$2 b="$2/ci-build" opts kv depargs shared extra="" system host_targets
  opts=$({ dep_get "$name" '.cmake_options // {} | to_entries[] | "\(.key)=\(.value)"'; dep_target_cmake_options "$name"; } | while IFS= read -r kv; do printf -- '-D%s ' "$(expand_tokens "$kv")"; done)
  if [ "$(dep_get "$name" '.shared // false')" = true ]; then shared=ON; else shared=OFF; fi
  system=$(target_get '.cmake_system_name // empty')
  depargs=""
  [ -n "$DEP_PREFIX_PATH" ] && depargs="-DCMAKE_PREFIX_PATH=${DEP_PREFIX_PATH//:/;}"

  # protobuf cross builds need a protoc that runs on the build host: build a
  # native one first, then build only the libraries for the target arch.
  host_targets=$(dep_get "$name" '(.host_cmake_targets // [])[]')
  if [ -n "$host_targets" ] && [ -z "$system" ] && is_cross "$ARCH"; then
    log "$name: building host tools ($(uname -m)) for cross-compilation: $(printf '%s' "$host_targets" | tr '\n' ' ')"
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      cmake -S "$srcdir" -B "$srcdir/host-build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$srcdir/host-prefix" \
      $(toolchain_host_cmake_args) \
      $(dep_get "$name" '.host_cmake_options // {} | to_entries[] | "-D\(.key)=\(.value)"') >/dev/null
    for kv in $host_targets; do
      env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
        cmake --build "$srcdir/host-build" --target "$kv" -j "$(njobs)"
    done
    HOST_BUILD="$srcdir/host-build"
    extra=$(dep_get "$name" '.cross_cmake_options // {} | to_entries[] | "-D\(.key)=\(.value)"' | while IFS= read -r kv; do printf '%s ' "$(expand_tokens "$kv")"; done)
  fi

  env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    PKG_CONFIG_PATH="${DEP_PKGCONFIG#:}" PKG_CONFIG_LIBDIR="$(pkgconfig_libdir)" \
    cmake -S "$srcdir" -B "$b" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=$shared \
    -DBUILD_TESTING=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    $(toolchain_cmake_args) \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    $depargs $opts $extra
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake --build "$b" -j "$(njobs)"
  cmake --install "$b"
}

recipe_configure() { # recipe_configure <name> <srcdir>
  local name=$1 srcdir=$2 b="$2/ci-build" flags="" f hostarg="" crossflags="" linkage
  while IFS= read -r f; do flags="$flags$(expand_tokens "$f") "; done \
    <<<"$(dep_get "$name" '(.configure_flags // [])[]'; dep_target_flags "$name")"
  if [ "$(dep_get "$name" '.shared // false')" = true ]; then
    linkage="--enable-shared --disable-static"
  else
    linkage="--enable-static --disable-shared"
  fi
  if is_cross "$ARCH"; then
    [ "$(dep_get "$name" '.host_flag == false')" = true ] || hostarg="--host=$HOST_TRIPLE"
    while IFS= read -r f; do crossflags="$crossflags$(expand_tokens "$f") "; done \
      <<<"$(dep_get "$name" '(.cross_configure_flags // [])[]')"
  fi
  mkdir -p "$b"
  (
    cd "$b"
    env CC="$CC" CXX="$CXX" \
      CFLAGS="$ARCH_FLAGS" CXXFLAGS="$ARCH_FLAGS" \
      CPPFLAGS="$DEP_CPPFLAGS" \
      LDFLAGS="$ARCH_LDFLAGS $DEP_LDFLAGS" \
      PKG_CONFIG_PATH="${DEP_PKGCONFIG#:}" \
      "$srcdir/configure" \
      --prefix="$PREFIX" $linkage $hostarg $flags $crossflags
  )
  make -C "$b" -j "$(njobs)"
  make -C "$b" install
}

recipe_openssl() { # recipe_openssl <name> <srcdir>
  local name=$1 srcdir=$2 flags="" f
  # shared vs no-shared comes from configure_flags, like build.py
  while IFS= read -r f; do flags="$flags$(expand_tokens "$f") "; done \
    <<<"$(dep_get "$name" '(.configure_flags // [])[]'; dep_target_flags "$name")"
  (
    cd "$srcdir"
    env CC="$CC" CFLAGS="$ARCH_FLAGS" \
      ./Configure "$OPENSSL_TARGET" --prefix="$PREFIX" --libdir=lib $flags
  )
  make -C "$srcdir" -j "$(njobs)"
  make -C "$srcdir" install_sw
}

meson_list() { printf '%s\n' "$1" | tr ' ' '\n' | sed -e '/^$/d' -e "s/.*/'&'/" | paste -s -d, - | sed 's/,/, /g'; }

meson_cross_file() {
  local file=$1
  {
    printf '[binaries]\n'
    printf "c = '%s'\ncpp = '%s'\nar = 'ar'\nstrip = 'strip'\npkg-config = 'pkg-config'\n" "$CC" "$CXX"
    printf '\n[built-in options]\n'
    printf 'c_args = [%s]\n' "$(meson_list "$ARCH_FLAGS $DEP_CPPFLAGS")"
    printf 'cpp_args = [%s]\n' "$(meson_list "$ARCH_FLAGS $DEP_CPPFLAGS")"
    printf 'c_link_args = [%s]\n' "$(meson_list "$ARCH_LDFLAGS $DEP_LDFLAGS")"
    printf 'cpp_link_args = [%s]\n' "$(meson_list "$ARCH_LDFLAGS $DEP_LDFLAGS")"
    printf "\n[host_machine]\nsystem = '%s'\ncpu_family = '%s'\ncpu = '%s'\nendian = 'little'\n" "$MESON_SYSTEM" "$MESON_CPU_FAMILY" "$ARCH"
  } >"$file"
}

recipe_meson() {
  local name=$1 srcdir=$2 b="$2/ci-build" opts kv linkage cross="" menv
  opts=$({ dep_get "$name" '.meson_options // {} | to_entries[] | "\(.key)=\(.value | if type == "array" then join(",") else tostring end)"'; dep_target_meson_options "$name"; } | while IFS= read -r kv; do printf -- '-D%s ' "$kv"; done)
  if [ "$(dep_get "$name" '.shared // false')" = true ]; then linkage=shared; else linkage=static; fi
  if is_cross "$ARCH"; then
    meson_cross_file "$srcdir/cross.ini"
    cross="--cross-file $srcdir/cross.ini"
  fi
  menv=(CC="$CC" CXX="$CXX" PKG_CONFIG_PATH="${DEP_PKGCONFIG#:}" PKG_CONFIG_LIBDIR="$(pkgconfig_libdir)" CMAKE_PREFIX_PATH="$DEP_PREFIX_PATH")
  [ -z "${ARCH_FLAGS// /}" ] || menv+=(CFLAGS="$ARCH_FLAGS" CXXFLAGS="$ARCH_FLAGS")
  [ -z "${DEP_CPPFLAGS// /}" ] || menv+=(CPPFLAGS="$DEP_CPPFLAGS")
  [ -z "$DEP_LIBDIRS" ] || menv+=(LIBRARY_PATH="${DEP_LIBDIRS#:}${LIBRARY_PATH:+:$LIBRARY_PATH}")
  [ -z "${ARCH_LDFLAGS// /}${DEP_LDFLAGS// /}" ] || menv+=(LDFLAGS="$ARCH_LDFLAGS $DEP_LDFLAGS")
  env "${menv[@]}" \
    meson setup "$b" "$srcdir" \
    --prefix="$PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --wrap-mode=nodownload \
    -Ddefault_library=$linkage \
    $(toolchain_meson_args) \
    $cross $opts
  meson compile -C "$b" -j "$(njobs)"
  meson install -C "$b"
}

recipe_make() {
  local name=$1 srcdir=$2 flags="" f
  while IFS= read -r f; do [ -z "$f" ] || flags="$flags$(expand_tokens "$f") "; done \
    <<<"$(dep_get "$name" '(.make_flags // [])[]')"
  env CC="$CC" CXX="$CXX" make -C "$srcdir" -j "$(njobs)" $flags
  env CC="$CC" CXX="$CXX" make -C "$srcdir" $flags install
}

build_dep() { # build_dep <name>; fetch, extract and build into $PREFIX
  local name=$1 srcdir source kind
  log "building $name for $ARCH $TARGET"
  source=$(fetch_source "$name" "$WORK/srcs")
  rm -rf "$WORK/build/$name"
  srcdir=$(extract "$source" "$WORK/build/$name")
  apply_patches "$name" "$srcdir"
  kind=$(dep_get "$name" '.kind')
  case "$kind" in
    cmake) recipe_cmake "$name" "$srcdir" ;;
    configure) recipe_configure "$name" "$srcdir" ;;
    openssl) recipe_openssl "$name" "$srcdir" ;;
    meson) recipe_meson "$name" "$srcdir" ;;
    make) recipe_make "$name" "$srcdir" ;;
    *) die "$name: unknown kind '$kind'" ;;
  esac
}
