# emira build entry points: the pure-Swift build + test loop, and the app bundle the daemon ships in.

# --- Swift Testing toolchain wiring -----------------------------------------------------------
# Under a full Xcode or a swift.org toolchain, `swift test` runs Swift Testing out of the box.
# A CommandLineTools-only install ships Testing.framework + libTestingMacros.dylib but doesn't
# wire them into SwiftPM's explicit-module test build, so we load the macro plugin and add the
# framework/interop rpaths explicitly. We detect that case by probing for the CLT plugin; when
# it's absent (i.e. Xcode is active) TEST_FLAGS stays empty and `swift test` runs unmodified.
DEVDIR          := $(shell xcode-select -p 2>/dev/null)
TESTING_PLUGIN  := $(DEVDIR)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
TESTING_FWK     := $(DEVDIR)/Library/Developer/Frameworks
TESTING_INTEROP := $(DEVDIR)/Library/Developer/usr/lib

ifeq ($(wildcard $(TESTING_PLUGIN)),)
  TEST_FLAGS :=
else
  TEST_FLAGS := -Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN) \
                -Xlinker -rpath -Xlinker $(TESTING_FWK) \
                -Xlinker -rpath -Xlinker $(TESTING_INTEROP)
endif

.PHONY: build test clean app install uninstall
build:
	swift build

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean
	rm -rf $(DIST)

# --- emira.app ---------------------------------------------------------------------------------
# The app *is* the daemon — one process, one bundle identity (see Resources/Info.plist). Assembled by
# hand rather than by Xcode because there is no GUI to build: SwiftPM produces the two executables and
# this copies them next to an Info.plist.
#
# **Both executables go in the bundle.** `emira-daemon` is `CFBundleExecutable`; `emira` (the CLI)
# rides along at `Contents/MacOS/emira` so there is exactly one copy of the wire protocol on the
# machine and no chance of a CLI and a daemon from different builds talking past each other. Nothing
# here puts it on `$PATH` — that is a Homebrew cask's `binary` stanza, or `make install-cli`.
#
# **Signing is ad-hoc (`--sign -`) for now**, which is enough to load and run locally. It is *not*
# enough for TCC to remember a grant across rebuilds: an ad-hoc signature is identified by its
# cdhash, which changes with every build, so macOS treats each build as a new app and re-asks for
# Accessibility. A stable Developer ID (plus `--options runtime` and notarization) is what fixes
# that, and it is deliberately deferred.
#
# The nested CLI is signed *before* the bundle: signing a bundle seals its `Contents` into
# `CodeResources`, so a nested executable signed afterwards would invalidate the outer signature.
APP_NAME := emira
DIST     := dist
BUNDLE   := $(DIST)/$(APP_NAME).app
CONTENTS := $(BUNDLE)/Contents
RELEASE  := .build/release

app:
	swift build -c release
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp $(RELEASE)/emira-daemon $(CONTENTS)/MacOS/emira-daemon
	cp $(RELEASE)/emira        $(CONTENTS)/MacOS/emira
	codesign --force --sign - $(CONTENTS)/MacOS/emira
	codesign --force --sign - $(BUNDLE)
	@echo "built $(BUNDLE)"

# Into /Applications, because that is where the login item registration will point: SMAppService
# records the bundle's *path*, so registering from a build directory breaks the moment it is cleaned.
install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/$(APP_NAME).app — launch it, then grant Accessibility"

uninstall:
	rm -rf /Applications/$(APP_NAME).app
