# native-deps

Mirror of the upstream source archives that chiaki-ng projects, such as Chiaki-ng for macOS and Akira, build their native dependencies from.

The archives live on the [`sources` release](https://github.com/chiaki-ng/native-deps/releases/tag/sources). They are unmodified copies of upstream releases, kept so that older versions of each project stay buildable if an upstream download disappears. Every filename carries its version, so projects share one release without collisions.

Builds download from this mirror first and fall back to the upstream URL. Each project checks every archive against the SHA-256 pinned in its own repository, so the mirror is a convenience, not a trust anchor.

To add archives, pin the version, upstream URL and SHA-256 in the project, then upload any missing files to the `sources` release. In Chiaki-ng for macOS, `make mirror-deps` does this.

Each archive keeps its own upstream licence; see the licence files inside it.
