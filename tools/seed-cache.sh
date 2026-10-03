#!/bin/sh
# Put a page into a test Mac's page cache, as though the app had fetched it.
#
#   tools/seed-cache.sh ibook https://macintoshgarden.org/games/halo tools/fixtures/item-halo.html
#
# The app keeps pages in ~/Library/Caches/The Garden/Pages, named by the MD5
# of the URL, with a sibling ".h" plist holding the validators.  A copy
# younger than the page's TTL is used without touching the network, so a
# seeded page is what the app shows - which is how the item view can be worked
# on while the site is unreachable.
set -e
cd "$(dirname "$0")/.."
host=${1:?usage: seed-cache.sh host url file}
url=${2:?usage: seed-cache.sh host url file}
file=${3:?usage: seed-cache.sh host url file}

key=$(printf '%s' "$url" | md5 -q 2>/dev/null || printf '%s' "$url" | md5sum | cut -d' ' -f1)
dir='Library/Caches/The Garden/Pages'

ssh "$host" "mkdir -p '$dir'"
scp -q "$file" "$host:$dir/$key"
ssh "$host" "cat > '$dir/$key.h'" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>type</key>
	<string>text/html; charset=utf-8</string>
	<key>url</key>
	<string>$url</string>
</dict>
</plist>
PLIST
echo "==> seeded $url on $host ($key)"
