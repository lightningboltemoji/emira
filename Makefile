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

# --- Linker search-path noise -------------------------------------------------------------------
# The same CLT-only install makes SwiftPM pass `-F $(DEVDIR)/Developer/Library/Frameworks` (and a
# matching `-L .../Developer/usr/lib` for executable products) on every link. That subtree only
# exists inside Xcode.app, so ld warns once per target — ~10 lines that bury real diagnostics. The
# flags are SwiftPM's own, not ours: nothing in Package.swift can drop them, and nothing we link
# lives there, so the paths are pure noise.
#
# So filter, narrowly: only `search path ... not found` lines naming that one directory, and only on
# stderr. Every other diagnostic still passes through; `swift build` writes its progress to stdout,
# which is left alone so it keeps its tty (in-place progress line, colors); and a redirect — as
# opposed to a pipe — leaves the exit status intact, so a failed build still fails the target.
# Requires bash for `>(...)`; make's default /bin/sh would not do.
SHELL   := /bin/bash
LD_NOISE = ld: warning: search path '$(DEVDIR)/Developer/.*' not found
QUIET    = 2> >(grep -vE "$(LD_NOISE)" >&2)

.PHONY: build test clean app zip dist install uninstall print-version
build:
	swift build $(QUIET)

test:
	swift test $(TEST_FLAGS) $(QUIET)

clean:
	swift package clean
	rm -rf $(DIST)

# --- Version -------------------------------------------------------------------------------------
# The git tag is the only version authority; nothing in the tree carries a number. A tagged commit
# builds `0.2.0`, anything else builds what `git describe` says, and outside a checkout `0.0.0`.
# `app` stamps both keys into the bundle's *copy* of the plist, never the source. (IMPLEMENTATION §7.)
GIT_DESCRIBE := $(shell git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null)
VERSION      ?= $(if $(GIT_DESCRIBE),$(patsubst v%,%,$(GIT_DESCRIBE)),0.0.0)
BUILD        ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

print-version:
	@echo $(VERSION)

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
# **Signing defaults to ad-hoc (`--sign -`)**, which is enough to load and run locally. It is *not*
# enough for TCC to remember a grant across rebuilds: an ad-hoc signature is identified by its
# cdhash, which changes with every build, so macOS treats each build as a new app and re-asks for
# Accessibility. `CODESIGN_IDENTITY` overrides it with a Developer ID, which brings the hardened
# runtime and a secure timestamp with it — both of which notarization requires.
#
# The nested CLI is signed *before* the bundle: signing a bundle seals its `Contents` into
# `CodeResources`, so a nested executable signed afterwards would invalidate the outer signature.
APP_NAME := emira
DIST     := dist
BUNDLE   := $(DIST)/$(APP_NAME).app
CONTENTS := $(BUNDLE)/Contents
RELEASE  := .build/release

CODESIGN_IDENTITY ?= -
ifeq ($(CODESIGN_IDENTITY),-)
  SIGN_FLAGS :=
else
  SIGN_FLAGS := --options runtime --timestamp
endif

app:
	swift build -c release $(QUIET)
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	                        -c "Set :CFBundleVersion $(BUILD)" $(CONTENTS)/Info.plist
	cp $(RELEASE)/emira-daemon $(CONTENTS)/MacOS/emira-daemon
	cp $(RELEASE)/emira        $(CONTENTS)/MacOS/emira
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(SIGN_FLAGS) $(CONTENTS)/MacOS/emira
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(SIGN_FLAGS) $(BUNDLE)
	@echo "built $(BUNDLE) — version $(VERSION) ($(BUILD))"

# --- The release archive -------------------------------------------------------------------------
# `ditto`, not `zip`: a bundle carries symlinks, xattrs and a signature that plain zip mangles, and
# it is the format `notarytool` takes. `zip` does not depend on `app` because notarization runs
# between them and a re-sign would discard the stapled ticket — `make dist` is the ordinary path.
ZIP_NAME ?= $(APP_NAME)-$(VERSION).zip
ZIP      := $(DIST)/$(ZIP_NAME)

zip:
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP)

dist: app zip

# Into /Applications, because that is where the login item registration will point: SMAppService
# records the bundle's *path*, so registering from a build directory breaks the moment it is cleaned.
install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/$(APP_NAME).app — launch it, then grant Accessibility"

uninstall:
	rm -rf /Applications/$(APP_NAME).app
