# The Garden - a Macintosh Garden store for Mac OS X 10.4 and 10.5.
# Universal (PowerPC G3+ and Intel) with the 10.4u SDK and Apple gcc-4.0,
# i.e. Xcode 2.5 on Tiger or Xcode 3.1 on Leopard (see scripts/remote-build.sh).

APP_NAME = The Garden
EXEC     = TheGarden
VERSION  = 0.3.3
# Alpha, Beta, or empty once it is neither.  Shown in the About window, the
# window title and every feedback report.
STAGE    = Alpha
# CFBundleVersion: a whole number, up by one each release.  The updater
# compares these, never the version people read.
BUILD_NUMBER = 10

SDK       ?= /Developer/SDKs/MacOSX10.4u.sdk
# Static OpenSSL 3 + libcurl 8 per architecture, as built for Captain Polliwog.
DEPS_ROOT ?= $(HOME)/polliwog-deps
ARCHS     ?= ppc i386
CC        = gcc-4.0
BUILD     = build
APP       = $(BUILD)/$(APP_NAME).app

export MACOSX_DEPLOYMENT_TARGET = 10.4

CORE    = src/GDHTTP.m src/GDGarden.m src/GDAccelerator.m
APPSRC  = $(filter-out $(CORE),$(wildcard src/*.m))
HEADERS = $(wildcard src/*.h)

# XADMaster (The Unarchiver's engine, LGPL) and UniversalDetector, Universal
# 10.4+ builds taken unmodified from The Unarchiver 3.11.1; bundled in
# Contents/Frameworks, where their @executable_path install names point.
VENDOR  = vendor
CFLAGS  = -isysroot $(SDK) -Os -Wall -Wno-unused-parameter -Isrc -I$(SDK)/usr/include/libxml2 -F$(VENDOR)
CFLAGS_ppc  = -mcpu=G3 -mtune=G4
CFLAGS_i386 = -march=prescott
LDBASE  = -isysroot $(SDK) -Wl,-syslibroot,$(SDK) -lxml2 -framework SystemConfiguration -framework CoreFoundation -framework Security -framework ApplicationServices
LDAPP   = $(LDBASE) -framework Cocoa -framework WebKit -F$(VENDOR) -framework XADMaster -framework UniversalDetector
LDTOOL  = $(LDBASE) -framework Foundation
DEPS_LIBS = libcurl.a libssl.a libcrypto.a libz.a

.PHONY: all app tool clean

# Must stay the first rule: make 3.80/3.81 take the first target as the default.
all: tool app

# Spelled out per architecture: make 3.80 on Tiger runs out of memory on the
# $(eval)/$(foreach) form.
CORE_ppc   = $(patsubst src/%.m,$(BUILD)/ppc/%.o,$(CORE))
CORE_i386  = $(patsubst src/%.m,$(BUILD)/i386/%.o,$(CORE))
APP_ppc    = $(patsubst src/%.m,$(BUILD)/ppc/%.o,$(APPSRC))
APP_i386   = $(patsubst src/%.m,$(BUILD)/i386/%.o,$(APPSRC))
DEPS_ppc   = $(patsubst %,$(DEPS_ROOT)/ppc/lib/%,$(DEPS_LIBS))
DEPS_i386  = $(patsubst %,$(DEPS_ROOT)/i386/lib/%,$(DEPS_LIBS))

$(BUILD)/ppc/%.o: src/%.m $(HEADERS)
	@mkdir -p $(BUILD)/ppc
	$(CC) -arch ppc $(CFLAGS) $(CFLAGS_ppc) -I$(DEPS_ROOT)/ppc/include -c $< -o $@

$(BUILD)/i386/%.o: src/%.m $(HEADERS)
	@mkdir -p $(BUILD)/i386
	$(CC) -arch i386 $(CFLAGS) $(CFLAGS_i386) -I$(DEPS_ROOT)/i386/include -c $< -o $@

$(BUILD)/ppc/gdtool.o: tools/gdtool.m $(HEADERS)
	@mkdir -p $(BUILD)/ppc
	$(CC) -arch ppc $(CFLAGS) $(CFLAGS_ppc) -I$(DEPS_ROOT)/ppc/include -c $< -o $@

$(BUILD)/i386/gdtool.o: tools/gdtool.m $(HEADERS)
	@mkdir -p $(BUILD)/i386
	$(CC) -arch i386 $(CFLAGS) $(CFLAGS_i386) -I$(DEPS_ROOT)/i386/include -c $< -o $@

# ---- command-line test tool
$(BUILD)/ppc/gdtool: $(BUILD)/ppc/gdtool.o $(CORE_ppc)
	$(CC) -arch ppc $^ $(DEPS_ppc) $(LDTOOL) -o $@

$(BUILD)/i386/gdtool: $(BUILD)/i386/gdtool.o $(CORE_i386)
	$(CC) -arch i386 $^ $(DEPS_i386) $(LDTOOL) -o $@

$(BUILD)/gdtool: $(patsubst %,$(BUILD)/%/gdtool,$(ARCHS))
	lipo -create $^ -output $@
	cp Resources/cacert.pem $(BUILD)/

tool: $(BUILD)/gdtool

# ---- the app
$(BUILD)/ppc/$(EXEC): $(APP_ppc) $(CORE_ppc)
	$(CC) -arch ppc $^ $(DEPS_ppc) $(LDAPP) -o $@

$(BUILD)/i386/$(EXEC): $(APP_i386) $(CORE_i386)
	$(CC) -arch i386 $^ $(DEPS_i386) $(LDAPP) -o $@

$(BUILD)/$(EXEC): $(patsubst %,$(BUILD)/%/$(EXEC),$(ARCHS))
	lipo -create $^ -output $@

app: $(BUILD)/$(EXEC) Resources/Info.plist Resources/cacert.pem
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp $(BUILD)/$(EXEC) "$(APP)/Contents/MacOS/$(EXEC)"
	@sed -e 's/@VERSION@/$(VERSION)/g' -e 's/@BUILD@/$(BUILD_NUMBER)/g' -e 's/@STAGE@/$(STAGE)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	@printf 'APPLGdnX' > "$(APP)/Contents/PkgInfo"
	@cp Resources/cacert.pem Resources/*.plist "$(APP)/Contents/Resources/" 2>/dev/null; true
	@rm -f "$(APP)/Contents/Resources/Info.plist"
	@cp Resources/*.icns Resources/*.txt "$(APP)/Contents/Resources/" 2>/dev/null; true
	@# Named, not Resources/*.png: the 1024px icon artwork stays out of the bundle.
	@cp Resources/cytruslogo.png "$(APP)/Contents/Resources/" 2>/dev/null; true
	@ditto Resources/Licenses "$(APP)/Contents/Resources/Licenses"
	@mkdir -p "$(APP)/Contents/Frameworks"
	@ditto $(VENDOR)/XADMaster.framework "$(APP)/Contents/Frameworks/XADMaster.framework"
	@ditto $(VENDOR)/UniversalDetector.framework "$(APP)/Contents/Frameworks/UniversalDetector.framework"
	@rm -rf "$(APP)/Contents/Frameworks/"*.framework/Versions/A/Headers "$(APP)/Contents/Frameworks/"*.framework/Headers
	@echo "Built $(APP) ($$(lipo -info $(BUILD)/$(EXEC) | sed 's/.*: //'))"

clean:
	rm -rf $(BUILD)
