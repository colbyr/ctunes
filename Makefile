# ctunes — Plex music client
#
# Device targets auto-detect the first connected iPhone. Override with:
#   make run DEVICE=<udid>

PROJECT   := App/ctunes.xcodeproj
SCHEME    := ctunes
BUNDLE_ID := com.colbyr.ctunes
DD        := build/DerivedData
SIM       ?= iPhone 17

DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null \
	| awk -F'   +' '/iPhone/ && /connected|available/ {print $$3; exit}')

DEVICE_APP := $(DD)/Build/Products/Debug-iphoneos/$(SCHEME).app
SIM_APP    := $(DD)/Build/Products/Debug-iphonesimulator/$(SCHEME).app

XCB := xcodebuild -scheme $(SCHEME) -project $(PROJECT) -derivedDataPath $(DD)

.PHONY: test live-test token build device install launch run sim sim-run devices clean

## Run PlexKit tests natively on macOS — no simulator, ~5s
test:
	swift test

## Also run the live tests against the real server, using the token in
## 1Password. Prompts for unlock the first time.
live-test:
	@PLEX_LIVE=1 \
	 PLEX_DEV_TOKEN="$$(scripts/plex-token.sh)" \
	 PLEX_DEV_CLIENT_ID="$$(scripts/plex-token.sh clientIdentifier)" \
	 swift test

## Store a fresh dev token in 1Password
token:
	python3 scripts/plex-dev-login.py

## Build the package alone
build:
	swift build

## Build the app for the connected device
device: guard-device
	$(XCB) -destination 'id=$(DEVICE)' -allowProvisioningUpdates build

install: device
	xcrun devicectl device install app --device $(DEVICE) $(DEVICE_APP)

launch:
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE_ID)

## Full device loop: build, install, launch
run: install launch

## Build and run in the simulator
sim:
	$(XCB) -destination 'platform=iOS Simulator,name=$(SIM)' build

sim-run: sim
	xcrun simctl boot '$(SIM)' 2>/dev/null || true
	xcrun simctl install booted $(SIM_APP)
	xcrun simctl launch booted $(BUNDLE_ID)

## Run in the simulator already signed in, using the 1Password token.
## DEBUG-only hook; the env var does nothing in a release build.
sim-run-live: sim
	xcrun simctl boot '$(SIM)' 2>/dev/null || true
	xcrun simctl install booted $(SIM_APP)
	@SIMCTL_CHILD_CTUNES_DEV_TOKEN="$$(scripts/plex-token.sh)" \
	 xcrun simctl launch booted $(BUNDLE_ID)

## List attached devices
devices:
	@xcrun devicectl list devices 2>/dev/null | grep -v DVTDeviceOperation

clean:
	rm -rf $(DD) .build

guard-device:
	@test -n "$(DEVICE)" || { echo "No iPhone connected. Plug one in or pass DEVICE=<udid>."; exit 1; }
