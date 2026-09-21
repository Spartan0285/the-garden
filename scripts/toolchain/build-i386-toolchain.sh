#!/bin/sh
# Adds an Intel (i386) Mac OS X cross compiler beside the PowerPC one in the
# build VM, so The Garden's Universal binary can be built on a modern Mac.
#
#   scripts/toolchain/build-i386-toolchain.sh          (from this Mac)
#
# The VM is Captain Polliwog's `ppcbuild` (scripts/toolchain/build-ppc-toolchain.sh
# in that repository), running on the Mac named by BUILD_MAC (default mbp).
# Nothing here touches the PowerPC toolchain: the compiler goes in /opt/i386,
# and it borrows the cctools already in /opt/ppc, which were built multi-arch -
# /opt/ppc/libexec/as/ has an i386 assembler, ld64 links i386, and the SDKs in
# /opt/ppc/SDKs are Universal.  So only GCC is built.
#
# GCC 6.5, as for PowerPC, so both halves of the app come from one compiler.
#
# It runs detached inside the VM and is polled from here: a build this long
# should not die with an SSH connection, and on this network they do drop.
set -e
BUILD_MAC=${BUILD_MAC:-mbp}
VM=${VM:-ppcbuild}
LIMACTL=${LIMACTL:-\$HOME/lima/bin/limactl}

echo "==> installing the build script in $VM on $BUILD_MAC"
ssh "$BUILD_MAC" "$LIMACTL shell $VM -- bash -c 'cat > ~/src/build-i386.sh'" <<'VMSCRIPT'
#!/bin/bash
set -e
cd ~/src
P=/opt/ppc/bin/powerpc-apple-darwin9      # the multi-arch cctools
T=i386-apple-darwin9
PREFIX=/opt/i386
SDK=/opt/ppc/SDKs/MacOSX10.5.sdk          # ld64-253 cannot read 10.4u's crt1.o

sudo mkdir -p $PREFIX/bin $PREFIX/$T/bin

# The cctools under i386 names.  Scripts rather than symlinks: the `as` driver
# finds its per-architecture assemblers relative to where it really lives.
for tool in ar as ld nm ranlib lipo strip otool install_name_tool libtool; do
    printf '#!/bin/sh\nexec %s-%s "$@"\n' "$P" "$tool" | sudo tee $PREFIX/bin/$T-$tool >/dev/null
    sudo cp $PREFIX/bin/$T-$tool $PREFIX/$T/bin/$tool
