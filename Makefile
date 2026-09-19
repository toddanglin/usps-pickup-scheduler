DD ?= .build/dd
PROJ = PickupBar.xcodeproj
XCB = xcodebuild -project $(PROJ) -scheme PickupBar -derivedDataPath $(DD) -quiet

.PHONY: generate build release test uitest run icon clean
generate:
	xcodegen generate
build: generate
	$(XCB) -configuration Debug build
release: generate
	$(XCB) -configuration Release build
	@echo "App at $(DD)/Build/Products/Release/PickupBar.app"
test: generate
	xcodebuild -project $(PROJ) -scheme PickupBar -derivedDataPath $(DD) -destination 'platform=macOS' test
# Screenshots the UI test takes. Override to collect them somewhere else.
UISCREENS ?= .build/uitest-screens
MOCK_PORT ?= 8799
# The UI-test runner inherits the sandboxed app's entitlements, so it may not
# listen on a socket or write outside its container: this target owns the mock
# server's lifetime and copies the screenshots out of the container afterwards.
RUNNER_TMP = $(HOME)/Library/Containers/com.toddanglin.PickupBarUITests.xctrunner/Data/tmp/pickupbar-uiscreens
uitest: generate
	rm -rf .build/uitest.xcresult
	rm -rf "$(RUNNER_TMP)"
	mkdir -p "$(UISCREENS)"
	@PORT=$(MOCK_PORT) python3 Scripts/mock-server.py > .build/uitest-mock.log 2>&1 & \
	  MOCK_PID=$$!; \
	  trap 'kill '"$$MOCK_PID"' 2>/dev/null' EXIT INT TERM; \
	  TEST_RUNNER_PICKUPBAR_MOCK_PORT=$(MOCK_PORT) \
	  TEST_RUNNER_PICKUPBAR_UITEST_SCREENSHOTS="$(UISCREENS)" \
	  xcodebuild -project $(PROJ) -scheme PickupBarUITests -destination 'platform=macOS' -derivedDataPath $(DD) -resultBundlePath .build/uitest.xcresult test; \
	  STATUS=$$?; \
	  kill $$MOCK_PID 2>/dev/null || true; \
	  cp -f "$(RUNNER_TMP)"/*.png "$(UISCREENS)/" 2>/dev/null || true; \
	  echo "Screenshots in $(UISCREENS):"; ls -1 "$(UISCREENS)" 2>/dev/null; \
	  exit $$STATUS
run: build
	open $(DD)/Build/Products/Debug/PickupBar.app
icon:
	swift Scripts/make-icon.swift PickupBar/Resources/Assets.xcassets/AppIcon.appiconset
clean:
	rm -rf .build $(PROJ)
