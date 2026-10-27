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
# the Homebrew cask (imathis/homebrew-tap). Named by VAUX_RELEASE in project.yml.
RELEASE := $(shell awk -F'"' '/VAUX_RELEASE:/ {print $$2; exit}' project.yml)
RELEASE_APP := build/Build/Products/Release/Vaux.app
DIST := dist
ZIP := $(DIST)/Vaux-$(RELEASE).zip
# The developer account's notarytool login, stored in the Keychain once with
# xcrun notarytool store-credentials notarytool-profile --apple-id <id> --team-id $(TEAM)
NOTARY_PROFILE ?= notarytool-profile
# No debugger entitlement (notarization rejects it), a secure timestamp.
RELEASE_SIGN := CODE_SIGN_STYLE=Manual \
                CODE_SIGN_IDENTITY="Developer ID Application" \
                PROVISIONING_PROFILE_SPECIFIER="" \
                DEVELOPMENT_TEAM=$(TEAM) \
                OTHER_CODE_SIGN_FLAGS=--timestamp \
                CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

.PHONY: gen open build run snapshot clean release install notarize publish

gen: ## Generate the Xcode project from project.yml
	xcodegen generate

open: gen ## Generate and open in Xcode
	open $(PROJECT)

build: gen ## Build Debug from the command line
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) build

run: build ## Build and launch the app
	open $$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {d=$$3} / FULL_PRODUCT_NAME/ {n=$$3} END {print d"/"n}')

SNAPSHOT ?= build/snapshot.png

snapshot: build ## Draw Vaux Dev's Settings tabs, menu and Settings window to $(SNAPSHOT)-named PNGs
	@mkdir -p $(dir $(SNAPSHOT))
	"$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {d=$$3} / EXECUTABLE_PATH/ {e=$$3} END {print d"/"e}')" -snapshot $(abspath $(SNAPSHOT))
	@ls $(basename $(SNAPSHOT)).*.png

release: gen ## Build Release (Apple silicon and Intel), signed with Developer ID
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath build \
	  -destination 'generic/platform=macOS' $(RELEASE_SIGN) build
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

publish: ## Tag the release, put the notarized zip on GitHub, update the Homebrew cask
	@test -f $(ZIP) || { echo "No $(ZIP): run make notarize first"; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=no)" || { echo "Commit your changes first"; exit 1; }
	git push origin HEAD
	git tag -a v$(RELEASE) -m "Vaux $(RELEASE)"
	git push origin v$(RELEASE)
	gh release create v$(RELEASE) $(ZIP) --title "Vaux $(RELEASE)" --generate-notes \
	  $(if $(findstring -,$(RELEASE)),--prerelease) $(if $(NOTES),--notes "$(NOTES)")
	scripts/update-cask.sh $(RELEASE) $$(shasum -a 256 $(ZIP) | cut -d' ' -f1)

clean: ## Remove generated project and build output
	rm -rf $(PROJECT) DerivedData build $(DIST)
