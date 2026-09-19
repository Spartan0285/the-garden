#!/bin/sh
# Build the Universal app on a PowerPC Mac (Xcode 2.5/3.1, 10.4u SDK).
#   Usage: scripts/remote-build.sh [host] [make targets]   (default: g4)
set -e
cd "$(dirname "$0")/.."
host=${1:-g4}; shift 2>/dev/null || true
scripts/sync.sh "$host"
# Tiger's shells default to a 6MB data limit, which gcc exceeds on big files.
ssh -o ConnectTimeout=90 "$host" "ulimit -d unlimited 2>/dev/null || ulimit -d 262144; cd TheGarden && make $*"
