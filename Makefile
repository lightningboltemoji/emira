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

.PHONY: build test clean app icon zip dist install uninstall print-version
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
# The onboarding window's wordmark rides in as SwiftPM's resource bundle for the `EmiraShell` target
# rather than as a loose file, so `Bundle.module` resolves both here and in a bare `swift build` tree.
# A missing bundle is a `fatalError` in SwiftPM's generated accessor, so the `cp` must fail the build.
#
# The nested CLI is signed *before* the app: signing a bundle seals its `Contents` into
# `CodeResources`, so nested *code* signed afterwards would invalidate the outer signature.
#
# **The resource bundle is not signed at all**, and must not be. It holds one WebP and no code, so the
# outer seal already covers it — `logo.webp` appears in the app's own `CodeResources` either way, and
# `codesign --verify --deep --strict` passes with the nested bundle unsigned. Signing it is also not
# portable: whether SwiftPM gives that bundle a `Contents/Info.plist` or lays it out flat depends on
# the toolchain, and `codesign` rejects the flat form outright — "bundle format unrecognized, invalid,
# or unsuitable" — so a build that signed it would pass here and fail on an older Xcode.
APP_NAME := emira
DIST     := dist
BUNDLE   := $(DIST)/$(APP_NAME).app
CONTENTS := $(BUNDLE)/Contents
RELEASE  := .build/release
# SwiftPM's name for a target's resources: <package>_<target>.bundle.
RESOURCE_BUNDLE := Emira_EmiraShell.bundle

CODESIGN_IDENTITY ?= -
ifeq ($(CODESIGN_IDENTITY),-)
  SIGN_FLAGS :=
else
  SIGN_FLAGS := --options runtime --timestamp
endif

# --- The app icon --------------------------------------------------------------------------------
# `Resources/emira.icon` is the source: three layer SVGs and the `icon.json` that composes them.
# macOS 26 does not read that directly — `actool` compiles it into an `Assets.car`, and
# `CFBundleIconName` names the icon inside. There is no legacy `.icns` alongside it because
# `LSMinimumSystemVersion` is 26.0: every system that can run emira reads the compiled form.
#
# **`actool` lives in Xcode, not the Command Line Tools**, so a CLT-only machine cannot compile the
# icon at all. That is not worth failing a build over — a bundle without an icon runs exactly as
# well, and the release runners have Xcode — so this compiles the icon when it can and says so when
# it cannot. `xcrun --find` is the probe: `/usr/bin/actool` exists either way and only errors when
# asked to do something.
#
# The partial plist actool insists on writing is a real output that we have no use for: it carries
# the icon name, which `Resources/Info.plist` already states. It goes to $(DIST) and is not copied.
#
# actool also always writes a legacy `$(APP_NAME).icns`, and that one is deleted. It is the icon a
# macOS older than 26 would read, which `LSMinimumSystemVersion` rules out — and it is not a fallback
# for a missing `Assets.car` either, since the same command produces both. Measured rather than
# assumed: with the `.icns` removed and the bundle re-signed, `NSWorkspace.icon(forFile:)` still
# returns emira's icon, so the 34 KB is only ever dead weight in the archive.
ICON   := Resources/$(APP_NAME).icon
ACTOOL := $(shell xcrun --find actool 2>/dev/null)

icon:
ifeq ($(ACTOOL),)
	@echo "warning: no actool — needs Xcode, not Command Line Tools. Bundle gets no icon."
else
	@$(ACTOOL) $(ICON) --compile $(CONTENTS)/Resources \
		--app-icon $(APP_NAME) --include-all-app-icons \
		--platform macosx --target-device mac \
		--minimum-deployment-target 26.0 --development-region en \
		--output-partial-info-plist $(DIST)/icon-partial.plist \
		--output-format human-readable-text --notices --warnings --errors
	@rm -f $(CONTENTS)/Resources/$(APP_NAME).icns
endif

app:
	swift build -c release $(QUIET)
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@$(MAKE) --no-print-directory icon
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	                        -c "Set :CFBundleVersion $(BUILD)" $(CONTENTS)/Info.plist
	cp $(RELEASE)/emira-daemon $(CONTENTS)/MacOS/emira-daemon
	cp $(RELEASE)/emira        $(CONTENTS)/MacOS/emira
	cp -R $(RELEASE)/$(RESOURCE_BUNDLE) $(CONTENTS)/Resources/$(RESOURCE_BUNDLE)
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
	@echo "installed /Applications/$(APP_NAME).app — launch it; it asks for the grants it needs"

uninstall:
	rm -rf /Applications/$(APP_NAME).app
