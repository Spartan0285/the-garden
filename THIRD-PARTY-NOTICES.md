# Third-party software in The Garden

The Garden itself is MIT licensed (see `LICENSE`). The app ships or links the
following; their full license texts are in `Resources/Licenses/` and are copied
into `The Garden.app/Contents/Resources/Licenses/`.

| Component | Version | How it is used | License |
|---|---|---|---|
| [XADMaster](https://github.com/MacPaw/XADMaster) | from The Unarchiver 3.11.1 | Dynamic framework, unmodified, in `Contents/Frameworks` | LGPL-2.1 |
| [UniversalDetector](https://github.com/MacPaw/universal-detector) | from The Unarchiver 3.11.1 | Dynamic framework, unmodified, in `Contents/Frameworks` | LGPL-2.1 |
| [libcurl](https://curl.se) | 8.22.0 | Statically linked | curl license (MIT-style) |
| [OpenSSL](https://www.openssl.org) | 3.5.8 | Statically linked | Apache-2.0 |
| [zlib](https://zlib.net) | 1.3.2 | Statically linked | zlib license |
| [Mozilla CA certificate list](https://curl.se/docs/caextract.html) | 2026-08-13 extract | `cacert.pem`, data | MPL-2.0 |

The LGPL frameworks are dynamic libraries loaded from `Contents/Frameworks`;
you may replace them with your own builds of the same frameworks (source:
https://github.com/MacPaw/XADMaster, https://github.com/MacPaw/universal-detector).

Software, pictures and descriptions shown in the app come from the Macintosh
Garden (https://macintoshgarden.org) and belong to their respective owners;
The Garden does not redistribute them.
