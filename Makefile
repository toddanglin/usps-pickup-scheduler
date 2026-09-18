DD ?= .build/dd
PROJ = PickupBar.xcodeproj
XCB = xcodebuild -project $(PROJ) -scheme PickupBar -derivedDataPath $(DD) -quiet

.PHONY: generate build release test run icon clean
generate:
	xcodegen generate
build: generate
	$(XCB) -configuration Debug build
release: generate
	$(XCB) -configuration Release build
	@echo "App at $(DD)/Build/Products/Release/PickupBar.app"
test: generate
	xcodebuild -project $(PROJ) -scheme PickupBar -derivedDataPath $(DD) -destination 'platform=macOS' test
run: build
	open $(DD)/Build/Products/Debug/PickupBar.app
icon:
	swift Scripts/make-icon.swift PickupBar/Resources/Assets.xcassets/AppIcon.appiconset
clean:
	rm -rf .build $(PROJ)
