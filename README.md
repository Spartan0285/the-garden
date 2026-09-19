# The Garden

A Mac App Store-style client for [Macintosh Garden](https://macintoshgarden.org),
native on Mac OS X 10.4 Tiger and 10.5 Leopard, Universal (PowerPC G3 and
later, and Intel). It browses, searches, downloads and installs by itself -
no helper on another machine.

- **Store:** Featured, Apps, Games (A-Z), Categories, Search; item pages with
  screenshots, ratings, every download and a compatibility badge for this Mac
  (runs natively, via Rosetta, in Classic, or not at all).
- **Get:** downloads over modern TLS (static libcurl 8 + OpenSSL 3; Tiger's
  own TLS stops at 1.0), resumes interrupted downloads, prefers fast mirrors,
  checks the Garden's MD5, then unpacks and installs: disk images via hdiutil,
  archives (StuffIt, BinHex, MacBinary, Compact Pro, zip, ...) via the bundled
  XADMaster; apps go to /Applications, Mac OS 9 software to
  "Applications (Mac OS 9)", installer packages open in Installer.
- **Library:** downloads and installed titles, Open / Show in Finder / Move to
  Trash / View in Store.

## Building

Builds on a PowerPC Mac with Xcode 2.5 (Tiger) or 3.1 (Leopard) and the 10.4u
SDK, against static libcurl/OpenSSL/zlib in `~/polliwog-deps/{ppc,i386}` (from
Captain Polliwog's `scripts/build-deps.sh`).

    scripts/remote-build.sh g4 app                  # sync + build on host g4
    scripts/remote-run.sh g3 /apps/the-unarchiver   # deploy, open a page, snapshot

`make ARCHS=ppc` builds PowerPC only. `tools/gdtool` exercises the site client
from the command line (list / item / search / get).

## Third-party code

`vendor/XADMaster.framework` and `vendor/UniversalDetector.framework` are the
unmodified Universal builds shipped with The Unarchiver 3.11.1 (LGPL-2.1); see
`Resources/Acknowledgements.txt`.
