#!/bin/sh
# Copy the app built on the G4 to a test Mac, open a page, and fetch a PNG of
# the window (the app writes it itself once the page has settled).
#   Usage: scripts/remote-run.sh host [page] [extra defaults...]
#   page: featured (default) | apps | games | categories | library |
#         /apps/slug | search:words
#   host: g3, g4, pbg4 (192.168.68.151), tiger (the QEMU guest)
set -e
cd "$(dirname "$0")/.."
host=${1:?usage: remote-run.sh host [page]}
page=${2:-featured}
shift 2 2>/dev/null || shift $#
SSH="ssh -o ConnectTimeout=60"
SCP="scp -q -o ConnectTimeout=60"
case "$host" in
pbg4) SSH="$SSH -o HostName=192.168.68.151"; SCP="$SCP -o HostName=192.168.68.151" ;;
tiger) # the QEMU guest: key and legacy algorithms as in the QEMU project's gssh.sh
       K=${POWEREMU_GUEST_KEY:-$HOME/.ssh/poweremu_guest}
       OPTS="-i $K -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1 -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1"
       SSH="$SSH -p 2222 $OPTS"; SCP="$SCP -O -P 2222 $OPTS"
       host=adam@127.0.0.1 ;;
esac
mkdir -p build/screens
BUILDHOST=${BUILDHOST:-g4}     # where scripts/remote-build.sh ran
if [ "$host" != "$BUILDHOST" ]; then
    # cpio, not zip: Leopard's ditto writes broken zips around the
    # frameworks' symlinks, and Tiger's tools can't read its zips anyway.
    ssh $BUILDHOST 'cd TheGarden/build && rm -f TheGarden.cpgz && ditto -c -z --keepParent "The Garden.app" TheGarden.cpgz'
    scp -q $BUILDHOST:TheGarden/build/TheGarden.cpgz build/TheGarden.cpgz
    $SSH "$host" 'cat > /tmp/TheGarden.cpgz' < build/TheGarden.cpgz
    $SSH "$host" 'rm -rf "/tmp/gd/The Garden.app"; mkdir -p /tmp/gd && ditto -x -z /tmp/TheGarden.cpgz /tmp/gd'
    APP="/tmp/gd/The Garden.app"
else
    APP="TheGarden/build/The Garden.app"
fi
snap=/tmp/garden-snapshot.png
extra=""
for kv in "$@"; do extra="$extra defaults write org.macintoshgarden.store ${kv%%=*} '${kv#*=}';"; done
$SSH "$host" "
    killall TheGarden 2>/dev/null; sleep 1; rm -f $snap
    defaults write org.macintoshgarden.store GDDebugSnapshotPath $snap
    defaults write org.macintoshgarden.store GDDebugPage '$page'
    $extra
    open '$APP'
    i=0; while [ ! -f $snap ] && [ \$i -lt 300 ]; do sleep 2; i=\$((i + 2)); done
    for k in GDDebugSnapshotPath GDDebugPage GDDebugInstallFile GDDebugMinSeconds GDDebugQuit GDDebugScroll GDDebugDock; do
        defaults delete org.macintoshgarden.store \$k 2>/dev/null; done
    echo \"==> page settled after ~\${i}s\"
    ps -axww -o rss,command | awk '/MacOS\/[T]heGarden/ { printf \"==> memory %d MB\\n\", \$1 / 1024 }'
    true"
out="build/screens/$(echo "$1$host-$page" | tr '/: ' '___').png"
$SCP "$host:$snap" "$out" && echo "==> $out"
