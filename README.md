# native-deps

Mirror of the upstream source archives that chiaki-ng projects, such as Chiaki-ng for macOS and Akira, build their native dependencies from.

The archives live on the [`sources` release](https://github.com/chiaki-ng/native-deps/releases/tag/sources). They are unmodified copies of upstream releases, kept so that older versions of each project stay buildable if an upstream download disappears. Every filename carries its version, so projects share one release without collisions.

Builds download from this mirror first and fall back to the upstream URL. Each project checks every archive against the SHA-256 pinned in its own repository, so the mirror is a convenience, not a trust anchor.

To add archives, pin the version, upstream URL and SHA-256 in the project, then upload any missing files to the `sources` release. In Chiaki-ng for macOS, `make mirror-deps` does this.

Each archive keeps its own upstream licence; see the licence files inside it.

For the sake of build scripts, please keep tags as follows:

```
<platform>-deps-<ddmmyy>
```

## Platforms

`PLATFORM=darwin|linux|windows|nx` picks `config/<platform>.toml`, the pins at `deps/<name>/<platform>.toml` and `scripts/toolchain-<platform>.sh`. darwin builds on macOS with Xcode 26; linux builds in the pinned GCC 16 image (Debian 13, glibc 2.41); windows builds in an MSYS2 UCRT64 shell; nx cross-builds static libraries for the Nintendo Switch in the pinned devkitA64 image, updated to GCC 16. `scripts/plan.sh --packages` prints the host packages a platform expects, `--dkp-packages` the devkitPro packages nx adds, and `--image` the container image.

## Pins

A pin is either an archive (`url` and `sha256`) or a git source (`repo`, `ref` and the full `commit` that is checked out). Either may list `patches`, files under `deps/<name>/patches/` applied with `patch -p1` before the build. Build kinds are `cmake`, `configure`, `openssl`, `meson` and `make`. `make bump NAME=x VERSION=y` moves an archive pin; `make bump NAME=x [REF=y]` resolves a git pin's commit. `BUILD-INFO` in each pool entry records the source, commit and patch hashes.

Releases are tagged `<platform>-deps-<ddmmyy>` and each platform's workflow publishes only for its own tag.
