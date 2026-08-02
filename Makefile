SCHEME := city of surf
PROJECT := city of surf.xcodeproj
CONFIG ?= Debug
# Prefer /tmp — project lives under Documents/iCloud which fills disk and breaks codesign xattrs.
DERIVED ?= /tmp/flood_surfer_dd
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

DEVICE_DEST ?= generic/platform=iOS
APP := $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/$(SCHEME).app
SIGN_IDENTITY ?= Apple Development: tanipekkaya@web.de (H85K4W2G74)
ENTITLEMENTS := city of surf/FloodSurfer.entitlements

.PHONY: build device-build run-device clean list-devices metal-toolchain sign fetch-assets

# One-time (needs network): make metal-toolchain
metal-toolchain:
	xcodebuild -downloadComponent MetalToolchain

# Default build = real iPhone OS (generic device). Not a Simulator validation.
build:
	@echo "=== build: destination='$(DEVICE_DEST)' (must be iphoneos, not Simulator) ==="
	@case "$(DEVICE_DEST)" in *[Ss]imulator*) echo "ERROR: DEVICE_DEST points at Simulator — use 'make device-build' or DEVICE_DEST='generic/platform=iOS'"; exit 1;; esac
	@find "city of surf" -name '.DS_Store' -delete 2>/dev/null || true
	@xattr -cr "city of surf" 2>/dev/null || true
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration $(CONFIG) \
		-destination '$(DEVICE_DEST)' \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO \
		build
	@$(MAKE) sign
	@echo "=== iphoneos product: $(APP) ==="
	@echo "NOTE: Simulator is NOT a valid Metal 4 smoke test for Flood Surfer."

# Explicit device-only alias (same as build, louder messaging).
device-build:
	@echo "=== DEVICE BUILD (iphoneos / Metal 4) — Simulator builds are invalid for smoke ==="
	@echo "Deployment Target: iOS 26.5  |  Feature: MTLGPUFamily.metal4"
	@$(MAKE) build DEVICE_DEST='generic/platform=iOS'
	@echo "Next: install $(APP) on a physical iPhone via Xcode, watch [FloodSurfer Smoke] logs."

sign:
	@test -d "$(APP)" || (echo "Missing app: $(APP)"; exit 1)
	@# Documents/iCloud adds FinderInfo + fileprovider xattrs that break codesign.
	@# ditto --norsrc --noextattr produces a signable copy.
	@rm -rf "$(APP).clean"
	@ditto --norsrc --noextattr "$(APP)" "$(APP).clean"
	@codesign --force --sign "$(SIGN_IDENTITY)" --timestamp=none --generate-entitlement-der \
		"$(APP).clean/$(SCHEME).debug.dylib" 2>/dev/null || true
	@codesign --force --sign "$(SIGN_IDENTITY)" --timestamp=none --generate-entitlement-der \
		"$(APP).clean/__preview.dylib" 2>/dev/null || true
	@codesign --force --sign "$(SIGN_IDENTITY)" --entitlements "$(ENTITLEMENTS)" \
		--timestamp=none --generate-entitlement-der "$(APP).clean"
	@rm -rf "$(APP)"
	@mv "$(APP).clean" "$(APP)"
	@echo "Signed: $(APP)"

list-devices:
	xcrun xctrace list devices 2>/dev/null || xcrun devicectl list devices

# Example: make run-device DEVICE='Your iPhone'
run-device:
	@test -n "$(DEVICE)" || (echo "Usage: make run-device DEVICE='iPhone Name'"; exit 1)
	$(MAKE) build
	@echo "Install via Xcode or: xcrun devicectl device install app --device '$(DEVICE)' '$(APP)'"

# Download CC0 HDRI + PBR maps and bake IBL (needs network + Pillow/numpy).
fetch-assets:
	@if [ -x .venv/bin/python ]; then .venv/bin/python tools/fetch_assets.py; else python3 tools/fetch_assets.py; fi

clean:
	rm -rf $(DERIVED)
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" clean
