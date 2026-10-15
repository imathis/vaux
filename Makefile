PROJECT := Vaux.xcodeproj
SCHEME  := Vaux

# Command-line signing override. Xcode (project.yml) uses automatic signing;
# from the CLI we sign manually with the local dev identity (no Apple ID
# account session needed). macOS dev builds don't require a provisioning profile.
TEAM := Q2573QH43F
SIGN := CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="Apple Development" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        DEVELOPMENT_TEAM=$(TEAM)

# Release: Developer ID-signed and notarized, zipped for GitHub releases and
# the Homebrew cask (imathis/homebrew-tap). The app's own version is in
# project.yml; this names the release.
RELEASE := 1.0.0-alpha.1
RELEASE_APP := build/Build/Products/Release/Vaux.app
DIST := dist
ZIP := $(DIST)/Vaux-$(RELEASE).zip
# Stored once with: xcrun notarytool store-credentials vaux --apple-id <id> --team-id $(TEAM)
NOTARY_PROFILE ?= vaux
# No debugger entitlement (notarization rejects it), a secure timestamp.
RELEASE_SIGN := CODE_SIGN_STYLE=Manual \
                CODE_SIGN_IDENTITY="Developer ID Application" \
                PROVISIONING_PROFILE_SPECIFIER="" \
                DEVELOPMENT_TEAM=$(TEAM) \
                OTHER_CODE_SIGN_FLAGS=--timestamp \
                CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

.PHONY: gen open build run clean release install notarize

gen: ## Generate the Xcode project from project.yml
	xcodegen generate

open: gen ## Generate and open in Xcode
	open $(PROJECT)

build: gen ## Build Debug from the command line
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) build

run: build ## Build and launch the app
	open $$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {d=$$3} / FULL_PRODUCT_NAME/ {n=$$3} END {print d"/"n}')

release: gen ## Build Release, signed with Developer ID
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath build $(RELEASE_SIGN) build
	codesign --verify --strict --deep $(RELEASE_APP)

install: release ## Install the Release build to /Applications and launch it
	-pkill -x Vaux
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

clean: ## Remove generated project and build output
	rm -rf $(PROJECT) DerivedData build $(DIST)