done
# collect2 runs dsymutil after linking, and there is none on Linux.
printf '#!/bin/sh\nexit 0\n' | sudo tee $PREFIX/bin/$T-dsymutil >/dev/null
sudo cp $PREFIX/bin/$T-dsymutil $PREFIX/$T/bin/dsymutil
sudo chmod +x $PREFIX/bin/* $PREFIX/$T/bin/*

# The same GCC 6.5 source the PowerPC compiler was built from.  Its one patch
# (PR88343, the PowerPC PIC base) only touches rs6000 code.
[ -d gcc-6.5.0 ] || {
    wget -q https://ftp.gnu.org/gnu/gcc/gcc-6.5.0/gcc-6.5.0.tar.xz
    echo "7ef1796ce497e89479183702635b14bb7a46b53249209a5e0f999bebf4740945  gcc-6.5.0.tar.xz" | sha256sum -c
    tar -xJf gcc-6.5.0.tar.xz
}

export PATH=$PREFIX/bin:$PATH
rm -rf build-gcc-i386 && mkdir build-gcc-i386 && cd build-gcc-i386
# -march=prescott: every Intel Mac has SSE3, and it is what the Makefile asks
# for.  The x86-only runtimes (quadmath, MPX, VTV) are off: nothing here needs
# them, and they are the likeliest parts not to build for Darwin.
../gcc-6.5.0/configure --target=$T --prefix=$PREFIX \
    --with-sysroot=$SDK \
    --with-as=$PREFIX/bin/$T-as --with-ld=$PREFIX/bin/$T-ld \
    --enable-languages=c,c++,objc,obj-c++ --disable-multilib --disable-nls --disable-bootstrap \
    --disable-libsanitizer --disable-libcilkrts --disable-libgomp --disable-libitm \
    --disable-libquadmath --disable-libssp --disable-libvtv --disable-libmpx \
    --with-dwarf2 --with-arch=prescott \
    AR_FOR_TARGET=$PREFIX/bin/$T-ar NM_FOR_TARGET=$PREFIX/bin/$T-nm \
    RANLIB_FOR_TARGET=$PREFIX/bin/$T-ranlib LIPO_FOR_TARGET=$PREFIX/bin/$T-lipo \
    STRIP_FOR_TARGET=$PREFIX/bin/$T-strip \
    CFLAGS="-O2 -g0" CXXFLAGS="-O2 -g0 -std=gnu++98" \
    CFLAGS_FOR_TARGET="-O2 -g0 -mmacosx-version-min=10.4" \
    CXXFLAGS_FOR_TARGET="-O2 -g0 -mmacosx-version-min=10.4" \
    LDFLAGS_FOR_TARGET="-Wl,-no_compact_unwind"
# -no_compact_unwind: ld64 writes "compact unwind" tables by default, a format
# that arrived in 10.6 - Tiger and Leopard only read the DWARF ones.  On i386
# it is also what stopped the first build: libstdc++ has more personality
# routines than compact unwind can encode.  (ld64 writes none for PowerPC,
# which is why the PowerPC compiler never met it.)
make -j10
sudo env PATH=$PATH make install
cd ~/src

# Prove it: C, Objective-C against Foundation, and a Universal binary with the
# PowerPC compiler's output.
cat > /tmp/hello.c <<'C'
#include <stdio.h>
int main(void) { puts("hello"); return 0; }
C
cat > /tmp/hello.m <<'M'
#import <Foundation/Foundation.h>
int main(void) {
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    NSLog(@"hello from %@", [[NSProcessInfo processInfo] processName]);
    [p release];
    return 0;
}
M
# -static-libgcc: without it GCC links its libgcc_s.1.dylib from a path that
# exists only in this VM, and the program would not launch on a real Mac.  The
# first version of this test checked only the file type and passed exactly
# that; it now fails on any library a Mac would not have.
F="-isysroot $SDK -mmacosx-version-min=10.4 -static-libgcc"
$PREFIX/bin/$T-gcc $F /tmp/hello.c -o /tmp/hello-i386
$PREFIX/bin/$T-gcc $F /tmp/hello.m -framework Foundation -o /tmp/hellom-i386
/opt/ppc/bin/powerpc-apple-darwin9-gcc $F /tmp/hello.m -framework Foundation -o /tmp/hellom-ppc
$P-lipo -create /tmp/hellom-ppc /tmp/hellom-i386 -output /tmp/hellom-universal
for b in /tmp/hello-i386 /tmp/hellom-i386 /tmp/hellom-ppc; do
    stray=$($P-otool -L "$b" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib|/System)/' || true)
    [ -z "$stray" ] || { echo "$b needs a library no Mac has: $stray"; exit 1; }
done
echo "== C:           $(file -b /tmp/hello-i386)"
echo "== Objective-C: $(file -b /tmp/hellom-i386)"
echo "== Universal:   $($P-lipo -info /tmp/hellom-universal | sed 's/.*: //')"
echo "== Loads only:  $($P-otool -L /tmp/hellom-i386 | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
$PREFIX/bin/$T-gcc --version | head -1
echo I386_TOOLCHAIN_DONE
VMSCRIPT

echo "==> building GCC 6.5 for i386, detached (about 25 minutes)"
ssh "$BUILD_MAC" "$LIMACTL shell $VM -- bash -c 'cd ~/src && (setsid nohup bash build-i386.sh > i386-toolchain.log 2>&1 || echo I386_TOOLCHAIN_FAILED >> i386-toolchain.log) >/dev/null 2>&1 &'"

# Poll.  A dropped connection costs a poll, not the build.
while :; do
    sleep 60
    # bash -c, so that ~ is the VM's home: bare, it expanded on the Mac to
    # /Users/adam, and the first version of this loop polled a file that did
    # not exist, forever, while the build had already failed.
    tail=$(ssh -o ConnectTimeout=15 "$BUILD_MAC" \
        "$LIMACTL shell $VM -- bash -c 'tail -3 ~/src/i386-toolchain.log'" 2>/dev/null) || continue
    case "$tail" in
    *I386_TOOLCHAIN_DONE*)   echo "$tail"; echo "==> done"; exit 0 ;;
    *I386_TOOLCHAIN_FAILED*) echo "$tail"; echo "==> FAILED - see ~/src/i386-toolchain.log in $VM" >&2; exit 1 ;;
    esac
    echo "    ... $(echo "$tail" | tail -1 | cut -c1-90)"
done
