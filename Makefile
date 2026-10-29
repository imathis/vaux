PROJECT := Vaux.xcodeproj
SCHEME  := Vaux

# xcodebuild needs Xcode, not the Command Line Tools: when xcode-select points
# at the tools and DEVELOPER_DIR isn't set, use Xcode (or Xcode-beta).
ifeq ($(DEVELOPER_DIR),)
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
export DEVELOPER_DIR := $(firstword $(wildcard /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer))
endif
endif

# Development builds sign automatically, as in Xcode: installing Vaux Camera
# needs a provisioning profile, which Xcode makes and keeps (sign in to Xcode
# with the team's Apple ID once).
TEAM := Q2573QH43F
SIGN := -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM)

# macOS replaces an installed system extension only when its version changes,
# and replacing it restarts it, which drops Vaux Camera from apps already
# open. So the extension's build number follows its own source (and build
# configuration): it changes only when the extension does.
camera_build = $(shell (cat CameraExtension/* Shared/*; echo $(1)) | cksum | cut -d' ' -f1)
DEBUG_BUILD := $(SIGN) VAUX_CAMERA_BUILD=$(call camera_build,Debug)

# Vaux Dev runs from /Applications: macOS installs system extensions only
# from there.
DEV_APP := /Applications/Vaux Dev.app

# Release: Developer ID-signed and notarized, zipped for GitHub releases and
# the Homebrew cask (imathis/homebrew-tap). Named by VAUX_RELEASE in project.yml.
RELEASE := $(shell awk -F'"' '/VAUX_RELEASE:/ {print $$2; exit}' project.yml)
RELEASE_APP := build/export/Vaux.app
DIST := dist
ZIP := $(DIST)/Vaux-$(RELEASE).zip
# The developer account's notarytool login, stored in the Keychain once with
# xcrun notarytool store-credentials notarytool-profile --apple-id <id> --team-id $(TEAM)
NOTARY_PROFILE ?= notarytool-profile
# Releases are archived, then exported for Developer ID (ExportOptions.plist):
# the export signs Vaux with the Developer ID profile that allows installing
# Vaux Camera. Xcode made that profile, distributing an archive once, and
# manages it, so it can't be named in a manual signing setup; the export
# finds it on disk without an Apple ID session.
ARCHIVE := build/Vaux.xcarchive

# Vaux's Stream Deck plugin (StreamDeck/), packed into build/ for Vaux to
# bundle. Stream Deck installs a plugin only over an older version, so it's
# major.minor.build.0 for a release, and each pack for Vaux Dev goes after
# that release, numbered by the minute (from 2026).
STREAMDECK_PLUGIN := build/dev.imathis.vaux.streamDeckPlugin
STREAMDECK_BASE := $(shell awk -F'"' '/MARKETING_VERSION:/ {split($$2, v, "."); m=v[1]"."v[2]} /CURRENT_PROJECT_VERSION:/ {b=$$2} END {print m"."b}' project.yml)
STREAMDECK_VERSION = $(STREAMDECK_BASE).$(shell echo $$(( ($$(date +%s) - 1767225600) / 60 )))
release: STREAMDECK_VERSION = $(STREAMDECK_BASE).0

.PHONY: gen open check build run snapshot snapshot-live status logs clean release install notarize publish streamdeck

gen: ## Generate the Xcode project from project.yml
	xcodegen generate

check: gen ## Compile Debug without signing (no profiles or Xcode account needed)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug CODE_SIGNING_ALLOWED=NO build

open: gen ## Generate and open in Xcode
	open $(PROJECT)

build: gen ## Build Debug (Vaux Dev) from the command line
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(DEBUG_BUILD) build

run: build ## Build Vaux Dev, install it to /Applications and launch it
	-pkill -f "Vaux Dev.app/Contents/MacOS/Vaux|Debug/Vaux.app/Contents/MacOS/Vaux"
	@# Opening it while the old one is still quitting fails (-600).
	@while pgrep -f "Vaux Dev.app/Contents/MacOS/Vaux|Debug/Vaux.app/Contents/MacOS/Vaux" >/dev/null; do sleep 0.1; done
	rm -rf "$(DEV_APP)"
	ditto "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {d=$$3} / FULL_PRODUCT_NAME/ {n=$$3} END {print d"/"n}')" "$(DEV_APP)"
	open "$(DEV_APP)"

SNAPSHOT ?= build/snapshot.png

snapshot: build ## Draw Vaux Dev's Settings tabs, menu and Settings window to $(SNAPSHOT)-named PNGs
	@mkdir -p $(dir $(SNAPSHOT))
	"$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {d=$$3} / EXECUTABLE_PATH/ {e=$$3} END {print d"/"e}')" -snapshot $(abspath $(SNAPSHOT))
	@ls $(basename $(SNAPSHOT)).*.png

snapshot-live: ## Have the running Vaux Dev draw its pages as they are now (camera live) to $(SNAPSHOT)-named PNGs
	@rm -f $(basename $(SNAPSHOT)).live-*.png
	xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("dev.imathis.vaux.debug.snapshot"), object: "$(abspath $(SNAPSHOT))", userInfo: nil, deliverImmediately: true)'
	@for i in $$(seq 1 40); do [ -f $(basename $(SNAPSHOT)).live-menu-effects.png ] && break; sleep 0.25; done
	@ls $(basename $(SNAPSHOT)).live-*.png

streamdeck: ## Build the Stream Deck plugin into build/, for Vaux to bundle (needs Node)
	cd StreamDeck && npm ci --no-fund --no-audit && npm run build
	@# Packing writes the version into the manifest: a copy, not the source.
	rm -rf build/streamdeck && mkdir -p build/streamdeck
	ditto StreamDeck/dev.imathis.vaux.sdPlugin build/streamdeck/dev.imathis.vaux.sdPlugin
	rm -rf build/streamdeck/dev.imathis.vaux.sdPlugin/logs
	cd StreamDeck && npx streamdeck pack ../build/streamdeck/dev.imathis.vaux.sdPlugin \
	  --output ../build --force --no-update-check --version $(STREAMDECK_VERSION)

release: gen streamdeck ## Build Release (Apple silicon and Intel), signed with Developer ID
	rm -rf $(ARCHIVE) build/export
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -archivePath $(ARCHIVE) \
	  -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM) VAUX_CAMERA_BUILD=$(call camera_build,Release) archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportPath build/export \
	  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
	codesign --verify --strict --deep $(RELEASE_APP)

install: release ## Install the Release build to /Applications and launch it
	@# Only the installed Vaux: Vaux Dev's process is named Vaux too.
	-pkill -f "/Applications/Vaux.app/Contents/MacOS/Vaux"
	@while pgrep -f "/Applications/Vaux.app/Contents/MacOS/Vaux" >/dev/null; do sleep 0.1; done
	rm -rf /Applications/Vaux.app
	ditto $(RELEASE_APP) /Applications/Vaux.app
	open /Applications/Vaux.app

notarize: release ## Notarize and staple the Release build, then zip it for distribution
	mkdir -p $(DIST)
	ditto -c -k --keepParent $(RELEASE_APP) $(DIST)/notarize.zip
	xcrun notarytool submit $(DIST)/notarize.zip --keychain-profile $(NOTARY_PROFILE) --wait
	rm $(DIST)/notarize.zip
	xcrun stapler staple $(RELEASE_APP)
	ditto -c -k --keepParent $(RELEASE_APP) $(ZIP)
	shasum -a 256 $(ZIP)

publish: ## Tag the release, put the notarized zip on GitHub, update the Homebrew cask
	@test -f $(ZIP) || { echo "No $(ZIP): run make notarize first"; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=no)" || { echo "Commit your changes first"; exit 1; }
	git push origin HEAD
	git tag -a v$(RELEASE) -m "Vaux $(RELEASE)"
	git push origin v$(RELEASE)
	gh release create v$(RELEASE) $(ZIP) --title "Vaux $(RELEASE)" --generate-notes \
	  $(if $(findstring -,$(RELEASE)),--prerelease) $(if $(NOTES),--notes "$(NOTES)")
	scripts/update-cask.sh $(RELEASE) $$(shasum -a 256 $(ZIP) | cut -d' ' -f1)

status: ## Installed system extensions (Vaux Camera)
	systemextensionsctl list

logs: ## Stream Vaux's logs, camera extension included
	/usr/bin/log stream --level debug --predicate 'subsystem == "dev.imathis.vaux"'

clean: ## Remove generated project and build output
	rm -rf $(PROJECT) DerivedData build $(DIST)
