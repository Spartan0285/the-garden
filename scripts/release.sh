#!/bin/sh
# Publish a release of The Garden, and the appcast the app checks.
#
#   scripts/release.sh [build-host]        (default: g4)
#
# Builds the Universal app on a PowerPC Mac, zips it, signs the release with
# the Ed25519 key in ~/.config/thegarden/release-key.pem, writes updates.plist
# and uploads the zip to a GitHub release.  The version and the build number
# come from the Makefile; raise both there before running this.
#
# The private key is never in this repository.  To make one:
#   mkdir -p ~/.config/thegarden && chmod 700 ~/.config/thegarden
#   openssl genpkey -algorithm ed25519 -out ~/.config/thegarden/release-key.pem
#   chmod 600 ~/.config/thegarden/release-key.pem
# and put its public half in GDReleasePublicKey in src/GDSelfUpdate.m:
#   openssl pkey -in ~/.config/thegarden/release-key.pem -pubout -outform DER |
#       tail -c 32 | base64
set -e
cd "$(dirname "$0")/.."

host=${1:-g4}
key=${GARDEN_RELEASE_KEY:-$HOME/.config/thegarden/release-key.pem}
repo=$(git config --get remote.origin.url | sed -e 's#.*github.com[:/]##' -e 's#\.git$##')
version=$(sed -n 's/^VERSION  *= *//p' Makefile)
build=$(sed -n 's/^BUILD_NUMBER  *= *//p' Makefile)
tag="v$version"
zip="TheGarden-$version.zip"

[ -f "$key" ] || { echo "no release key at $key (see the notes at the top)" >&2; exit 1; }
[ -n "$version" ] && [ -n "$build" ] || { echo "cannot read VERSION/BUILD_NUMBER from the Makefile" >&2; exit 1; }
if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "$tag already exists: raise VERSION and BUILD_NUMBER in the Makefile first" >&2
    exit 1
fi

echo "==> building $version (build $build) on $host"
scripts/remote-build.sh "$host" app >/dev/null

# Zipped on the Mac that built it, with -y so the symbolic links inside the
# frameworks stay links.  The app unpacks its own update with the XADMaster it
# bundles, which restores them; ditto's zips are not readable across these
# systems.
echo "==> packing $zip"
mkdir -p build
rm -f "build/$zip"
ssh "$host" "cd TheGarden/build && rm -f '$zip' && zip -q -r -y '$zip' 'The Garden.app' && cat '$zip'" > "build/$zip"
[ -s "build/$zip" ] || { echo "the zip came back empty" >&2; exit 1; }

size=$(wc -c < "build/$zip" | tr -d ' ')
sha=$(openssl dgst -sha256 -hex "build/$zip" | sed 's/.*= *//')
url="https://github.com/$repo/releases/download/$tag/$zip"

# What the app verifies: the version bound to this file and to where it comes
# from, so a signature cannot be moved to another download.
statement="TheGarden-update-1
version=$version
build=$build
sha256=$sha
size=$size
url=$url
"
statement_file=$(mktemp /tmp/garden-release.XXXXXX)
printf '%s' "$statement" > "$statement_file"
signature=$(openssl pkeyutl -sign -inkey "$key" -rawin -in "$statement_file" | base64 | tr -d '\n')
rm -f "$statement_file"

echo "==> writing updates.plist"
notes=${GARDEN_RELEASE_NOTES:-"The Garden $version."}
cat > updates.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>version</key>
	<string>$version</string>
	<key>build</key>
	<string>$build</string>
	<key>url</key>
	<string>$url</string>
	<key>sha256</key>
	<string>$sha</string>
	<key>size</key>
	<string>$size</string>
	<key>minimumSystemVersion</key>
	<string>10.4</string>
	<key>notes</key>
	<string>$notes</string>
	<key>signature</key>
	<string>$signature</string>
</dict>
</plist>
PLIST

echo "==> tagging and uploading"
git add updates.plist
git commit -q -m "The Garden $version" || true
git tag "$tag"
git push -q origin main "$tag"
gh release create "$tag" "build/$zip" --repo "$repo" --title "The Garden $version" --notes "$notes"

echo "==> $version published"
echo "    $url"
echo "    sha256 $sha"
