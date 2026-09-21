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

# Released from main, and nowhere else.  Another session once had its own
# branch checked out in this same working tree; the release commit landed on
# that branch, "git push origin main" pushed a stale main - a silent no-op that
# exited 0 - and 0.3.1 to 0.3.3 went out as tags and release pages while the
# appcast every copy reads still said 0.3.
if [ "$(git branch --show-current)" != "main" ]; then
    echo "not on main (on '$(git branch --show-current)'): refusing to release" >&2
    exit 1
fi
cd "$(dirname "$0")/.."

host=${1:-g4}
key=${GARDEN_RELEASE_KEY:-$HOME/.config/thegarden/release-key.pem}
repo=$(git config --get remote.origin.url | sed -e 's#.*github.com[:/]##' -e 's#\.git$##')
version=$(sed -n 's/^VERSION  *= *//p' Makefile)
build=$(sed -n 's/^BUILD_NUMBER  *= *//p' Makefile)
stage=$(sed -n 's/^STAGE  *= *//p' Makefile)
# What people read: "0.3.4 Alpha".  The tag and the zip keep the bare number.
label="$version${stage:+ $stage}"
tag="v$version"
zip="TheGarden-$version.zip"

[ -f "$key" ] || { echo "no release key at $key (see the notes at the top)" >&2; exit 1; }
[ -n "$version" ] && [ -n "$build" ] || { echo "cannot read VERSION/BUILD_NUMBER from the Makefile" >&2; exit 1; }
if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "$tag already exists: raise VERSION and BUILD_NUMBER in the Makefile first" >&2
    exit 1
fi

echo "==> building $label (build $build) on $host"
scripts/remote-build.sh "$host" app >/dev/null

# Zipped on the Mac that built it, with -y so the symbolic links inside the
# frameworks stay links.  The app unpacks its own update with the XADMaster it
# bundles, which restores them; ditto's zips are not readable across these
# systems.
echo "==> packing $zip"
mkdir -p build
rm -f "build/$zip"
remote_md5=$(ssh "$host" "cd TheGarden/build && rm -f '$zip' && zip -q -r -y '$zip' 'The Garden.app' && md5 -q '$zip'")
# scp rather than ssh-and-cat: the cat once arrived as 2.9 MB of a 6.8 MB zip,
# with nothing to say so.  Then prove it: same MD5 as the Mac that made it,
# and it unpacks.  A truncated release would be signed as though it were whole.
scp -q "$host:TheGarden/build/$zip" "build/$zip"
[ "$(md5 -q "build/$zip")" = "$remote_md5" ] || { echo "the zip did not arrive intact" >&2; exit 1; }
unzip -tq "build/$zip" >/dev/null || { echo "the zip does not unpack" >&2; exit 1; }
[ -s "build/$zip" ] || { echo "the zip came back empty" >&2; exit 1; }

size=$(wc -c < "build/$zip" | tr -d ' ')
sha=$(openssl dgst -sha256 -hex "build/$zip" | sed 's/.*= *//')
url="https://github.com/$repo/releases/download/$tag/$zip"

# What the app verifies: the version bound to this file and to where it comes
# from, so a signature cannot be moved to another download.
statement="TheGarden-update-1
version=$label
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
notes=${GARDEN_RELEASE_NOTES:-"The Garden $label."}
cat > updates.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>version</key>
	<string>$label</string>
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
git commit -q -m "The Garden $label" || true
git tag "$tag"
git push origin HEAD:main "$tag"
if [ "$(git ls-remote origin main | cut -f1)" != "$(git rev-parse HEAD)" ]; then
    echo "pushed, but origin/main is not this commit: the appcast was NOT published" >&2
    exit 1
fi
gh release create "$tag" "build/$zip" --repo "$repo" --title "The Garden $version${stage:+ ($stage)}" --notes "$notes"

# The release page is not the release.  Every copy of the app reads the
# appcast, so wait until that is the new build - the CDN holds it a few
# minutes - or say plainly that it is not.
echo "==> waiting for the served appcast to show build $build"
served=""
for i in $(seq 1 40); do
    served=$(curl -s "https://raw.githubusercontent.com/$repo/main/updates.plist?cb=$i" |
             sed -n '/<key>build<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}')
    [ "$served" = "$build" ] && break
    sleep 15
done
[ "$served" = "$build" ] || echo "WARNING: the appcast is still serving build '$served', not $build" >&2

echo "==> $label published"
echo "    $url"
echo "    sha256 $sha"
