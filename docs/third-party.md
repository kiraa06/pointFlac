# Third-party code

## libFLAC 1.5.0

- Location: `Packages/PointFlacKit/Sources/CFLAC/` (vendored source target `CFLAC`)
- Upstream: https://github.com/xiph/flac, release 1.5.0
- Tarball: `https://github.com/xiph/flac/releases/download/1.5.0/flac-1.5.0.tar.xz`
- SHA-256 of tarball: `f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920`
- Licence: Xiph BSD-3-Clause (`Packages/PointFlacKit/Sources/CFLAC/COPYING.Xiph`)
- Modifications: none to upstream files. Added by pointFlac: `config.h`, `include/CFLAC.h`, `include/module.modulemap`.
- Left out: `ogg_*.c` (no Ogg support), `windows_unicode_filenames.c`, the encoder-side tools, the GPL/LGPL parts of the tarball.
