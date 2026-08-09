# Builds everything Zephyr is: the ZulipKit packages and their tests, and
# the Mac and iOS apps.
#
#   make            everything below
#   make test       ZulipKit package tests (model, API, content, math)
#   make mac        debug app        (make mac-release for optimised)
#   make ios        simulator build  (make ios-device for a signed device build)
#   make tv         tvOS monitor app (simulator)
#   make vision     visionOS build (simulator)
#   make run        build and launch the Mac app
#   make generate   regenerate Zephyr.xcodeproj from project.yml (xcodegen)
#   make clean

.PHONY: all test mac mac-release ios ios-device tv vision run generate clean

all: test mac ios tv vision

test:
	swift test --package-path Packages/ZulipKit

# Exactly what Xcode's own Build does — same scheme, same default
# DerivedData — so a make build and a ⌘B are the same build.
mac:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "platform=macOS" -quiet build
	@echo "==> Built for macOS"

mac-release:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "platform=macOS" -configuration Release -quiet build
	@echo "==> Built for macOS (Release)"

ios:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "generic/platform=iOS Simulator" -quiet build
	@echo "==> Built for iOS Simulator"

tv:
	xcodebuild -project Zephyr.xcodeproj -scheme ZephyrTV \
	  -destination "generic/platform=tvOS Simulator" -quiet build
	@echo "==> Built for tvOS Simulator"

vision:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "generic/platform=visionOS Simulator" -quiet build
	@echo "==> Built for visionOS Simulator"

ios-device:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination "generic/platform=iOS" -allowProvisioningUpdates -quiet build
	@echo "==> Built for iOS device"

run: mac
	@open "$$(xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination 'platform=macOS' -showBuildSettings build 2>/dev/null \
	  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $$2; exit}')/Zephyr.app"

# Performance probes: runs the app in the foreground with -perfLog YES
# (the sandbox container blocks `defaults write` from outside, and `open`
# would swallow stdout — the probes print there). Ctrl-C quits.
perf: mac
	@"$$(xcodebuild -project Zephyr.xcodeproj -scheme Zephyr \
	  -destination 'platform=macOS' -showBuildSettings build 2>/dev/null \
	  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $$2; exit}')/Zephyr.app/Contents/MacOS/Zephyr" -perfLog YES

# The generated project is committed (CI needs no extra step); regenerate
# after editing project.yml.
generate:
	xcodegen generate

clean:
	xcodebuild -project Zephyr.xcodeproj -scheme Zephyr -quiet clean || true
	rm -rf Packages/ZulipKit/.build
