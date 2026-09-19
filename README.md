# The Garden

A Mac App Store-style client for [Macintosh Garden](https://macintoshgarden.org),
native on Mac OS X 10.4 Tiger and 10.5 Leopard, Universal (PowerPC G3 and
later, and Intel). It browses, searches, downloads and installs by itself -
no helper on another machine.

- **Store:** Featured (with New & Noteworthy from the site's feed), Apps and
  Games (A-Z), Categories, Search. Item pages have screenshots, the rating,
  reviews (the site's comments), every download with a compatibility badge
  for this Mac (natively, via Rosetta, in Classic, or not at all), and rows of
  "More by <author>" and "Related" titles.
- **Get:** downloads over modern TLS (static libcurl 8 + OpenSSL 3; Tiger's
  own TLS stops at 1.0), resumes interrupted downloads, prefers fast mirrors,
  checks the Garden's MD5, then unpacks and installs: disk images via hdiutil,
  archives (StuffIt, BinHex, MacBinary, Compact Pro, zip, ...) via the bundled
  XADMaster; apps go to /Applications, Mac OS 9 software to
  "Applications (Mac OS 9)", installer packages open in Installer.
- **Library:** downloads and installed titles with their real icons: Open,
  Add to Dock, Show in Finder, Move to Trash, View in Store.
- **Updates:** installed titles for which the Garden has a newer file of the
  same kind (same variant, higher version); Update installs it and moves the
  old copy to the Trash. The count shows on the tab and the Dock icon, which
  also shows download progress.
- **Light on the site:** pages are cached on disk (item pages 3 days,
  listings 6 hours, the feed 1 hour) and shown offline when the network is
  down. The Garden only fetches what you open; the site's robots.txt asks
  crawlers not to index it, so there is no catalog crawl.

## Building

Builds on a PowerPC Mac with Xcode 2.5 (Tiger) or 3.1 (Leopard) and the 10.4u
SDK, against static libcurl/OpenSSL/zlib in `~/polliwog-deps/{ppc,i386}` (from
Captain Polliwog's `scripts/build-deps.sh`).

    scripts/remote-build.sh g4 app                  # sync + build on host g4
    scripts/remote-run.sh g3 /apps/the-unarchiver   # deploy, open a page, snapshot

`make ARCHS=ppc` builds PowerPC only. `tools/gdtool` exercises the site client
from the command line (list / item / search / get).

## License

MIT (see `LICENSE`). Third-party components and their licenses are listed in
`THIRD-PARTY-NOTICES.md`.

## Third-party code

`vendor/XADMaster.framework` and `vendor/UniversalDetector.framework` are the
unmodified Universal builds shipped with The Unarchiver 3.11.1 (LGPL-2.1); see
`Resources/Acknowledgements.txt`.
