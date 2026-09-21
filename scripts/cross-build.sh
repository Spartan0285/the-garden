#!/bin/sh
# Build The Garden, Universal, on a modern Mac: both halves are compiled by the
# GCC 6.5 cross compilers in the build VM, instead of Apple's gcc-4.0 on a
# PowerPC Mac.
#
#   scripts/cross-build.sh [make targets]          (default: app)
#
# Needs the VM `ppcbuild` on BUILD_MAC (default mbp) with the PowerPC compiler
# (Captain Polliwog's scripts/toolchain/build-ppc-toolchain.sh) and the Intel one
# (scripts/toolchain/build-i386-toolchain.sh), and ~/polliwog-deps/{ppc,i386} on
# that Mac.  The finished app is copied back to build/ here.
#
# Only ~/polliwog-build is writable from inside the VM, so the sources go there.
set -e
cd "$(dirname "$0")/.."
BUILD_MAC=${BUILD_MAC:-mbp}
VM=${VM:-ppcbuild}
LIMACTL=${LIMACTL:-\$HOME/lima/bin/limactl}
SRC=polliwog-build/garden          # under the build Mac's home, and the VM's
targets=${*:-app}

echo "==> syncing to $BUILD_MAC:~/$SRC"
rsync -a --delete --exclude .git --exclude build/ ./ "$BUILD_MAC:$SRC/"

# The VM sees the Mac's home at the same path, so the SDK and dependency
# paths below are the ones the VM uses.
#
# -static-libgcc: by default GCC links its own libgcc_s.1.dylib, from a path
# that exists only inside this VM, so the app would not even launch on a real
# Mac ("Library not loaded").  Statically, it depends on nothing but the system.
# -fobjc-exceptions: Apple's gcc turns @try/@catch on by default, FSF GCC does not.
# -no_compact_unwind for i386: a 10.6 format that Tiger and Leopard never read.
LINKFLAGS="-mmacosx-version-min=10.4 -static-libgcc -fobjc-exceptions"
echo "==> building ($targets) in $VM"
ssh "$BUILD_MAC" "$LIMACTL shell $VM -- bash -c 'cd /Users/adam/$SRC && make $targets \
    CC_ppc=\"/opt/ppc/bin/powerpc-apple-darwin9-gcc $LINKFLAGS\" \
    CC_i386=\"/opt/i386/bin/i386-apple-darwin9-gcc $LINKFLAGS -Wl,-no_compact_unwind\" \
    LIPO=/opt/ppc/bin/powerpc-apple-darwin9-lipo \
    DITTO=\"cp -a\" \
    SDK=/opt/ppc/SDKs/MacOSX10.5.sdk \
    DEPS_ROOT=/Users/adam/polliwog-deps \
    CFLAGS_ppc=\"-mcpu=750 -mtune=7450\" \
    CFLAGS_i386=\"-march=prescott\"'"

# Back to this Mac.  ditto on the build Mac, which keeps the frameworks'
# symbolic links; checked by MD5 on arrival, because a transfer here has
# arrived short before without saying so.
echo "==> fetching the app"
sum=$(ssh "$BUILD_MAC" "cd $SRC/build && rm -f cross.cpgz && ditto -c -z --keepParent 'The Garden.app' cross.cpgz && md5 -q cross.cpgz")
mkdir -p build && rm -rf "build/The Garden.app"
scp -q "$BUILD_MAC:$SRC/build/cross.cpgz" build/cross.cpgz
[ "$(md5 -q build/cross.cpgz)" = "$sum" ] || { echo "the app did not arrive intact" >&2; exit 1; }
ditto -x -z build/cross.cpgz build/
# file, not lipo: a current Mac's lipo no longer knows PowerPC and calls that
# half "unknown".
echo "==> build/The Garden.app:"
file -b "build/The Garden.app/Contents/MacOS/TheGarden" | sed 's/^/    /' 
