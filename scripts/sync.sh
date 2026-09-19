#!/bin/sh
# Copies the sources to a PowerPC Mac, replacing only files whose contents
# changed and giving those the Mac's own time (the G3/G4 clocks drift, so
# copied timestamps can make make(1) skip an edit).
#   Usage: scripts/sync.sh host
set -e
cd "$(dirname "$0")/.."
host=${1:?usage: sync.sh host}
REMOTE_DIR=TheGarden

ZIP=$(mktemp /tmp/garden-sync.XXXXXX)
rm -f "$ZIP"; ZIP="$ZIP.zip"
trap 'rm -f "$ZIP"' EXIT
# -y keeps the frameworks' symlinks; zip only allows it when writing a file.
zip -q -r -X -y "$ZIP" Makefile src tools Resources scripts vendor -x '*.DS_Store'
cat "$ZIP" |
    ssh -o ConnectTimeout=90 "$host" "
        rm -rf /tmp/garden-sync && mkdir -p /tmp/garden-sync $REMOTE_DIR &&
        cd /tmp/garden-sync && cat > sources.zip && unzip -qo sources.zip && rm sources.zip &&
        [ -f Makefile ] || { echo 'sync: empty archive, nothing changed' >&2; exit 1; }
        changed=0
        find . -type l | while read f; do
            t=\"\$HOME/$REMOTE_DIR/\$f\"
            if [ \"\`readlink \"\$f\"\`\" != \"\`readlink \"\$t\" 2>/dev/null\`\" ]; then
                mkdir -p \"\`dirname \"\$t\"\`\"; rm -rf \"\$t\"; ln -s \"\`readlink \"\$f\"\`\" \"\$t\"
            fi
        done
        IFS='
'
        for f in \`find . -type f\`; do
            if ! cmp -s \"\$f\" \"\$HOME/$REMOTE_DIR/\$f\"; then
                mkdir -p \"\$HOME/$REMOTE_DIR/\`dirname \$f\`\"
                cat \"\$f\" > \"\$HOME/$REMOTE_DIR/\$f\"
                changed=\$((changed + 1))
            fi
        done
        [ -f /tmp/garden-sync/Makefile ] && [ -d /tmp/garden-sync/src ] &&
        for f in \`cd \$HOME/$REMOTE_DIR && find src tools -type f\`; do
            [ -e \"/tmp/garden-sync/\$f\" ] || { rm -f \"\$HOME/$REMOTE_DIR/\$f\"; echo \"removed \$f\"; }
        done
        chmod +x \$HOME/$REMOTE_DIR/scripts/*.sh
        rm -rf /tmp/garden-sync
        echo \"==> $host: \$changed files updated\""
