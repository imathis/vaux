PROJECT := Hush.xcodeproj
SCHEME  := Hush

# Command-line signing override. Xcode (project.yml) uses automatic signing;
# from the CLI we sign manually with the local dev identity (no Apple ID
# account session needed). macOS dev builds don't require a provisioning profile.
TEAM := Q2573QH43F
SIGN := CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="Apple Development" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        DEVELOPMENT_TEAM=$(TEAM)

.PHONY: gen open build run clean

gen: ## Generate the Xcode project from project.yml
	xcodegen generate

open: gen ## Generate and open in Xcode
	open $(PROJECT)

build: gen ## Build Debug from the command line
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) build

run: build ## Build and launch the app
	open $$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug $(SIGN) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {d=$$3} / FULL_PRODUCT_NAME/ {n=$$3} END {print d"/"n}')

clean: ## Remove generated project and build output
	rm -rf $(PROJECT) DerivedData build
